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
                BrowserErrorView(tab: tab)
            }
        }
        .overlay(alignment: .top) {
            if tab.isLoading && tab.estimatedProgress < 1 {
                BrowserProgressBar(progress: tab.estimatedProgress)
            }
        }
        .animation(.linear(duration: 0.2), value: tab.estimatedProgress)
        // 页面里点到 itms-apps:// 之类的外部 scheme：不自动弹 App，先问一句
        .alert(
            "需要在其他 App 中打开",
            isPresented: Binding(
                get: { tab.pendingExternalURL != nil },
                set: { presented in
                    if !presented { tab.cancelPendingExternalURL() }
                }
            ),
            presenting: tab.pendingExternalURL
        ) { url in
            Button("在「\(externalAppName(for: url))」中打开") {
                tab.confirmOpenExternally(url)
            }
            Button("取消", role: .cancel) {
                tab.cancelPendingExternalURL()
            }
        } message: { url in
            Text("内置浏览器无法直接加载这个链接，是否交给「\(externalAppName(for: url))」打开？")
        }
    }

    /// 外部 scheme 对应的 App 名称，用于提示文案
    private func externalAppName(for url: URL) -> String {
        switch url.scheme?.lowercased() ?? "" {
        case "itms-apps", "itms", "itms-services", "macappstore": return "App Store"
        case "tel", "telprompt": return "电话"
        case "sms": return "信息"
        case "mailto": return "邮件"
        case "maps": return "地图"
        case "weixin", "wechat": return "微信"
        case "alipay", "alipays": return "支付宝"
        default: return "系统 App"
        }
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

/// 加载失败 / SSL 错误页：可重试的失败给「重试」，不支持的外部 scheme 给「用系统打开」，
/// 两种情况都提供「返回」，保证错误页永远能退出去。
struct BrowserErrorView: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(AppColors.textPrimary)
            if let message = tab.errorMessage, !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            HStack(spacing: 12) {
                if tab.isUnsupportedURL {
                    // 外部 scheme（App Store 等）：重试必然再失败，改为交给系统，与 Safari 一致
                    Button("用系统打开") { tab.openFailedURLExternally() }
                        .buttonStyle(.borderedProminent)
                        .tint(AppColors.primary)
                } else {
                    Button("重试") { tab.reload() }
                        .buttonStyle(.borderedProminent)
                        .tint(AppColors.primary)
                }
                if tab.canGoBackOrStartPage {
                    Button("返回") { tab.goBack() }
                        .buttonStyle(.bordered)
                        .tint(AppColors.primary)
                }
            }
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 背景只做视觉：左侧 24pt 不参与命中测试，侧滑返回手势才能穿透到 WebView 容器。
        // 否则错误页会把手势整层挡住（错误态下侧滑完全失效，无法退回上一页）。
        .background {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: 24)
                    .allowsHitTesting(false)
                AppColors.pageBackground
            }
            .ignoresSafeArea()
        }
    }

    private var iconName: String {
        if tab.isSSLError { return "lock.slash.fill" }
        if tab.isUnsupportedURL { return "arrow.up.forward.app" }
        return "wifi.slash"
    }

    private var title: String {
        if tab.isSSLError { return "连接不安全" }
        if tab.isUnsupportedURL { return "这个链接需要在 App 中打开" }
        return "无法打开网页"
    }
}
