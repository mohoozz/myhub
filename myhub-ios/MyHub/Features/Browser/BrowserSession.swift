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

    /// 新建标签并激活；`url` 为空表示空白起始页
    @discardableResult
    func newTab(url: URL? = nil) -> BrowserTab {
        let tab = BrowserTab(url: url, isIncognito: isIncognito)
        configure(tab)
        tabs.append(tab)
        activeTabID = tab.id
        persist()
        return tab
    }

    /// 统一配置标签回调（新窗口 + 历史记录 + 会话持久化）
    private func configure(_ tab: BrowserTab) {
        tab.onOpenNewTab = { [weak self] url in
            self?.newTab(url: url)
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
    }

    func switchTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
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
            let tab = BrowserTab(id: snapshot.id, url: url, isIncognito: false)
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
