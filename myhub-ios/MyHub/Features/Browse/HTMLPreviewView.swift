import SwiftUI
import WebKit

/// HTML 网页预览（浏览界面直接弹出的全屏预览框，不占用内置浏览器页签）。
///
/// 页面由 `HTMLPreviewServer` 经回环静态服务提供：站点根 = 该 HTML 所在目录，
/// 因此同目录的 css / js / 图片 / 字体等相对资源都能正常加载（本地与远程连接源一致）。
struct HTMLPreviewView: View {
    let entry: FileEntry
    let adapter: StorageAdapter

    /// 可预览的网页扩展名
    static let supportedExtensions: Set<String> = ["html", "htm"]

    static func supports(_ entry: FileEntry) -> Bool {
        !entry.isDir && supportedExtensions.contains(entry.ext.lowercased())
    }

    @Environment(\.dismiss) private var dismiss
    @State private var url: URL?
    @State private var startError: String?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var reloadToken = 0
    /// 侧滑退出的横向位移
    @State private var edgeDragOffset: CGFloat = 0

    var body: some View {
        // 用 GeometryReader 拿真实安全区：整屏铺满（不留白边），顶栏按 inset 自己让位
        GeometryReader { proxy in
            ZStack {
                // 侧滑退出时露出的底衬（固定不动）
                AppColors.pageBackground

                movingLayer(insets: proxy.safeAreaInsets)
            }
            .ignoresSafeArea()
        }
        .background(edgeSwipeBack)
        .task { startIfNeeded() }
        .onDisappear { HTMLPreviewServer.shared.unregister() }
    }

    /// 随侧滑整体右移的内容层：网页 + 状态浮层 + 悬浮顶栏
    private func movingLayer(insets: EdgeInsets) -> some View {
        ZStack(alignment: .top) {
            content

            // url 未就绪时 content 自己已经有指示器，避免叠两个
            if isLoading, loadError == nil, url != nil {
                ProgressView()
                    .controlSize(.large)
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let loadError {
                errorView(loadError)
                    .background(AppColors.pageBackground)
            }

            // 顶栏浮在网页上（透明毛玻璃），不占内容高度
            header(insets: insets)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(x: edgeDragOffset)
    }

    @ViewBuilder
    private var content: some View {
        if let url {
            // 整屏交给网页：铺到状态栏与 Home 指示条下面
            HTMLWebView(
                url: url,
                reloadToken: reloadToken,
                isLoading: $isLoading,
                loadError: $loadError
            )
        } else if let startError {
            errorView(startError)
        } else {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

// MARK: - 侧滑退出（fullScreenCover 无系统侧滑返回，补一个屏幕左边缘右滑手势）

    private var edgeSwipeBack: some View {
        EdgeSwipeBack(
            // WKWebView 自身是滚动视图：必须关掉滚动优先，否则边缘手势会被它的 pan 吞掉
            scrollViewTakesPriority: false,
            onChanged: { translation in
                edgeDragOffset = max(0, translation)
            },
            onEnded: { translation, velocity in
                let screenWidth = UIScreen.main.bounds.width
                // 灵敏判定：位移过 1/4 屏宽，或向右快速轻扫即退出
                if translation > screenWidth * 0.25 || velocity > 600 {
                    withAnimation(.appQuick) { edgeDragOffset = screenWidth }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        dismiss()
                    }
                } else {
                    withAnimation(.appQuick) { edgeDragOffset = 0 }
                }
            }
        )
    }

// MARK: - 悬浮顶栏（透明毛玻璃，对齐漫画阅读器的控制层）

    private func header(insets: EdgeInsets) -> some View {
        HStack(spacing: 2) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressScale)

            Text(entry.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 6)

            Button(action: reload) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressScale)
            .disabled(url == nil)
            .opacity(url == nil ? 0.35 : 1)
        }
        .foregroundStyle(AppColors.textPrimary)
        // 顶栏内容避开状态栏 / 横屏刘海，毛玻璃底仍从屏幕最顶端铺下来
        .padding(.horizontal, max(10, insets.leading))
        .padding(.top, insets.top + 2)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(AppColors.textSecondary)
            Text("网页打开失败")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppColors.textPrimary)
            Text(message)
                .font(.caption)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("重试", action: reload)
                .font(.subheadline.weight(.medium))
                .buttonStyle(.pressScale)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

// MARK: - 动作

    private func startIfNeeded() {
        guard url == nil, startError == nil else { return }
        do {
            url = try HTMLPreviewServer.shared.register(entry: entry, adapter: adapter)
            isLoading = true
        } catch {
            startError = error.localizedDescription
            isLoading = false
        }
    }

    private func reload() {
        if url == nil {
            startError = nil
            startIfNeeded()
            return
        }
        loadError = nil
        reloadToken += 1
    }
}

// MARK: - WKWebView 包装

private struct HTMLWebView: UIViewRepresentable {
    let url: URL
    let reloadToken: Int
    @Binding var isLoading: Bool
    @Binding var loadError: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        // 与 Safari 默认一致：有声媒体需用户手势
        config.mediaTypesRequiringUserActionForPlayback = .audio
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // 铺满整屏（含安全区）时不要再被自动内缩，否则底部/顶部会露出底色白边
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.load(url, in: webView, token: reloadToken)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.load(url, in: webView, token: reloadToken)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: HTMLWebView
        private var loadedToken: Int?
        private var loadedURL: URL?

        init(_ parent: HTMLWebView) {
            self.parent = parent
        }

        func load(_ url: URL, in webView: WKWebView, token: Int) {
            guard loadedToken != token || loadedURL != url else { return }
            loadedToken = token
            loadedURL = url
            // 首帧给一个加载指示；此后（刷新/页内跳转）保留旧内容直到新页面到达，避免闪烁
            if webView.url == nil {
                DispatchQueue.main.async { self.parent.isLoading = true }
            }
            webView.load(URLRequest(url: url))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.loadError = nil
            }
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
        ) {
            handle(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handle(error)
        }

        private func handle(_ error: Error) {
            let nsError = error as NSError
            // 导航被新请求打断（快速重试 / 关闭）不算失败
            guard nsError.code != NSURLErrorCancelled else { return }
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.loadError = error.localizedDescription
            }
        }
    }
}
