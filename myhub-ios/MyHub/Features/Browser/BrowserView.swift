import SwiftUI

/// 单个标签的浏览视图
/// 封装 `WKWebView` + 2px 加载进度条 + 错误页（失败/SSL + 重试）。
struct BrowserView: View {
    @ObservedObject var tab: BrowserTab
    var onTap: (() -> Void)? = nil

    var body: some View {
        ZStack {
            // 侧滑返回起始页时的「上一页」预览：常驻在网页层之下，被不透明的网页
            if showsStartPagePreview {
                StartPage { url in
                    tab.load(url)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

            BrowserWebView(tab: tab, onTap: onTap)

            // 起始页：空白标签（未加载 URL）时显示
            if tab.isShowingStartPage {
                StartPage { url in
                    tab.load(url)
                }
                .transition(.opacity)
            }

            if tab.hasError {
                BrowserErrorView(
                    isSSL: tab.isSSLError,
                    message: tab.errorMessage,
                    onRetry: { tab.reload() }
                )
            }
        }
        .overlay(alignment: .top) {
            if tab.isLoading && tab.estimatedProgress < 1 {
                BrowserProgressBar(progress: tab.estimatedProgress)
            }
        }
        .animation(.linear(duration: 0.2), value: tab.estimatedProgress)
    }

    /// 是否需要在网页层之下预挂起始页（侧滑返回预览）。
    private var showsStartPagePreview: Bool {
        !tab.isPendingRestore && !tab.isShowingStartPage && tab.backLeadsToStartPage
    }
}

/// 地址栏下方 2px 蓝色加载进度条（`estimatedProgress` KVO）
private struct BrowserProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(AppColors.primary)
                .frame(width: max(0, geo.size.width * progress))
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}

/// 加载失败 / SSL 错误页 + 重试
struct BrowserErrorView: View {
    let isSSL: Bool
    let message: String?
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: isSSL ? "lock.slash.fill" : "wifi.slash")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(isSSL ? "连接不安全" : "无法打开网页")
                .font(.headline)
                .foregroundStyle(AppColors.textPrimary)
            if let message, !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Button("重试", action: onRetry)
                .buttonStyle(.borderedProminent)
                .tint(AppColors.primary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.pageBackground)
    }
}
