import SwiftUI
import UIKit
import WebKit

/// 滚动位移计量器（TODO 399）：把 `contentOffset` 的高频变化（ProMotion 下可达 120Hz）
/// 归并成稀疏的「用户正在滑动页面」信号——累计位移超过 `distance` 且距上次信号超过 `interval`
/// 才发一个，既保证慢速拖动（单次回调不足 1pt）也能触发收起，又避免刷爆 `@Published`。
/// 仅在 `UIScrollView` 的主线程 KVO 回调内读写，故标注 `@unchecked Sendable`。
private final class ScrollDragMeter: @unchecked Sendable {
    private let distance: CGFloat = 4
    private let interval: TimeInterval = 0.15
    private var accumulated: CGFloat = 0
    private var lastTickAt: TimeInterval = 0

    /// 喂入一次位移增量，返回是否应发出「收起操作栏」信号
    func feed(_ delta: CGFloat) -> Bool {
        accumulated += abs(delta)
        guard accumulated >= distance else { return false }
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastTickAt >= interval else { return false }
        accumulated = 0
        lastTickAt = now
        return true
    }

    /// 手指离开页面（惯性滚动 / 回弹 / 布局自动调整）时复位，使下一次拖动能立即触发
    func reset() {
        accumulated = 0
        lastTickAt = 0
    }
}

/// 浏览器标签（TODO §8.1，IOS-401）：
/// 每个标签持有一个 `WKWebView` 实例，切换标签时不销毁视图，从而保持导航历史栈
/// （back/forward）不因标签切换或 URL 重建而丢失；无痕标签使用独立的 `nonPersistent`
/// 数据存储，不落盘。
@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id: UUID
    let isIncognito: Bool

    /// 懒创建（TODO 418）：会话恢复但尚未显示的标签不建 WebKit 实例，
    /// 避免启动时为几十个历史标签各拉起一套 WebContent 进程；首次访问时才创建。
    private(set) lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        // 与 Safari 默认一致：静音视频可自动播放，**有声媒体必须经用户手势**。
        // 旧值为 `[]`（完全允许自动播放），恢复的标签/后台标签会被广告页突然放音放视频。
        config.mediaTypesRequiringUserActionForPlayback = .audio
        // 无痕：非持久化数据存储，关闭即失忆
        config.websiteDataStore = isIncognito ? .nonPersistent() : .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = Self.userAgentString()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // 传入实例而非读 self.webView：lazy 初始化期间读自身会递归
        observe(webView)
        isWebViewCreated = true
        return webView
    }()

    /// `webView` 是否已真正创建：`webView` 是 lazy，判断存在性时不能直接读它（会触发创建）
    private var isWebViewCreated = false

    /// 是否为「会话恢复但尚未加载」的占位标签：不联网、不建 WebView、不挂载视图。
    /// 由激活/可见时调用的 `loadPendingURLIfNeeded()` 置为 `false`。
    @Published private(set) var isPendingRestore = false

    // MARK: - 可观察状态（KVO 驱动）

    @Published var title = ""
    @Published var currentURL: URL? {
        didSet {
            // 相同值（如重定向回原 URL）不重复触发；init 中的初始赋值不会触发 didSet
            guard currentURL != oldValue else { return }
            // 页面已经换掉：旧缩略图不再代表当前内容，清空让网格重抓（TODO 423）
            if thumbnailSourceURL != currentURL?.absoluteString { thumbnail = nil }
            noteHistoryNavigation()
            onStateChange?()
        }
    }
    @Published var faviconURL: URL?
    @Published var estimatedProgress: Double = 0
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    /// HTTPS 安全图标：当前主资源使用安全连接
    @Published var hasOnlySecureContent = false
    @Published var hasError = false
    @Published var isSSLError = false
    @Published var errorMessage: String?

    /// 页面滚动计数：用户任意方向拖动页面均自增，用于将底部操作栏收起为胶囊（TODO §8.2）
    /// 用计数器而非布尔，保证「展开后再次滚动」也能再触发收起
    @Published var scrollTick: Int = 0

    /// 刷新计数：主动刷新（工具栏刷新键 / 下拉刷新 / 错误页重试）自增，
    /// 与 `scrollTick` 一样用于把底部操作栏收起为胶囊（TODO 399）
    @Published var reloadTick: Int = 0

    /// 起始页回退标记：从起始页导航进入过页面后为 `true`，
    /// 使「回退」按钮在 webView 历史为空时仍可返回到起始页（Safari 行为）
    @Published private(set) var startedFromStartPage = false

    /// 「从起始页出发」时 webView 历史栈的边界条目（起始页之前的最后一页；全新标签为 `nil`）。
    /// 回退到该条目即视为回到起始页，避免回退越过起始页误入更早的残留历史（多退一页）。
    private var startPageBoundary: WKBackForwardListItem?

    // MARK: - 跨重启历史栈

    /// 含当前页在内的历史 URL（按时间顺序）。正常运行时由 `WKBackForwardList` 同步而来，
    /// 重启恢复后作为回退/前进的唯一依据（WebKit 没有「注入历史」的公开 API）。
    private var historyURLs: [String] = []
    /// 当前页在 `historyURLs` 中的下标；`-1` 表示无当前页（起始页）
    private var historyIndex = -1
    /// 是否由 `historyURLs` 驱动回退/前进：仅「会话恢复且历史跨进程丢失」的标签为 `true`。
    /// 此模式下原生 back/forward 顺序不可靠（每次回退都是一次新导航），故禁用系统侧滑手势、
    /// 改由工具栏按钮与自定义边缘手势走本栈。
    private(set) var usesRestoredHistory = false

    /// `target=_blank` / `window.open` 回调：交给 `BrowserSessionStore` 新建标签
    var onOpenNewTab: ((URL) -> Void)?

    /// 主资源加载完成回调（url, title）：记录浏览历史（无痕不记录，TODO §8.3）
    var onDidFinishVisit: ((URL, String) -> Void)?

    /// 标签状态变化回调（当前 URL 变化等）：由 `BrowserSessionStore` 订阅，驱动会话持久化，
    /// 保证「导航后直接退出」也能保存上一次打开的页面
    var onStateChange: (() -> Void)?

    /// 下拉刷新控件（由 `BrowserWebView` 创建并挂到 `scrollView`）：
    /// 页面加载完成/失败时在此结束刷新动画（`scrollView` 强持有，故弱引用即可）
    weak var refreshControl: UIRefreshControl?

    private var observations: [NSKeyValueObservation] = []
    /// 会话恢复的延迟加载 URL（TODO 418）：
    /// App 启动不自动联网，等标签真正显示时由 `loadPendingURLIfNeeded()` 补加载
    private var pendingLoadURL: URL?

    /// - Parameter autoload: 是否立即加载 `url`。
    ///   会话恢复必须传 `false`：`RootView` 用 ZStack 保活所有页签、启动即构建 `BrowserHomeView`，
    ///   若在此直接 load，会把上次开过的**全部**网页在启动瞬间一起联网、渲染并（允许自动播放时）出声，
    ///   用户还没进浏览器就可能看到／听到页面内容（含网页全屏视频等系统层呈现）。
    /// - Parameters:
    ///   - restoredHistory: 会话恢复时读回的历史 URL 列表（含当前页），用于重建回退能力
    ///   - restoredIndex: 当前页在上述列表中的下标
    ///   - startedFromStartPage: 会话恢复时读回的「从起始页进入」标记
    init(
        id: UUID = UUID(),
        url: URL?,
        isIncognito: Bool,
        autoload: Bool = true,
        restoredHistory: [String] = [],
        restoredIndex: Int = -1,
        startedFromStartPage: Bool = false
    ) {
        self.id = id
        self.isIncognito = isIncognito

        super.init()

        self.currentURL = url

        // 重启恢复：原生历史栈已丢失，改用磁盘里的 URL 栈驱动回退/前进。
        // 仅当栈里确有可回退/可前进的条目时才接管，避免把普通标签也拖进自定义模式。
        if let url, restoredHistory.count > 1,
           restoredHistory.indices.contains(restoredIndex) {
            var stack = restoredHistory
            if stack[restoredIndex] != url.absoluteString {
                // 落盘后又发生过重定向/跳转：以实际当前地址为准，避免回退到错位的一页
                stack[restoredIndex] = url.absoluteString
            }
            historyURLs = stack
            historyIndex = restoredIndex
            usesRestoredHistory = true
        }
        self.startedFromStartPage = startedFromStartPage

        if let url {
            if autoload {
                webView.load(URLRequest(url: url))
            } else {
                // 只记 URL：WebView 与网络请求都推迟到标签真正显示时（`loadPendingURLIfNeeded`）
                pendingLoadURL = url
                isPendingRestore = true
            }
        }
    }

    // MARK: - 导航操作

    func load(_ url: URL) {
        // 从起始页导航进入页面：起始页成为可回退的第一页（需在 currentURL 更新前判断）
        if isShowingStartPage {
            startedFromStartPage = true
            // 记录当前历史边界：后续回退到此条目即回到起始页（避免多退一页到残留历史）
            startPageBoundary = webView.backForwardList.currentItem
            // 起始页是逻辑第一页：历史从这里重新累积（重启恢复后从起始页出发同样适用）
            historyURLs = []
            historyIndex = -1
        }
        clearError()
        // 用户主动导航优先于会话恢复的延迟加载，避免之后又被旧 URL 覆盖
        pendingLoadURL = nil
        isPendingRestore = false
        currentURL = url   // 立即更新：隐藏起始页、刷新地址栏
        webView.load(URLRequest(url: url))
    }

    // MARK: - 可见性与媒体播放（TODO 418）

    /// 会话恢复的延迟加载：标签首次真正显示时调用（重复调用无副作用）
    func loadPendingURLIfNeeded() {
        guard let url = pendingLoadURL else { return }
        pendingLoadURL = nil
        isPendingRestore = false   // 先置位：视图据此外挂载 WebView
        clearError()
        webView.load(URLRequest(url: url))
    }

    /// 暂停页面内媒体播放（标签切走 / 浏览器页签不可见 / App 进入后台）。
    /// 标签常驻保活且允许自动播放：不暂停的话，后台标签会继续出声、占用音频会话，
    /// 甚至在锁屏后继续消耗流量。
    func suspendMediaPlayback() {
        // 未创建的占位标签没有媒体可暂停，读 `webView` 反而会触发 lazy 创建
        guard isWebViewCreated else { return }
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
    }

    /// 解除媒体暂停（标签重新显示 / 回到前台）：只恢复可播放状态，不主动播放
    func resumeMediaPlayback() {
        guard isWebViewCreated else { return }
        webView.setAllMediaPlaybackSuspended(false, completionHandler: nil)
    }

    func reload() {
        clearError()
        // 刷新同样收起操作栏为胶囊（TODO 399）：计数器自增，保证连续刷新每次都能触发
        reloadTick += 1
        webView.reload()
    }

    func stopLoading() {
        webView.stopLoading()
    }

    /// 回退可用性：非起始页时总可回退（webView 历史栈可退，或可退回起始页）。
    /// 起始页本身是标签的逻辑第一页，不可再回退。
    var canGoBackOrStartPage: Bool {
        guard !isShowingStartPage else { return false }
        if usesRestoredHistory { return historyIndex > 0 || startedFromStartPage }
        return webView.canGoBack || startedFromStartPage
    }

    /// 前进可用性（工具栏按钮用）：重启恢复后原生历史栈为空，改看自定义栈
    var canGoForwardOrHistory: Bool {
        if usesRestoredHistory { return historyIndex >= 0 && historyIndex < historyURLs.count - 1 }
        return webView.canGoForward
    }

    /// 回退一步是否将回到起始页（即已到达「从起始页出发」时记录的历史边界）
    private var reachedStartPageBoundary: Bool {
        guard startedFromStartPage, let boundary = startPageBoundary else { return false }
        return webView.backForwardList.backItem === boundary
    }

    /// 下一步回退是否为「回到起始页」（供手势层决定是否拦截系统 back 手势）
    var backLeadsToStartPage: Bool {
        guard !isShowingStartPage, startedFromStartPage else { return false }
        // 重启恢复：自定义栈退到底即起始页
        if usesRestoredHistory { return historyIndex <= 0 }
        // 无更早历史，或回退将越过起始页边界 → 下一步即起始页
        return !webView.canGoBack || reachedStartPageBoundary
    }

    /// 回退：优先走 webView 历史栈；到达起始页边界（或栈空且从起始页进入）时回退到起始页
    func goBack() {
        if usesRestoredHistory {
            guard !isShowingStartPage else { return }
            if historyIndex > 0 {
                historyIndex -= 1
                loadHistoryEntry()
            } else if startedFromStartPage {
                showStartPage()
            }
            return
        }
        if webView.canGoBack, !reachedStartPageBoundary {
            webView.goBack()
        } else if startedFromStartPage, !isShowingStartPage {
            showStartPage()
        }
    }

    func goForward() {
        if usesRestoredHistory {
            guard historyIndex >= 0, historyIndex < historyURLs.count - 1 else { return }
            historyIndex += 1
            loadHistoryEntry()
            return
        }
        webView.goForward()
    }

    /// 回退到起始页：清空 URL 展示起始页（起始页始终是标签的逻辑第一页）
    private func showStartPage() {
        startedFromStartPage = false
        startPageBoundary = nil
        // 自定义历史栈同步清空：起始页是标签的第一页，之后从起始页出发重新累积
        historyURLs = []
        historyIndex = -1
        currentURL = nil
        // 注：WKBackForwardList 无公开的清空历史栈 API；此处只重置 UI 状态，webView 历史栈保留。
        // 再次从起始页导航时会依据 `startPageBoundary` 重新界定回退边界，从而不会多退一页到残留历史。
    }

    // MARK: - 卡片缩略图（标签网格方案 A，TODO 423）

    /// 标签卡片的预览图：由 `captureThumbnailIfNeeded()` 异步抓取，与本标签的生命周期绑定。
    /// 无痕标签**永不抓取**——截图会以图像形式留在内存与系统快照缓存里，
    /// 与「无痕不落盘」的承诺冲突，网格直接走品牌色占位形态。
    @Published private(set) var thumbnail: UIImage?
    /// 当前缩略图对应的 URL：用于判断「缓存是否还能代表现在这一页」
    private var thumbnailSourceURL: String?
    /// 抓取进行中标记：同一标签只允许一次在途快照，避免打开网格时重复排队
    private var isCapturingThumbnail = false

    /// 抓取卡片缩略图（打开标签网格时按需调用，可安全重复调用）。
    ///
    /// 三条硬约束：
    /// - **无痕不抓**：隐私优先，宁可看占位图；
    /// - **不建 WebView**：会话恢复但尚未显示的标签不能读 `webView`（lazy 会拉起 WebContent 进程）；
    /// - **只抓顶部一屏**：卡片预览只露上半部分，抓整页既慢又占内存。
    ///
    /// - Parameter targetWidth: 快照目标宽度（pt）。卡片实际宽度约 160pt，取 2.5 倍保证 Retina 下清晰。
    func captureThumbnailIfNeeded(targetWidth: CGFloat = 400) {
        guard !isIncognito else { return }
        guard isWebViewCreated, !isPendingRestore else { return }
        guard let key = currentURL?.absoluteString, !isShowingStartPage else { return }
        // 命中缓存：同一页面已经抓过
        if key == thumbnailSourceURL, thumbnail != nil { return }
        guard !isCapturingThumbnail else { return }

        let size = webView.bounds.size
        // 标签尚未布局（从未显示）时抓不到有效画面，等下次打开网格再试
        guard size.width > 1, size.height > 1 else { return }

        isCapturingThumbnail = true
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: Double(targetWidth))
        configuration.rect = CGRect(origin: .zero, size: size)

        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            Task { @MainActor in
                guard let self else { return }
                self.isCapturingThumbnail = false
                guard let image else { return }
                // 抓取期间页面可能已经跳走：过期的帧直接丢弃，否则卡片会显示上一页的内容
                guard key == self.currentURL?.absoluteString else { return }
                self.thumbnailSourceURL = key
                self.thumbnail = image
            }
        }
    }

    /// 展示标签卡片网格所需的快照（用于持久化）
    var snapshot: BrowserTabSnapshot {
        // 先与原生历史栈对齐，保证落盘的是「最后一次导航后」的真实历史
        refreshNativeHistory()
        return BrowserTabSnapshot(
            id: id,
            urlString: currentURL?.absoluteString,
            title: title,
            historyURLs: historyURLs.isEmpty ? nil : historyURLs,
            currentIndex: historyIndex >= 0 ? historyIndex : nil,
            startedFromStartPage: startedFromStartPage
        )
    }

    /// 是否显示起始页（空白标签：未加载 URL 且无错误）
    var isShowingStartPage: Bool {
        currentURL == nil && !isLoading && !hasError
    }

    // MARK: - 历史栈维护

    /// 从原生历史栈同步（正常运行时唯一来源）。
    /// 重启恢复模式下跳过：那时原生栈是本栈「回放」出来的，条目顺序与真实历史相反，不能反向覆盖。
    private func refreshNativeHistory() {
        // 未创建的占位标签不能读 `webView`（会触发 lazy 创建、拉起 WebContent 进程），沿用已恢复的栈
        guard !usesRestoredHistory, isWebViewCreated else { return }
        let list = webView.backForwardList
        guard let current = list.currentItem else {
            historyURLs = []
            historyIndex = -1
            return
        }
        let back = list.backList
        historyURLs = (back + [current] + list.forwardList).map(\.url.absoluteString)
        historyIndex = back.count
    }

    /// 重启恢复模式下的历史记账：新导航丢弃前进项后追加当前页
    private func noteHistoryNavigation() {
        // 正常模式由 `refreshNativeHistory()` 从原生栈同步，这里只管自定义栈
        guard usesRestoredHistory else { return }
        // 地址置空（回到起始页 / 加载失败）不改写栈：起始页由 `showStartPage()` 显式清空，
        // 失败时保留历史才能让用户回退离开出错页
        guard let url = currentURL?.absoluteString else { return }
        // 历史回放（goBack/goForward 引起的地址变化）：位置已由调用方设置，不新增条目
        if historyURLs.indices.contains(historyIndex), historyURLs[historyIndex] == url { return }
        if historyIndex >= 0 {
            historyURLs = Array(historyURLs.prefix(historyIndex + 1))
        } else {
            historyURLs = []
        }
        historyURLs.append(url)
        historyIndex = historyURLs.count - 1
    }

    /// 按自定义栈加载当前下标对应的页面（WebKit 无注入历史 API，只能重新发起导航）
    private func loadHistoryEntry() {
        guard historyURLs.indices.contains(historyIndex),
              let url = URL(string: historyURLs[historyIndex]) else { return }
        clearError()
        pendingLoadURL = nil
        isPendingRestore = false
        currentURL = url
        webView.load(URLRequest(url: url))
    }

    // MARK: - KVO

    /// - Parameter webView: 由 `webView` 的 lazy 初始化传入（避免初始化期间读取 `self.webView` 递归）
    private func observe(_ webView: WKWebView) {
        // 滚动计量器：随下方 contentOffset 观察闭包一同存活，仅在主线程 KVO 回调内访问
        let dragMeter = ScrollDragMeter()
        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                let value = webView.estimatedProgress
                Task { @MainActor [weak self] in self?.estimatedProgress = value }
            },
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                let value = webView.title ?? ""
                Task { @MainActor [weak self] in self?.title = value }
            },
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                let value = webView.url
                Task { @MainActor [weak self] in self?.currentURL = value }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                let value = webView.isLoading
                Task { @MainActor [weak self] in
                    self?.isLoading = value
                    // 加载结束（成功/失败/取消）即收起下拉刷新动画
                    if !value { self?.refreshControl?.endRefreshing() }
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                let value = webView.canGoBack
                Task { @MainActor [weak self] in self?.canGoBack = value }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                let value = webView.canGoForward
                Task { @MainActor [weak self] in self?.canGoForward = value }
            },
            webView.observe(\.hasOnlySecureContent, options: [.new]) { [weak self] webView, _ in
                let value = webView.hasOnlySecureContent
                Task { @MainActor [weak self] in self?.hasOnlySecureContent = value }
            },
            // 滚动即收起操作栏为胶囊（任意方向，Safari 风格）：只有点击胶囊才恢复地址栏。
            // 仅统计「用户手指在拖动」期间的位移（TODO 399）：操作栏展开/收起会改变 webView 高度、
            // 页面加载与回弹也会自动调整 contentOffset，这类「伪滚动」若计入就会与点击胶囊展开形成反馈回路
            // （展开 → webView 变矮 → offset 自动调整 → 立刻又收起，表现为「第一次点击胶囊没展开」）。
            webView.scrollView.observe(\.contentOffset, options: [.new, .old]) { [weak self] scrollView, change in
                guard scrollView.isTracking || scrollView.isDragging else {
                    dragMeter.reset()
                    return
                }
                let newY = scrollView.contentOffset.y
                let oldY = change.oldValue?.y ?? newY
                // 按「累计位移」判定而非单次增量：慢速拖动时每次回调不足 1pt，
                // 用单次阈值会永远触发不了收起；累计超过阈值即发一个信号并复位（兼带节流）
                guard dragMeter.feed(newY - oldY) else { return }
                Task { @MainActor [weak self] in self?.scrollTick += 1 }
            }
        ]
    }

    // MARK: - 错误处理

    private func handleError(_ error: Error) {
        let nsError = error as NSError
        let isSSL = nsError.domain == NSURLErrorDomain
            && (nsError.code == NSURLErrorServerCertificateUntrusted
                || nsError.code == NSURLErrorServerCertificateHasBadDate
                || nsError.code == NSURLErrorServerCertificateNotYetValid
                || nsError.code == NSURLErrorServerCertificateHasUnknownRoot
                || nsError.code == NSURLErrorSecureConnectionFailed)
        hasError = true
        isSSLError = isSSL
        errorMessage = isSSL ? "连接不安全，证书校验失败" : (error.localizedDescription)
        AppLogger.shared.log("浏览器标签加载失败: \(nsError.domain) \(nsError.code) \(error.localizedDescription)", level: .warn, module: "browser")
    }

    private func clearError() {
        hasError = false
        isSSLError = false
        errorMessage = nil
    }

    // MARK: - Favicon 提取

    private func extractFavicon() {
        // 通过注入脚本读取 <link rel="icon">；失败则回退到 Google favicon 服务
        let js = """
        (function() {
          function absolute(href) {
            if (!href) return '';
            var a = document.createElement('a');
            a.href = href;
            return a.href;
          }
          var links = document.querySelectorAll('link[rel~="icon"], link[rel="shortcut icon"], link[rel="apple-touch-icon"]');
          for (var i = 0; i < links.length; i++) {
            var href = absolute(links[i].getAttribute('href'));
            if (href) return href;
          }
          return '';
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            Task { @MainActor in
                guard let self else { return }
                if let href = result as? String, !href.isEmpty, let url = URL(string: href) {
                    self.faviconURL = url
                } else if let host = self.currentURL?.host {
                    self.faviconURL = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64")
                }
            }
        }
    }

    // MARK: - UA

    private static func userAgentString() -> String? {
        switch AppSettings.Browser.userAgent {
        case .platform: return nil
        case .desktop:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Safari/605.1.15"
        case .mobile:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Mobile/15E148 Safari/604.1"
        }
    }
}

// MARK: - WKNavigationDelegate

extension BrowserTab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        clearError()
        extractFavicon()
        // 记录浏览历史（无痕不记录）
        if !isIncognito, let url = webView.url {
            onDidFinishVisit?(url, webView.title ?? "")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // 忽略用户主动取消（回退/停止/刷新会取消旧导航，触发 -999 NSURLErrorCancelled），
        // 避免把正常的回退误判为加载失败而弹出错误页
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        handleError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // 忽略用户主动取消（-999）
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        handleError(error)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // `target=_blank`：无 targetFrame 表示新窗口请求 → 新标签打开
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            onOpenNewTab?(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

// MARK: - WKUIDelegate

extension BrowserTab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // `window.open`：新标签打开
        if let url = navigationAction.request.url {
            onOpenNewTab?(url)
        }
        return nil
    }

    /// 长按链接菜单**全部自绘**（TODO 408）：
    /// 系统默认菜单里的「打开」在 `WKWebView`（非 Safari 宿主）下由 WebKit 自行处理，
    /// 会走 `UIApplication.open` 把链接丢给系统默认浏览器——表现为「点了 Open Link 跳到 Safari」，
    /// 且该动作**不经过** `decidePolicyFor`，因此无法在导航策略层拦截。
    /// 唯一可靠的办法是接管 `contextMenuConfigurationForElement` 自建菜单，
    /// 让每个动作都落到内置浏览器的 API 上（当前标签加载 / 新建标签 / 拷贝 / 分享）。
    func webView(
        _ webView: WKWebView,
        contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
        completionHandler: @escaping (UIContextMenuConfiguration?) -> Void
    ) {
        // 非链接元素（图片 / 纯文本 / 输入框）返回 nil，交回系统默认菜单（选词、拷贝图片等不受影响）
        guard let url = elementInfo.linkURL else {
            completionHandler(nil)
            return
        }

        let config = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let open = UIAction(title: "打开", image: UIImage(systemName: "arrow.up.right.square")) { _ in
                Task { @MainActor in self?.load(url) }
            }
            let openInNewTab = UIAction(title: "在新标签页中打开", image: UIImage(systemName: "plus.square.on.square")) { _ in
                Task { @MainActor in self?.onOpenNewTab?(url) }
            }
            let copy = UIAction(title: "拷贝链接", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.url = url
            }
            let share = UIAction(title: "分享…", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                Task { @MainActor in self?.presentShareSheet(for: url, from: webView) }
            }
            return UIMenu(title: url.absoluteString, children: [open, openInNewTab, copy, share])
        }
        completionHandler(config)
    }

    /// 点击长按预览（而非菜单项）时的提交动作：同样留在内置浏览器内，于当前标签加载
    func webView(
        _ webView: WKWebView,
        contextMenuForElement elementInfo: WKContextMenuElementInfo,
        willCommitWithAnimator animator: UIContextMenuInteractionCommitAnimating
    ) {
        guard let url = elementInfo.linkURL else { return }
        animator.preferredCommitStyle = .pop
        animator.addCompletion { [weak self] in
            Task { @MainActor in self?.load(url) }
        }
    }

    /// 分享面板：从承载 webView 的窗口最上层控制器弹出（iPad 需锚点，否则 popover 会崩）
    private func presentShareSheet(for url: URL, from webView: WKWebView) {
        guard var presenter = webView.window?.rootViewController else { return }
        while let presented = presenter.presentedViewController { presenter = presented }

        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = webView
            popover.sourceRect = CGRect(x: webView.bounds.midX, y: webView.bounds.midY, width: 1, height: 1)
        }
        presenter.present(controller, animated: true)
    }
}

// MARK: - SwiftUI 封装

/// 将 `BrowserTab` 持有的 `WKWebView` 挂到视图层级（标签保活：由 `ZStack` 常驻所有标签，
/// 仅切换透明度而非销毁重建，从而保持导航历史栈）。
/// 附带手势：左边缘滑动（回退历史 / 回到起始页，绝不删除页签）、点击页面（展开被收起的操作栏）。
struct BrowserWebView: UIViewRepresentable {
    let tab: BrowserTab
    var onTap: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .white
        let webView = tab.webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])

        // 下拉刷新：页面滚动到顶部继续下拉即重新加载（原生 UIRefreshControl，自带下拉/转圈动画）
        let refresh = UIRefreshControl()
        refresh.tintColor = UIColor(AppColors.primary)
        refresh.addTarget(
            context.coordinator,
            action: #selector(Coordinator.handleRefresh(_:)),
            for: .valueChanged
        )
        webView.scrollView.refreshControl = refresh
        tab.refreshControl = refresh

        // 左边缘滑动：默认交给系统 backForward 手势做页面间回退；
        // 「下一步回退即起始页」与重启恢复的标签（见 updateUIView）改用本手势——
        // 由它自己做跟手位移 + 松手完成/回弹的过渡（Safari 侧滑返回，TODO 421）
        let edge = UIScreenEdgePanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleEdgeSwipe(_:))
        )
        edge.edges = .left
        edge.delegate = context.coordinator
        container.addGestureRecognizer(edge)
        context.coordinator.edgeGesture = edge

        // 点击页面：展开操作栏（不拦截链接/表单交互）
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        container.addGestureRecognizer(tap)

        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        // 手势分工（保证「一直回退最终回到起始页」且绝不误删页签）：
        // - 起始页：标签第一页，左滑不做任何事（既不删页签，也不跳到残留历史）
        // - 下一步回退即起始页：用自定义边缘手势拦截，关闭系统 back 手势（避免越过起始页多退一页）
        // - 其余（页面间回退）：交给系统 back 手势，保留跟手滑动动画
        if tab.isShowingStartPage {
            tab.webView.allowsBackForwardNavigationGestures = false
            context.coordinator.edgeGesture?.isEnabled = false
        } else if tab.backLeadsToStartPage || tab.usesRestoredHistory {
            // 重启恢复的标签：原生历史栈由「回放」产生，方向不可靠，统一交给自定义边缘手势
            tab.webView.allowsBackForwardNavigationGestures = false
            context.coordinator.edgeGesture?.isEnabled = true
        } else {
            tab.webView.allowsBackForwardNavigationGestures = true
            context.coordinator.edgeGesture?.isEnabled = false
        }

        // 位移 / 透明度兜底（TODO 421）：侧滑把容器挪动过之后，若因标签切换、媒体可见性等
        // 打断了收尾动画（completion 不再回调），容器会卡在偏移或半透明态。
        // 手势进行中与收尾动画进行中都不能动它，其余时机一律归位。
        let gesture = context.coordinator.edgeGesture
        let gestureActive = gesture?.state == .began || gesture?.state == .changed
        if !gestureActive, !context.coordinator.isCompletingBack {
            if container.transform != .identity { container.transform = .identity }
            if container.alpha != 1 { container.alpha = 1 }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: BrowserWebView
        weak var edgeGesture: UIScreenEdgePanGestureRecognizer?
        /// 侧滑返回的收尾动画（回弹 / 「滑出 → 滑入」）是否仍在进行。
        /// 是 `updateUIView` 归位兜底的唯一豁免依据：动画进行中若被兜底把 `transform` 归零，
        /// 就会退化成「一帧瞬移」，回弹的阻尼与滑入的位移全部失效。
        private(set) var isCompletingBack = false

        /// 侧滑「代号」：每次手势 `.began` 自增。收尾动画的 completion 必须核对代号——
        /// 手势可能在上一轮收尾动画还没走完时再次起手（`removeAllAnimations` 会让旧 completion
        /// 提前回调），若不核对就会用旧的判定再 `goBack()` 一次，退成连退两页。
        private var swipeGeneration = 0

        init(_ parent: BrowserWebView) { self.parent = parent }

        /// 侧滑返回（TODO 421）：跟手位移 + 松手后完成/回弹，对齐 Safari 的交互式返回。
        ///
        /// 旧实现只在 `.ended` 里 `goBack()`：全程没有位移反馈，画面在松手瞬间直接换掉，
        /// 读起来就是「滑一下、猝不及防地跳转」。现在 `.changed` 阶段整块网页容器跟着手指右移，
        /// 下层（起始页预览 / 页面底色）逐帧露出；松手按位移比例 + 速度决定完成还是回弹。
        @objc func handleEdgeSwipe(_ gesture: UIScreenEdgePanGestureRecognizer) {
            guard let container = gesture.view else { return }
            let width = max(container.bounds.width, 1)
            // 位移换算基准取 **window**（退化为父视图）：容器本身正被 `transform` 挪动，
            // 以它为坐标空间会让 translation 反过来被自身位移缩放，形成跟手距离衰减 / 抖动
            // （与 `MiniPlayer` 下滑收起、播放页手势同一处坑）；window 也没有任何祖先变换，
            // 位移与手指在屏幕上的移动严格 1:1。
            let space = container.window ?? container.superview ?? container

            switch gesture.state {
            case .began:
                // 新一次起手：作废上一轮收尾动画（`removeAllAnimations` 会立刻回调其 completion，
                // 靠代号一致性检查让它空转），并把位移 / 透明度归零，避免残值叠加
                swipeGeneration &+= 1
                isCompletingBack = false
                container.layer.removeAllAnimations()
                container.transform = .identity
                container.alpha = 1
            case .changed:
                let dx = gesture.translation(in: space).x
                container.transform = CGAffineTransform(translationX: max(0, dx), y: 0)
            case .ended:
                let dx = gesture.translation(in: space).x
                let velocity = gesture.velocity(in: space).x
                let progress = min(max(dx / width, 0), 1)
                // 位移过 32% 或带明显右甩速度即完成，否则回弹（比例与阈值对齐系统侧滑返回的手感）
                if progress > 0.32 || velocity > 700 {
                    completeBack(on: container)
                } else {
                    springBack(container)
                }
            default:
                // .cancelled / .failed（如页面被其它手势抢占）：一律回弹，不能半途换页
                springBack(container)
            }
        }

        /// 未过阈值：带阻尼弹回原位（`beginFromCurrentState` 保证从当前手势位移处接着动，不跳帧）
        private func springBack(_ container: UIView) {
            guard !isCompletingBack else { return }
            isCompletingBack = true
            let generation = swipeGeneration
            UIView.animate(
                withDuration: 0.26,
                delay: 0,
                usingSpringWithDamping: 0.9,
                initialSpringVelocity: 0,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                container.transform = .identity
            } completion: { [weak self] _ in
                // 代号不符说明手势已重新起手，新一轮自己管自己的状态
                guard let self, generation == self.swipeGeneration else { return }
                self.isCompletingBack = false
            }
        }

        /// 过阈值：先让当前页整块滑出，再在新页面上做入场，把「内容替换」藏进不可见的那一帧。
        ///
        /// 为什么不能直接 `goBack()` 了事：重启恢复的标签走的是自定义历史栈（`usesRestoredHistory`），
        /// 回退只能重新发起导航（WebKit 没有注入历史的 API），内容必然整块替换；旧实现的
        /// 「松手即 `goBack()`」就把这次替换完全暴露出来。这里分两种情况收尾：
        /// - **回退到起始页**：下层常驻起始页预览（`BrowserView.showsStartPagePreview`），
        ///   纯滑动退出即可，替换发生在容器完全移出屏幕之后，观感是「上一页滑走 → 起始页留在原位」；
        /// - **页面间回退**：新内容要等导航回来，故叠加淡出/淡入，让中间那次替换落在半透明处。
        private func completeBack(on container: UIView) {
            guard !isCompletingBack else { return }
            isCompletingBack = true

            let width = max(container.bounds.width, 1)
            let returnsToStartPage = parent.tab.backLeadsToStartPage
            let generation = swipeGeneration
            container.layer.removeAllAnimations()

            UIView.animate(
                withDuration: 0.20,
                delay: 0,
                options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
            ) {
                container.transform = CGAffineTransform(translationX: width, y: 0)
                if !returnsToStartPage { container.alpha = 0 }
            } completion: { [weak self] _ in
                guard let self, generation == self.swipeGeneration else { return }
                self.parent.tab.goBack()

                // 起始页由下层常驻预览无缝接手：容器此刻完全在屏外，暂不归位——
                // 让「起始页插入」与「容器归位」落在同一次 SwiftUI 更新里（由 `updateUIView` 的
                // 兜底完成）。若在这里立刻归位，旧页面有可能抢在起始页渲染之前闪回一帧。
                if returnsToStartPage || self.parent.tab.isShowingStartPage {
                    container.alpha = 1
                    self.isCompletingBack = false
                    return
                }

                // 页面间回退：从左侧 25% 处滑入，与离场方向构成一次连贯的左右推进
                container.transform = CGAffineTransform(translationX: -width * 0.25, y: 0)
                UIView.animate(
                    withDuration: 0.28,
                    delay: 0,
                    usingSpringWithDamping: 0.92,
                    initialSpringVelocity: 0,
                    options: [.curveEaseOut, .allowUserInteraction]
                ) {
                    container.transform = .identity
                    container.alpha = 1
                } completion: { [weak self] _ in
                    guard let self, generation == self.swipeGeneration else { return }
                    self.isCompletingBack = false
                }
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            // 点击页面任意处（含空白）：先收起键盘/退出地址栏编辑，再展开操作栏
            Keyboard.dismiss()
            parent.onTap?()
        }

        @objc func handleRefresh(_ sender: UIRefreshControl) {
            // 已加载页面则重新加载（加载完成后由 isLoading KVO 收起动画）；
            // 起始页/无 URL 时无内容可刷，立即结束动画
            if parent.tab.currentURL != nil {
                parent.tab.reload()
            } else {
                sender.endRefreshing()
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// 标签会话快照（持久化用，无痕标签不参与）
///
/// `historyURLs` / `currentIndex` 是**跨重启保留回退能力**的关键：
/// `WKBackForwardList` 无法序列化，重启后新建的 `WKWebView` 历史栈只有当前一条，
/// 不把历史一起落盘就只剩「能打开上次的页面，但回退键永远置灰」。
struct BrowserTabSnapshot: Codable {
    let id: UUID
    let urlString: String?
    let title: String
    /// 含当前页在内的完整历史（按时间顺序）；`nil` 表示无历史（起始页 / 旧版本数据）
    var historyURLs: [String]? = nil
    /// 当前页在 `historyURLs` 中的下标
    var currentIndex: Int? = nil
    /// 「从起始页进入」标记：决定回退到底时是否退回起始页
    var startedFromStartPage: Bool? = nil
}
