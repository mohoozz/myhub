import SwiftUI
import WebKit

/// 浏览器标签（TODO §8.1，IOS-401）：
/// 每个标签持有一个 `WKWebView` 实例，切换标签时不销毁视图，从而保持导航历史栈
/// （back/forward）不因标签切换或 URL 重建而丢失；无痕标签使用独立的 `nonPersistent`
/// 数据存储，不落盘。
@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id: UUID
    let isIncognito: Bool
    let webView: WKWebView

    // MARK: - 可观察状态（KVO 驱动）

    @Published var title = ""
    @Published var currentURL: URL? {
        didSet {
            // 相同值（如重定向回原 URL）不重复触发；init 中的初始赋值不会触发 didSet
            guard currentURL != oldValue else { return }
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

    /// 页面向上滚动（手指上滑）标志：用于收起底部操作栏（TODO §8.2）
    @Published var isScrollingUp = false

    /// 起始页回退标记：从起始页导航进入过页面后为 `true`，
    /// 使「回退」按钮在 webView 历史为空时仍可返回到起始页（Safari 行为）
    @Published private(set) var startedFromStartPage = false

    /// `target=_blank` / `window.open` 回调：交给 `BrowserSessionStore` 新建标签
    var onOpenNewTab: ((URL) -> Void)?

    /// 主资源加载完成回调（url, title）：记录浏览历史（无痕不记录，TODO §8.3）
    var onDidFinishVisit: ((URL, String) -> Void)?

    /// 标签状态变化回调（当前 URL 变化等）：由 `BrowserSessionStore` 订阅，驱动会话持久化，
    /// 保证「导航后直接退出」也能保存上一次打开的页面
    var onStateChange: (() -> Void)?

    private var observations: [NSKeyValueObservation] = []

    init(id: UUID = UUID(), url: URL?, isIncognito: Bool) {
        self.id = id
        self.isIncognito = isIncognito

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // 无痕：非持久化数据存储，关闭即失忆
        config.websiteDataStore = isIncognito ? .nonPersistent() : .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = Self.userAgentString()
        self.webView = webView

        super.init()

        self.currentURL = url
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observe()

        if let url {
            webView.load(URLRequest(url: url))
        }
    }

    // MARK: - 导航操作

    func load(_ url: URL) {
        // 从起始页导航进入页面：起始页成为可回退的第一页（需在 currentURL 更新前判断）
        if isShowingStartPage {
            startedFromStartPage = true
        }
        clearError()
        currentURL = url   // 立即更新：隐藏起始页、刷新地址栏
        webView.load(URLRequest(url: url))
    }

    func reload() {
        clearError()
        webView.reload()
    }

    func stopLoading() {
        webView.stopLoading()
    }

    /// 回退可用性：webView 历史栈可回退，或当前位于「从起始页进入」的页面（可回退到起始页）
    var canGoBackOrStartPage: Bool {
        webView.canGoBack || (startedFromStartPage && !isShowingStartPage)
    }

    /// 回退：优先走 webView 历史栈；栈空且从起始页进入时回退到起始页
    func goBack() {
        if webView.canGoBack {
            webView.goBack()
        } else if startedFromStartPage, !isShowingStartPage {
            showStartPage()
        }
    }

    func goForward() { webView.goForward() }

    /// 回退到起始页：清空 URL 展示起始页，并清空 webView 导航历史，
    /// 使下一次从起始页的导航成为新的历史根，避免残留旧历史
    private func showStartPage() {
        startedFromStartPage = false
        currentURL = nil
        if #available(iOS 15.0, *) {
            webView.backForwardList.removeAllItems()
        }
    }

    /// 展示标签卡片网格所需的快照（用于持久化）
    var snapshot: BrowserTabSnapshot {
        BrowserTabSnapshot(id: id, urlString: currentURL?.absoluteString, title: title)
    }

    /// 是否显示起始页（空白标签：未加载 URL 且无错误）
    var isShowingStartPage: Bool {
        currentURL == nil && !isLoading && !hasError
    }

    // MARK: - KVO

    private func observe() {
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
                Task { @MainActor [weak self] in self?.isLoading = value }
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
            // 滚动方向：手指上滑 = 收起操作栏（缩小为胶囊），下滑 = 展开；
            // 下滑（含滚回顶部回弹区）始终恢复展开，避免操作栏收起后无法恢复
            webView.scrollView.observe(\.contentOffset, options: [.new, .old]) { [weak self] scrollView, change in
                let newY = scrollView.contentOffset.y
                let oldY = change.oldValue?.y ?? newY
                let delta = newY - oldY
                // 忽略微小抖动
                guard abs(delta) > 2 else { return }
                if delta < 0 {
                    Task { @MainActor [weak self] in self?.isScrollingUp = false }
                } else if newY > 0 {
                    // 手指上滑且非顶部回弹区：收起
                    Task { @MainActor [weak self] in self?.isScrollingUp = true }
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
}

// MARK: - SwiftUI 封装

/// 将 `BrowserTab` 持有的 `WKWebView` 挂到视图层级（标签保活：由 `ZStack` 常驻所有标签，
/// 仅切换透明度而非销毁重建，从而保持导航历史栈）。
/// 附带手势：左边缘滑动（历史栈空时退出页签）、点击页面（展开被收起的操作栏）。
struct BrowserWebView: UIViewRepresentable {
    let tab: BrowserTab
    var onEdgeSwipeBack: (() -> Void)? = nil
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

        // 左边缘滑动：历史栈非空交给系统 backForward 手势；为空时退出页签
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
        // 历史栈空时启用边缘手势；非空时系统 backForward 手势已接管侧滑返回
        context.coordinator.edgeGesture?.isEnabled = !tab.canGoBack
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: BrowserWebView
        weak var edgeGesture: UIScreenEdgePanGestureRecognizer?

        init(_ parent: BrowserWebView) { self.parent = parent }

        @objc func handleEdgeSwipe(_ gesture: UIScreenEdgePanGestureRecognizer) {
            guard gesture.state == .ended else { return }
            if parent.tab.canGoBack {
                parent.tab.goBack()
            } else {
                parent.onEdgeSwipeBack?()
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            // 点击页面任意处（含空白）：先收起键盘/退出地址栏编辑，再展开操作栏
            Keyboard.dismiss()
            parent.onTap?()
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// 标签会话快照（持久化用，仅保存 URL/标题，无痕标签不参与）
struct BrowserTabSnapshot: Codable {
    let id: UUID
    let urlString: String?
    let title: String
}
