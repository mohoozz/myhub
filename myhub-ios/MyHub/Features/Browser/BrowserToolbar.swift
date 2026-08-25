import SwiftUI

/// 底部操作栏（TODO §8.2，IOS-401）：
/// 后退 / 前进 / 刷新（加载中变停止）/ 标签 / 菜单。
/// 后退/前进按钮依据 `canGoBack` / `canGoForward` 动态启用；「菜单」走全局 `PopupMenu`。
struct BrowserToolbar: View {
    @ObservedObject var tab: BrowserTab
    let tabCount: Int
    let menuItems: [PopupMenuItem]
    let onTabs: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            navButton("chevron.left", disabled: !tab.canGoBack) { tab.goBack() }
            navButton("chevron.right", disabled: !tab.canGoForward) { tab.goForward() }
            navButton(tab.isLoading ? "xmark" : "arrow.clockwise", disabled: false) {
                if tab.isLoading { tab.stopLoading() } else { tab.reload() }
            }

            Spacer()

            // 标签按钮（显示当前标签数）
            Button(action: onTabs) {
                HStack(spacing: 4) {
                    Image(systemName: "square.on.square")
                        .font(.subheadline)
                    Text("\(tabCount)")
                        .font(.subheadline.monospacedDigit())
                }
                .foregroundStyle(AppColors.textPrimary)
                .frame(height: 40)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressScale)

            // 菜单
            PopupMenuButton(items: menuItems)
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
        .background(AppColors.cardBackground.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Divider().overlay(AppColors.separator) }
    }

    private func navButton(_ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .frame(width: 44, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressScale)
        .foregroundStyle(disabled ? AppColors.textSecondary.opacity(0.35) : AppColors.textPrimary)
        .disabled(disabled)
    }
}
