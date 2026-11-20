import SwiftUI
import UIKit
import WebKit

/// 滚动位移计量器：把高频位移合并成稀疏的「收起操作栏」信号
private final class ScrollDragMeter: @unchecked Sendable {
    private let distance: CGFloat = 4
    private let interval: TimeInterval = 0.15
    private var accumulated: CGFloat = 0
    private var lastTickAt: TimeInterval = 0
    /// 本轮拖动（手指按下 → 抬起）是否已经开始过
    private var gestureStarted = false

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

    /// 记录「手指仍在页面上」的一次位移回调，返回是否属于本轮拖动的**第一个**回调。
    func beginGestureIfNeeded() -> Bool {
        guard !gestureStarted else { return false }
        gestureStarted = true
        return true
    }

    /// 手指离开页面（惯性滚动 / 回弹 / 布局自动调整）时复位：计量值与手势态一并归零
    func endGesture() {
        gestureStarted = false
        reset()
    }

    /// 只复位位移计量（保留手势态）
    private func reset() {
        accumulated = 0
        lastTickAt = 0
    }
}

/// 浏览器标签
@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id: UUID
    let isIncognito: Bool

    /// 懒创建：会话恢复但尚未显示的标签不建 WebKit 实例
    private(set) lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        // 与 Safari 默认一致：静音视频可自动播放，**有声媒体必须经用户手势**。
        config.mediaTypesRequiringUserActionForPlayback = .audio
        // 无痕：非持久化数据存储，关闭即失忆
        config.websiteDataStore = isIncognito ? .nonPersistent() : .default()
        // 顶部 Safe Area：见 `ignoreViewportFitCoverScript` 的说明
        config.userContentController.addUserScript(Self.ignoreViewportFitCoverScript)
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

    /// 注入脚本：去掉页面声明的 `viewport-fit=cover`。
    private static let ignoreViewportFitCoverScript = WKUserScript(
        source: #"""
        (function () {
          'use strict';
          function strip(meta) {
            var content = meta.getAttribute('content');
            if (!content || !/viewport-fit\s*=\s*cover/i.test(content)) { return false; }
            meta.setAttribute('content', content.replace(/[,;]?\s*viewport-fit\s*=\s*cover/gi, ''));
            return true;
          }
          function sweep() {
            var metas = document.querySelectorAll('meta[name="viewport"]');
            var changed = false;
            for (var i = 0; i < metas.length; i++) {
              if (strip(metas[i])) { changed = true; }
            }
            return changed;
          }
          sweep();
          var root = document.head || document.documentElement;
          if (!root || !window.MutationObserver) { return; }
          var observer = new MutationObserver(function () {
            if (sweep()) { observer.disconnect(); }
          });
          observer.observe(root, { childList: true, subtree: true });
          window.addEventListener('DOMContentLoaded', function () {
            sweep();
            observer.disconnect();
          }, { once: true });
        })();
        """#,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )

    /// 是否为「会话恢复但尚未加载」的占位标签：不联网、不建 WebView、不挂载视图。
    @Published private(set) var isPendingRestore = false

 // MARK: - 可观察状态（KVO 驱动）

    @Published var title = ""
    @Published var currentURL: URL? {
        didSet {
            // 相同值（如重定向回原 URL）不重复触发；init 中的初始赋值不会触发 didSet
            guard currentURL != oldValue else { return }
            // 页面已经换掉：旧缩略图不再代表当前内容，清空让网格重抓
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

    /// 页面滚动计数：用户任意方向拖动页面均自增，用于将底部操作栏收起为胶囊
    @Published var scrollTick: Int = 0

    /// 忽略「当前这一轮滚动手势」剩余的收起信号
    private var suppressesScrollCollapse = false

    /// 起始页回退标记：从起始页导航进入过页面后为 `true`
    @Published private(set) var startedFromStartPage = false

    private var startPageBoundary: WKBackForwardListItem?

 // MARK: - 跨重启历史栈

    /// 含当前页在内的历史 URL（按时间顺序）。正常运行时由 `WKBackForwardList` 同步而来
    private var historyURLs: [String] = []
    /// 当前页在 `historyURLs` 中的下标；`-1` 表示无当前页（起始页）
    private var historyIndex = -1
    /// 是否由 `historyURLs` 驱动回退/前进：仅「会话恢复且历史跨进程丢失」的标签为 `true`。
    private(set) var usesRestoredHistory = false

    /// `target=_blank` / `window.open` 回调：交给 `BrowserSessionStore` 新建标签
    var onOpenNewTab: ((URL) -> Void)?

    /// 主资源加载完成回调（url, title）：记录浏览历史（无痕不记录）
    var onDidFinishVisit: ((URL, String) -> Void)?

    /// 标签状态变化回调（当前 URL 变化等）：由 `BrowserSessionStore` 订阅，驱动会话持久化
    var onStateChange: (() -> Void)?

    /// 下拉刷新控件（由 `BrowserWebView` 创建并挂到 `scrollView`）
    weak var refreshControl: UIRefreshControl?

    private var observations: [NSKeyValueObservation] = []
    /// 会话恢复的延迟加载 URL
    private var pendingLoadURL: URL?

    /// 最近一次**主动发起**导航的地址（`load` / 恢复补加载 / 历史回放）。
    private var requestedURL: URL?

    /// - Parameter autoload: 是否立即加载 `url`。
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
        self.requestedURL = url

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
        requestedURL = url   // 供失败后的「重试」重新发起同一请求
        currentURL = url   // 立即更新：隐藏起始页、刷新地址栏
        webView.load(URLRequest(url: url))
    }

 // MARK: - 可见性与媒体播放

    /// 会话恢复的延迟加载：标签首次真正显示时调用（重复调用无副作用）
    func loadPendingURLIfNeeded() {
        guard let url = pendingLoadURL else { return }
        pendingLoadURL = nil
        isPendingRestore = false   // 先置位：视图据此外挂载 WebView
        clearError()
        requestedURL = url
        webView.load(URLRequest(url: url))
    }

    /// 暂停页面内媒体播放（标签切走 / 浏览器页签不可见 / App 进入后台）。
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
        // 刷新是操作栏上的操作，**不**收起操作栏（只有滑动页面才收起，见 `scrollTick`）。
        if hasError, let url = requestedURL ?? currentURL {
            load(url)
            return
        }
        clearError()
        webView.reload()
    }

    func stopLoading() {
        webView.stopLoading()
    }

    /// 用户点击底部胶囊主动展开操作栏：本轮滚动手势剩余的回调不要再把它收回去。
    func suppressScrollCollapseForCurrentGesture() {
        suppressesScrollCollapse = true
    }

    /// 回退可用性：非起始页时总可回退（webView 历史栈可退，或可退回起始页）。
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
    }

 // MARK: - 卡片缩略图

    /// 标签卡片的预览图：由 `captureThumbnailIfNeeded()` 异步抓取，与本标签的生命周期绑定。
    @Published private(set) var thumbnail: UIImage?
    /// 当前缩略图对应的 URL：用于判断「缓存是否还能代表现在这一页」
    private var thumbnailSourceURL: String?
    /// 抓取进行中标记：同一标签只允许一次在途快照，避免打开网格时重复排队
    private var isCapturingThumbnail = false

    /// 抓取卡片缩略图（打开标签网格时按需调用，可安全重复调用）。
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

 // MARK: - 侧滑返回背景（上一页画面，Safari 风格）

    /// 页面画面缓存，key 为 URL 绝对字符串。
    private var pageSnapshots: [String: UIImage] = [:]
    /// 缓存淘汰顺序（先进先出）：只保留最近若干页，避免长会话里图片越积越多
    private var pageSnapshotOrder: [String] = []
    private static let maxPageSnapshots = 6
    /// 抓取进行中标记：同一标签只允许一张在途快照
    private var isCapturingPageSnapshot = false

    /// 下一次回退的目标页画面：无缓存返回 `nil`（调用方用白底）。
    var backTargetSnapshot: UIImage? {
        if usesRestoredHistory {
            guard historyIndex > 0, historyURLs.indices.contains(historyIndex - 1) else { return nil }
            return pageSnapshots[historyURLs[historyIndex - 1]]
        }
        guard isWebViewCreated, let item = webView.backForwardList.backItem else { return nil }
        return pageSnapshots[item.url.absoluteString]
    }

    /// 抓取当前页画面，供下次侧滑返回当背景用（`didFinish` 时调用，可安全重复调用）。
    func capturePageSnapshot(targetWidth: CGFloat = 600) {
        guard !isIncognito else { return }
        guard isWebViewCreated, !isPendingRestore else { return }
        guard let key = currentURL?.absoluteString, !isShowingStartPage else { return }
        guard !isCapturingPageSnapshot else { return }

        let size = webView.bounds.size
        // 页面还没布局（从未显示）时抓不到有效画面，等这次 `didFinish` 之后的下次加载再试
        guard size.width > 1, size.height > 1 else { return }

        isCapturingPageSnapshot = true
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: Double(targetWidth))
        configuration.rect = CGRect(origin: .zero, size: size)

        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            Task { @MainActor in
                guard let self else { return }
                self.isCapturingPageSnapshot = false
                guard let image else { return }
                // 抓取期间页面可能已经跳走：过期帧直接丢弃，否则侧滑会露出错误的页面
                guard key == self.currentURL?.absoluteString else { return }
                self.storePageSnapshot(image, for: key)
            }
        }
    }

    private func storePageSnapshot(_ image: UIImage, for key: String) {
        if pageSnapshots[key] == nil { pageSnapshotOrder.append(key) }
        pageSnapshots[key] = image
        while pageSnapshotOrder.count > Self.maxPageSnapshots {
            pageSnapshots.removeValue(forKey: pageSnapshotOrder.removeFirst())
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
        // 地址置空（回到起始页 / 加载失败）不改写栈：起始页由 `showStartPage()` 显式清空
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
        requestedURL = url
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
                Task { @MainActor [weak self] in
                    // 首次导航失败后 WebKit 会把 `url` 重置为 nil（该次导航从未提交，没有「当前页」）。
                    guard let value else { return }
                    // 已提交的页面才是「重试」该回到的地方
                    self?.requestedURL = value
                    self?.currentURL = value
                }
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
            webView.scrollView.observe(\.contentOffset, options: [.new, .old]) { [weak self] scrollView, change in
                guard scrollView.isTracking || scrollView.isDragging else {
                    dragMeter.endGesture()
                    return
                }
                // 本轮拖动的第一个回调：用来解除「主动展开后的收起抑制」
                let beginsGesture = dragMeter.beginGestureIfNeeded()
                let newY = scrollView.contentOffset.y
                let oldY = change.oldValue?.y ?? newY
                // 按「累计位移」判定而非单次增量：慢速拖动时每次回调不足 1pt
                let shouldCollapse = dragMeter.feed(newY - oldY)
                guard beginsGesture || shouldCollapse else { return }
                // 手势态与收起信号放在同一个主线程任务里处理：新手势先解除抑制，再看本次是否要收起
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if beginsGesture { self.suppressesScrollCollapse = false }
                    guard shouldCollapse, !self.suppressesScrollCollapse else { return }
                    self.scrollTick += 1
                }
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
        // 留一张当前页画面：下次侧滑返回时作为下层的「上一页」背景（Safari 风格）
        capturePageSnapshot()
        // 记录浏览历史（无痕不记录）
        if !isIncognito, let url = webView.url {
            onDidFinishVisit?(url, webView.title ?? "")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // 忽略用户主动取消（回退/停止/刷新会取消旧导航，触发 -999 NSURLErrorCancelled）
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

    /// 长按链接菜单**全部自绘**
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

/// 将 `BrowserTab` 持有的 `WKWebView` 挂到视图层级
struct BrowserWebView: UIViewRepresentable {
    let tab: BrowserTab
    var onTap: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        // 两层结构，职责分离（不要再合并成一层）
        let container = UIView()
        // 宿主必须透明：底色由位移层提供，否则侧滑露出的是这层白底
        container.backgroundColor = .clear

        // 侧滑背景（Safari 风格）：铺在网页层之下、宿主之上的「上一页」画面。
        let backdrop = UIImageView()
        backdrop.backgroundColor = .white
        backdrop.contentMode = .scaleAspectFill
        backdrop.clipsToBounds = true
        backdrop.isHidden = true
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: container.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        context.coordinator.backdropView = backdrop

        let moving = UIView()
        moving.backgroundColor = .white
        moving.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(moving)
        NSLayoutConstraint.activate([
            moving.topAnchor.constraint(equalTo: container.topAnchor),
            moving.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            moving.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            moving.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        context.coordinator.movingView = moving

        let webView = tab.webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        moving.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: moving.topAnchor),
            webView.bottomAnchor.constraint(equalTo: moving.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: moving.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: moving.trailingAnchor)
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

        // 左边缘滑动返回：全部回退场景都由本手势承担（系统 backForward 手势已关闭，见 `updateUIView`）
        let edge = UIScreenEdgePanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleEdgeSwipe(_:))
        )
        edge.edges = .left
        edge.delegate = context.coordinator
        container.addGestureRecognizer(edge)
        context.coordinator.edgeGesture = edge

        // 让页面主滚动视图等侧滑手势先失败再开始滚动：从边缘水平起手时页面不跟着上下滚
        webView.scrollView.panGestureRecognizer.require(toFail: edge)

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
        // 回退手势统一由下面的自定义边缘手势承担（保证跟手位移 + 绝不越过起始页多退一页）
        tab.webView.allowsBackForwardNavigationGestures = false
        context.coordinator.edgeGesture?.isEnabled = !tab.isShowingStartPage

        // 位移兜底：侧滑把位移层挪动过之后，若因标签切换、媒体可见性等
        let gesture = context.coordinator.edgeGesture
        let gestureActive = gesture?.state == .began || gesture?.state == .changed
        if !gestureActive, !context.coordinator.isCompletingBack,
           let moving = context.coordinator.movingView {
            if moving.transform != .identity { moving.transform = .identity }
            if moving.alpha != 1 { moving.alpha = 1 }
            // 背景层同样复位：手势被系统打断时不会走 completion，残留的白底 / 快照会
            if let backdrop = context.coordinator.backdropView, !backdrop.isHidden {
                context.coordinator.resetBackdrop()
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: BrowserWebView
        weak var edgeGesture: UIScreenEdgePanGestureRecognizer?
        /// 侧滑位移层：手势只移动它，绝不移动挂手势的宿主（见 `makeUIView` 的两层结构）
        weak var movingView: UIView?
        /// 侧滑背景层（白底 + 上一页快照），躲在 `movingView` 之下，只在手势期间显示
        weak var backdropView: UIImageView?
        /// 侧滑返回的收尾动画（回弹 / 「滑出 → 滑入」）是否仍在进行。
        private(set) var isCompletingBack = false

        /// 侧滑「代号」：每次手势 `.began` 自增。收尾动画的 completion 必须核对代号
        private var swipeGeneration = 0

        init(_ parent: BrowserWebView) { self.parent = parent }

        /// 侧滑返回：跟手位移 + 松手后完成/回弹，对齐 Safari 的交互式返回。
        @objc func handleEdgeSwipe(_ gesture: UIScreenEdgePanGestureRecognizer) {
            // `gesture.view` 是静止的宿主，只用来取尺寸与坐标空间；被移动的是 `movingView`
            guard let container = gesture.view, let moving = movingView else { return }
            let width = max(container.bounds.width, 1)
            // 位移换算基准取 **window**（退化为父视图）：位移层正被 `transform` 挪动
            let space = container.window ?? container.superview ?? container

            switch gesture.state {
            case .began:
                // 新一次起手：作废上一轮收尾动画
                swipeGeneration &+= 1
                isCompletingBack = false
                moving.layer.removeAllAnimations()
                moving.transform = .identity
                moving.alpha = 1
                // 下层背景就位：白底 or 上一页画面（见方法注释）
                prepareBackdrop()
            case .changed:
                // 夹在 [0, width]：只允许向右滑出，且最多移出一屏
                let dx = min(max(gesture.translation(in: space).x, 0), width)
                moving.transform = CGAffineTransform(translationX: dx, y: 0)
            case .ended:
                let dx = gesture.translation(in: space).x
                let velocity = gesture.velocity(in: space).x
                let progress = min(max(dx / width, 0), 1)
                // 位移过 32% 或带明显右甩速度即完成，否则回弹（比例与阈值对齐系统侧滑返回的手感）
                if progress > 0.32 || velocity > 700 {
                    completeBack(on: moving)
                } else {
                    springBack(moving)
                }
            default:
                // .cancelled / .failed（如页面被其它手势抢占）：一律回弹，不能半途换页
                springBack(moving)
            }
        }

        /// 侧滑起手时准备下层背景（Safari 风格：白底 / 上一页画面）。
        private func prepareBackdrop() {
            guard let backdrop = backdropView else { return }
            let tab = parent.tab
            guard !tab.backLeadsToStartPage else {
                backdrop.isHidden = true
                return
            }
            backdrop.image = tab.backTargetSnapshot
            backdrop.isHidden = false
        }

        /// 收尾结束：隐藏背景层并释放图片，避免长会话里一直占着整屏位图。
        func resetBackdrop() {
            guard let backdrop = backdropView else { return }
            backdrop.isHidden = true
            backdrop.image = nil
        }

        /// 未过阈值：带阻尼弹回原位（`beginFromCurrentState` 保证从当前手势位移处接着动，不跳帧）
        private func springBack(_ moving: UIView) {
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
                moving.transform = .identity
            } completion: { [weak self] _ in
                // 代号不符说明手势已重新起手，新一轮自己管自己的状态
                guard let self, generation == self.swipeGeneration else { return }
                self.isCompletingBack = false
                self.resetBackdrop()
            }
        }

        /// 过阈值：当前页整块滑出，露出下层背景，然后换页、就绪后原位淡入。
        private func completeBack(on moving: UIView) {
            guard !isCompletingBack else { return }
            isCompletingBack = true

            let width = max(moving.bounds.width, 1)
            let generation = swipeGeneration
            moving.layer.removeAllAnimations()

            // 0.22s：比旧的 0.18s 略长，滑出末段更能「收住」，与 Safari 的松手收尾接近
            UIView.animate(
                withDuration: 0.22,
                delay: 0,
                options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
            ) {
                moving.transform = CGAffineTransform(translationX: width, y: 0)
            } completion: { [weak self] _ in
                guard let self, generation == self.swipeGeneration else { return }
                self.parent.tab.goBack()

                // 起始页分支：**不要**在这里把位移层挪回屏内。`goBack()` 只是切了标签的状态
                if self.parent.tab.isShowingStartPage {
                    moving.alpha = 1
                    self.isCompletingBack = false
                    // 保底归位：正常路径是「起始页插入后的那次 SwiftUI 更新」由 `updateUIView` 兜底归位
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak moving] in
                        guard let moving, let self, generation == self.swipeGeneration else { return }
                        moving.transform = .identity
                        self.resetBackdrop()
                    }
                    return
                }

                self.revealWhenPageReady(on: moving, width: width, generation: generation, attempt: 0)
            }
        }

        /// 等回退后的页面真正就绪（`isLoading` 落下，最多约 0.4s）后**原位淡入**。
        private func revealWhenPageReady(
            on moving: UIView,
            width: CGFloat,
            generation: Int,
            attempt: Int
        ) {
            guard generation == swipeGeneration else { return }
            let tab = parent.tab
            // 首轮先让出一帧多：`goBack()` 触发的是 next runloop 的导航状态更新
            let delay: TimeInterval = attempt == 0 ? 0.05 : 0.02
            if (attempt == 0 || tab.isLoading), attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.revealWhenPageReady(on: moving, width: width, generation: generation, attempt: attempt + 1)
                }
                return
            }

            moving.transform = .identity
            moving.alpha = 0
            UIView.animate(
                withDuration: 0.16,
                delay: 0,
                options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
            ) {
                moving.alpha = 1
            } completion: { [weak self] _ in
                guard let self, generation == self.swipeGeneration else { return }
                self.isCompletingBack = false
                self.resetBackdrop()
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            // 点击页面任意处（含空白）：先收起键盘/退出地址栏编辑，再展开操作栏
            Keyboard.dismiss()
            parent.onTap?()
        }

        @objc func handleRefresh(_ sender: UIRefreshControl) {
            // 已加载页面则重新加载（加载完成后由 isLoading KVO 收起动画）
            if parent.tab.currentURL != nil {
                parent.tab.reload()
            } else {
                sender.endRefreshing()
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // 只让「点击页面」与其它手势共存（点链接 / 表单需要它不抢触摸）
            g is UITapGestureRecognizer || other is UITapGestureRecognizer
        }

        /// 方向分流：只有「横向起手」才认侧滑，纵向起手直接放弃，把手势让回页面滚动
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return true }
            guard g === edgeGesture else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}

/// 标签会话快照（持久化用，无痕标签不参与）
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
