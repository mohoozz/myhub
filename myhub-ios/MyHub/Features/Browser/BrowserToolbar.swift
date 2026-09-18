import SwiftUI

/// 底部操作栏（TODO §8.2，IOS-401；TODO 377 方案 A「悬浮单胶囊」）：
/// 一行整合：后退 / 前进 / 刷新（加载中变停止）+ 地址栏 + 标签 / 菜单，
/// 整体为与全局悬浮页签栏同语言的圆角胶囊（内缩 12pt、圆角 26、1pt 灰描边 + 轻阴影）；
/// 内部导航键用弱填充圆底、地址栏为胶囊内浅灰填充块。
/// 地址栏起始页（自带大搜索框）时隐藏并退化为占位；后退/前进按钮依据 `canGoBack` / `canGoForward` 动态启用；「菜单」走全局 `PopupMenu`。
struct BrowserToolbar: View {
    @ObservedObject var tab: BrowserTab
    let tabCount: Int
    let menuItems: [PopupMenuItem]
    let onTabs: () -> Void
    /// 地址栏提交（导航）回调：由父视图交给 `BrowserSessionStore.open`
    let onSubmitAddress: (URL) -> Void

    /// 胶囊圆角 / 条高：与全局页签栏（26 / 56）同一圆角语言，略矮以让出网页可视区
    private let cornerRadius: CGFloat = 26
    private let barHeight: CGFloat = 52

    var body: some View {
        HStack(spacing: 4) {
            // 左区：后退 / 前进 / 刷新（加载中变停止），弱填充圆底
            HStack(spacing: 2) {
                navButton("chevron.left", disabled: !tab.canGoBackOrStartPage) { tab.goBack() }
                navButton("chevron.right", disabled: !tab.canGoForward) { tab.goForward() }
                navButton(tab.isLoading ? "xmark" : "arrow.clockwise", disabled: false) {
                    if tab.isLoading { tab.stopLoading() } else { tab.reload() }
                }
            }

            // 中区：地址栏弹性占满（胶囊内浅灰填充块）；
            // 起始页（空白标签）自带大搜索框时退化为占位
            if !tab.isShowingStartPage {
                AddressBar(tab: tab) { url in
                    onSubmitAddress(url)
                }
                .frame(maxWidth: .infinity)
            } else {
                Spacer(minLength: 8)
            }

            // 右区：标签数 chip / 菜单
            HStack(spacing: 4) {
                Button(action: onTabs) {
                    HStack(spacing: 3) {
                        Image(systemName: "square.on.square")
                            .font(.system(size: 13, weight: .medium))
                        Text("\(tabCount)")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(AppColors.textPrimary)
                    .frame(height: 36)
                    .padding(.horizontal, 8)
                    .contentShape(Capsule())
                }
                .buttonStyle(ToolbarButtonStyle(cornerRadius: 18))
                .background(Capsule().fill(AppColors.fieldFill))
                .accessibilityLabel("标签页（\(tabCount)）")

                PopupMenuButton(items: menuItems)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: barHeight)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppColors.cardBackground)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // 1pt 极浅描边：白底主界面下与内容分割（与全局悬浮页签栏 / mini 播放器统一为 cardBorder，TODO 376/379）
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(AppColors.cardBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        // 左右内缩 12pt：与全局悬浮页签栏对齐，形成上下「双胶囊」节奏
        .padding(.horizontal, 12)
        .animation(.appFast, value: tab.isShowingStartPage)
    }

    private func navButton(_ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 34, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(ToolbarButtonStyle(cornerRadius: 22))
        .foregroundStyle(disabled ? AppColors.textSecondary.opacity(0.35) : AppColors.textPrimary)
        .disabled(disabled)
    }
}

/// 浏览器底部工具栏按钮按压样式（TODO §8.2，TODO 377 方案 A 圆角胶囊）：
/// 按压缩放 + 浅蓝圆底高亮（圆角取控件一半高度，形成「弱填充圆底」），点击反馈比全局 `.pressScale`（0.97）更明显
private struct ToolbarButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 22

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(configuration.isPressed ? AppColors.primary.opacity(0.16) : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.appFast, value: configuration.isPressed)
    }
}
