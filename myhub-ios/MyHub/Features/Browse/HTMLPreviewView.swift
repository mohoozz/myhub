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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AppColors.separator)

            ZStack {
                if let url {
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
                }

                if isLoading, loadError == nil {
                    ProgressView()
                        .controlSize(.large)
                        .padding(20)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                if let loadError {
                    errorView(loadError)
                        .background(AppColors.pageBackground)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppColors.pageBackground)
        .task { startIfNeeded() }
        .onDisappear { HTMLPreviewServer.shared.unregister() }
    }

// MARK: - 顶部栏

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(AppColors.fieldFill)
                    .clipShape(Circle())
            }
            .buttonStyle(.pressScale)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("网页预览")
                    .font(.caption2)
                    .foregroundStyle(AppColors.textSecondary)
            }

            Spacer(minLength: 0)

            Button(action: reload) {
                Image(systemName: "arrow.clockwise")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressScale)
            .disabled(url == nil)
            .opacity(url == nil ? 0.4 : 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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
