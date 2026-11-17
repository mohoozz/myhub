import SwiftUI

/// 单个标签的浏览视图（TODO §8.1，IOS-401）：
/// 封装 `WKWebView` + 2px 加载进度条 + 错误页（失败/SSL + 重试）。
struct BrowserView: View {
    @ObservedObject var tab: BrowserTab
    var onTap: (() -> Void)? = nil

    var body: some View {
        ZStack {
            // 侧滑返回起始页时的「上一页」预览（TODO 421）：常驻在网页层之下，被不透明的网页
            // 完全盖住，平时看不见。边缘滑动时由 UIKit 侧把网页容器整块右移，它便被逐帧露出——
            // 于是「一松手画面瞬间跳过去」变成「上一页跟着手指一点点移进来」。
            // 放在这一层（而不是手势回调里逐帧改 SwiftUI 状态）是为了零逐帧重绘：
            // 位移全在 UIKit 的 `transform` 上完成，SwiftUI 只在状态翻转时刷新一次。
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
    ///
    /// `backLeadsToStartPage` 会读 `webView`（`lazy`），必须在占位恢复标签上短路，
    /// 否则会在标签尚未显示时提前拉起 WebContent 进程（与 TODO 418 的延迟加载相悖）。
    ///
    /// 只在「下一步回退就是起始页」时挂载，预览必然在需要它的那一刻已经就位；
    /// 其余页面（页面间回退）不挂，避免每个标签都常驻一份起始页视图——这类页面侧滑时
    /// 露出的是页面底色，收尾时等新页面就绪后再滑入（见 `Coordinator.slideInWhenPageReady`）。
    private var showsStartPagePreview: Bool {
        !tab.isPendingRestore && !tab.isShowingStartPage && tab.backLeadsToStartPage
    }
}

/// 地址栏下方 2px 蓝色加载进度条（`estimatedProgress` KVO，IOS-401）
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

/// 加载失败 / SSL 错误页 + 重试（IOS-401）
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
