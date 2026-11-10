import SwiftUI

/// 浏览器标签会话全局持有（TODO §1.1 页面保活 / §8.1 `TabManager` 落地处）：
/// 由 App 层以 `@StateObject` 持有并注入环境，切换页签不销毁会话；
/// 标签列表 + 激活标签本地持久化，退出保存、启动恢复（无痕标签不落盘）。
@MainActor
final class BrowserSessionStore: ObservableObject {
    @Published private(set) var tabs: [BrowserTab] = []
    @Published var activeTabID: UUID?
    /// 无痕开关：控制当前可见/新建的标签组
    @Published var isIncognito = false

    private static let tabsKey = "browser.session.tabs"
    private static let activeTabKey = "browser.session.activeTabID"

    init() {
        restoreSession()
    }

    // MARK: - 派生

    /// 当前模式（普通/无痕）下可见的标签
    var visibleTabs: [BrowserTab] { tabs.filter { $0.isIncognito == isIncognito } }

    var activeTab: BrowserTab? { tabs.first { $0.id == activeTabID } }

    // MARK: - 标签操作

    /// 新建标签；`url` 为空表示空白起始页。
    /// `activate` 为 false 时只把标签追加到列表、**不切换**当前页面（后台新开，TODO 408）。
    @discardableResult
    func newTab(url: URL? = nil, activate: Bool = true) -> BrowserTab {
        let tab = BrowserTab(url: url, isIncognito: isIncognito)
        configure(tab)
        tabs.append(tab)
        if activate { activeTabID = tab.id }
        persist()
        return tab
    }

    /// 统一配置标签回调（新窗口 + 历史记录 + 会话持久化）
    private func configure(_ tab: BrowserTab) {
        // 长按链接「在新标签页中打开」/ `target=_blank` / `window.open` 统一走这里：
        // 是否立即跳转由设置项决定（关闭即后台新开，停留在当前页，TODO 408）
        tab.onOpenNewTab = { [weak self] url in
            self?.newTab(url: url, activate: AppSettings.Browser.openNewTabInForeground)
        }
        tab.onDidFinishVisit = { url, title in
            BrowserDataStore.shared.recordVisit(
                title: title,
                url: url.absoluteString,
                favicon: nil
            )
        }
        // URL 变化即持久化：导航（地址栏输入/点击链接/重定向）后直接退出也能恢复
        tab.onStateChange = { [weak self] in
            self?.persist()
        }
    }

    func closeTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: idx)

        if activeTabID == id {
            // 优先切换到相邻标签（右侧，否则左侧，否则最后剩余）
            let fallback = tabs.indices.contains(idx) ? tabs[idx] : tabs.last
            activeTabID = fallback?.id
        }

        // 当前模式无可见标签时补一个空白标签
        if visibleTabs.isEmpty {
            newTab()
        } else {
            persist()
        }
        // 切到的标签可能是「会话恢复但尚未加载」的：补加载并解除媒体暂停（TODO 418）
        syncActiveTab()
    }

    func switchTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
        persist()
        // 切到另一个标签：仅新激活标签补加载/恢复媒体，旧标签暂停（TODO 418）
        syncActiveTab()
    }

    /// 拖拽排序：将 `fromID` 标签移动到 `toID` 标签所在位置（实时交换，标签卡片长按拖动）
    func moveTab(fromID: UUID, toID: UUID) {
        guard fromID != toID,
              let from = tabs.firstIndex(where: { $0.id == fromID }),
              let to = tabs.firstIndex(where: { $0.id == toID })
        else { return }
        let moved = tabs.remove(at: from)
        // 移除后重新定位目标：向下拖插到目标之后，向上拖插到目标之前
        let target = tabs.firstIndex(where: { $0.id == toID }) ?? to
        let insertAt = from < to ? target + 1 : target
        tabs.insert(moved, at: min(insertAt, tabs.count))
        persist()
    }

    /// 在激活标签加载 URL（无激活标签则新建）
    func open(_ url: URL) {
        if let tab = activeTab {
            tab.load(url)
        } else {
            newTab(url: url)
        }
    }

    /// 切换无痕开关：激活对应模式的标签，若无则新建空白标签
    func toggleIncognito() {
        isIncognito.toggle()
        if let active = activeTab, active.isIncognito == isIncognito {
            // 激活标签已属于新模式，保持不变
        } else if let first = visibleTabs.first {
            activeTabID = first.id
        } else {
            newTab()
        }
        persist()
        // 切换模式后激活标签可能变化：同步补加载 / 媒体暂停（TODO 418）
        syncActiveTab()
    }

    // MARK: - 可见性与媒体播放（TODO 418）

    /// 浏览器页签当前是否真正显示（默认否：启动时本对象即已构建，但用户可能停在别的页签）
    private var isBrowserVisible = false

    /// 由浏览器视图 / App 生命周期汇报可见性：
    /// - 可见：只加载**激活标签**并解除它的媒体暂停，其余标签保持暂停（不联网、不出声）；
    /// - 不可见：暂停所有页面媒体，避免切到别的页签或播放器全屏后网页继续播放。
    func setBrowserVisible(_ visible: Bool) {
        isBrowserVisible = visible
        if visible {
            syncActiveTab()
        } else {
            tabs.forEach { $0.suspendMediaPlayback() }
        }
    }

    /// App 进入后台：暂停全部页面媒体（锁屏后不再出声、不抢占音频会话、不继续耗流量）
    func suspendAllMediaPlayback() {
        tabs.forEach { $0.suspendMediaPlayback() }
    }

    /// 同步激活标签：补加载（会话恢复的延迟加载）+ 解除媒体暂停，其余标签暂停
    private func syncActiveTab() {
        guard isBrowserVisible else { return }
        for tab in tabs {
            if tab.id == activeTabID {
                tab.loadPendingURLIfNeeded()
                tab.resumeMediaPlayback()
            } else {
                tab.suspendMediaPlayback()
            }
        }
    }

    // MARK: - 会话持久化（退出保存 + 启动恢复）

    /// App 进入后台/即将终止时兜底落盘（由 App 层 `scenePhase` 回调调用）
    func persistNow() {
        persist()
    }

    /// 仅持久化非无痕标签（无痕标签关闭即失忆）
    private func persist() {
        let snapshots = tabs.filter { !$0.isIncognito }.map(\.snapshot)
        if let data = try? JSONEncoder().encode(snapshots) {
            UserDefaults.standard.set(data, forKey: Self.tabsKey)
        }
        // 激活标签为无痕时不落盘
        let activePersisted = activeTab?.isIncognito == false ? activeTabID?.uuidString : nil
        UserDefaults.standard.set(activePersisted, forKey: Self.activeTabKey)
    }

    private func restoreSession() {
        guard let data = UserDefaults.standard.data(forKey: Self.tabsKey),
              let snapshots = try? JSONDecoder().decode([BrowserTabSnapshot].self, from: data),
              !snapshots.isEmpty
        else {
            newTab()
            return
        }

        let restored: [BrowserTab] = snapshots.map { snapshot in
            let url = snapshot.urlString.flatMap(URL.init(string:))
            // autoload: false —— 只恢复地址与标题，**不在启动时联网**（TODO 418）。
            // 本对象由 App 层 @StateObject 持有，启动即构建；若在此加载，上次开过的所有网页
            // 会在用户还没进入浏览器时一起加载/渲染/出声（`RootView` 的 ZStack 保活会让它们
            // 全部挂在视图树里），表现为「在别的页面突然出现网页内容」。
            let tab = BrowserTab(id: snapshot.id, url: url, isIncognito: false, autoload: false)
            tab.title = snapshot.title
            configure(tab)
            return tab
        }
        tabs = restored

        let activeRaw = UserDefaults.standard.string(forKey: Self.activeTabKey)
        if let id = activeRaw.flatMap(UUID.init(uuidString:)),
           restored.contains(where: { $0.id == id }) {
            activeTabID = id
        } else {
            activeTabID = restored.first?.id
        }
    }
}
