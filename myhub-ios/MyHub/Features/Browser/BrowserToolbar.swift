import SwiftUI

/// 底部操作栏（TODO §8.2，IOS-401）：
/// 一行整合：后退 / 前进 / 刷新（加载中变停止）+ 居中地址栏 + 标签 / 菜单。
/// 地址栏起始页（自带大搜索框）时隐藏并退化为占位；后退/前进按钮依据 `canGoBack` / `canGoForward` 动态启用；「菜单」走全局 `PopupMenu`。
struct BrowserToolbar: View {
    @ObservedObject var tab: BrowserTab
    let tabCount: Int
    let menuItems: [PopupMenuItem]
    let onTabs: () -> Void
    /// 地址栏提交（导航）回调：由父视图交给 `BrowserSessionStore.open`
    let onSubmitAddress: (URL) -> Void

    /// 左（后退/前进/刷新）/ 右（标签/菜单）按钮区等宽，保证地址栏严格居中；
    /// 宽度 = 3 个导航按钮 + 间距（右侧按钮更少，靠屏幕边缘对齐，左侧留白对称）
    private let sideAreaWidth: CGFloat = 38 * 3 + 2 * 2

    var body: some View {
        HStack(spacing: 2) {
            // 左区：后退 / 前进 / 刷新（加载中变停止），紧凑排列
            HStack(spacing: 2) {
                navButton("chevron.left", disabled: !tab.canGoBackOrStartPage) { tab.goBack() }
                navButton("chevron.right", disabled: !tab.canGoForward) { tab.goForward() }
                navButton(tab.isLoading ? "xmark" : "arrow.clockwise", disabled: false) {
                    if tab.isLoading { tab.stopLoading() } else { tab.reload() }
                }
            }
            .frame(width: sideAreaWidth, alignment: .leading)

            // 中区：地址栏弹性占满，配合左右等宽按钮区严格居中；
            // 起始页（空白标签）自带大搜索框时退化为占位
            if !tab.isShowingStartPage {
                AddressBar(tab: tab) { url in
                    onSubmitAddress(url)
                }
                .frame(maxWidth: .infinity)
            } else {
                Spacer(minLength: 8)
            }

            // 右区：标签（显示当前标签数）/ 菜单，与左区等宽（右对齐）
            HStack(spacing: 2) {
                Button(action: onTabs) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.on.square")
                            .font(.subheadline)
                        Text("\(tabCount)")
                            .font(.subheadline.monospacedDigit())
                    }
                    .foregroundStyle(AppColors.textPrimary)
                    .frame(height: 40)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ToolbarButtonStyle())

                PopupMenuButton(items: menuItems)
            }
            .frame(width: sideAreaWidth, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
        .background(AppColors.cardBackground.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Divider().overlay(AppColors.separator) }
        .animation(.appFast, value: tab.isShowingStartPage)
    }

    private func navButton(_ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .frame(width: 38, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(ToolbarButtonStyle())
        .foregroundStyle(disabled ? AppColors.textSecondary.opacity(0.35) : AppColors.textPrimary)
        .disabled(disabled)
    }
}

/// 浏览器底部工具栏按钮按压样式（TODO §8.2）：
/// 按压缩放 + 浅蓝背景高亮，点击反馈比全局 `.pressScale`（0.97）更明显
private struct ToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? AppColors.primary.opacity(0.16) : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.appFast, value: configuration.isPressed)
    }
}
