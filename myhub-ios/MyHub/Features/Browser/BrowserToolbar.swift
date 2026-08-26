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

    var body: some View {
        HStack(spacing: 6) {
            navButton("chevron.left", disabled: !tab.canGoBack) { tab.goBack() }
            navButton("chevron.right", disabled: !tab.canGoForward) { tab.goForward() }
            navButton(tab.isLoading ? "xmark" : "arrow.clockwise", disabled: false) {
                if tab.isLoading { tab.stopLoading() } else { tab.reload() }
            }

            // 地址栏占中间弹性宽度（单行内居中）；起始页（空白标签）自带大搜索框时退化为占位
            if !tab.isShowingStartPage {
                AddressBar(tab: tab) { url in
                    onSubmitAddress(url)
                }
                .frame(maxWidth: .infinity)
            } else {
                Spacer(minLength: 8)
            }

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
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressScale)

            // 菜单
            PopupMenuButton(items: menuItems)
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
                .frame(width: 44, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressScale)
        .foregroundStyle(disabled ? AppColors.textSecondary.opacity(0.35) : AppColors.textPrimary)
        .disabled(disabled)
    }
}
