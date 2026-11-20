import SwiftUI

/// 底部操作栏
/// 一行整合：后退 / 前进 / 刷新（加载中变停止）+ 地址栏 + 标签 / 菜单
struct BrowserToolbar: View {
    @ObservedObject var tab: BrowserTab
    let tabCount: Int
    let menuItems: [PopupMenuItem]
    /// 底部浮层共享的形变命名空间：与收起态小胶囊共用同一身份
    let morphNamespace: Namespace.ID?
    let onTabs: () -> Void
    /// 地址栏是否处于编辑态（由父级持有，Safari 风格整条变输入框）
    @Binding var isEditingAddress: Bool
    /// 地址栏提交（导航）回调：由父视图交给 `BrowserSessionStore.open`
    let onSubmitAddress: (URL) -> Void

    /// 条高对齐 Safari 底部操作栏尺度：原 52pt 下内部控件仅 34~38pt
    static let barHeight: CGFloat = 60

    var body: some View {
        // 子视图位置保持恒定（左区条件插入 / 右区 if-else 二选一，地址栏固定在第二位）
        HStack(spacing: 4) {
            // 左区：后退 / 前进 / 刷新（加载中变停止），弱填充圆底
            if !isEditingAddress {
                HStack(spacing: 2) {
                    navButton("chevron.left", disabled: !tab.canGoBackOrStartPage) { tab.goBack() }
                    navButton("chevron.right", disabled: !tab.canGoForwardOrHistory) { tab.goForward() }
                    navButton(tab.isLoading ? "xmark" : "arrow.clockwise", disabled: false) {
                        if tab.isLoading { tab.stopLoading() } else { tab.reload() }
                    }
                }
                .transition(.opacity)
            }

            // 中区：地址栏弹性占满（胶囊内浅灰填充块）；编辑态下即铺满整条的输入框
            if !tab.isShowingStartPage {
                AddressBar(tab: tab, isEditing: $isEditingAddress) { url in
                    onSubmitAddress(url)
                }
                .frame(maxWidth: .infinity)
            } else {
                Spacer(minLength: 8)
            }

            // 右区：编辑态为「取消」，否则标签数 chip / 菜单
            if isEditingAddress {
                cancelButton
                    .transition(.opacity)
            } else {
                HStack(spacing: 4) {
                    Button(action: onTabs) {
                        HStack(spacing: 3) {
                            Image(systemName: "square.on.square")
                                .font(.system(size: 15, weight: .medium))
                            Text("\(tabCount)")
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        }
                        .foregroundStyle(AppColors.textPrimary)
                        .frame(height: 46)
                        .padding(.horizontal, 10)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(ToolbarButtonStyle(cornerRadius: 23))
                    .background(Capsule().fill(AppColors.fieldFill))
                    .accessibilityLabel("标签页（\(tabCount)）")

                    // 全局菜单键默认 32pt 偏小，此处显式撑到 38×48 与导航键同格
                    PopupMenuButton(items: menuItems, size: CGSize(width: 38, height: 48))
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: Self.barHeight)
        .clipShape(Capsule())
        // 胶囊底（白底 + 1pt 描边 + 轻阴影）由 `ChromeCapsule` 统一绘制
        .background { ChromeCapsule(morphNamespace: morphNamespace) }
        // 左右内缩 12pt：与全局悬浮页签栏对齐，形成上下「双胶囊」节奏
        .padding(.horizontal, 12)
        .animation(.appFast, value: tab.isShowingStartPage)
        .animation(.appFast, value: isEditingAddress)
    }

    /// 编辑态右侧「取消」：退出编辑并收起键盘（地址栏文本不提交，地址回落为当前页域名）
    private var cancelButton: some View {
        Button {
            isEditingAddress = false
        } label: {
            Text("取消")
                .font(.subheadline)
                .foregroundStyle(AppColors.primary)
                .frame(height: 46)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(ToolbarButtonStyle(cornerRadius: 23))
        .accessibilityLabel("取消编辑网址")
    }

    private func navButton(_ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                // 38×48 触控格：高度满足 iOS 44pt 下限，宽度在单行内为地址栏留出余量
                .frame(width: 38, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(ToolbarButtonStyle(cornerRadius: 24))
        .foregroundStyle(disabled ? AppColors.textSecondary.opacity(0.35) : AppColors.textPrimary)
        .disabled(disabled)
    }
}

// MARK: - 底部浮层胶囊底

/// 页面底部浮层（展开的操作栏 / 收起态小胶囊）共用的胶囊底：白底 + 1pt 灰描边 + 轻阴影。
struct ChromeCapsule: View {
    /// `matchedGeometryEffect` 的身份键：底部浮层全局只此一块
    static let morphID = "browserBottomChrome"

    /// 父级命名空间；为 nil 时退化为普通胶囊底（不影响外观）
    var morphNamespace: Namespace.ID? = nil

    var body: some View {
        Group {
            if let morphNamespace {
                shape.matchedGeometryEffect(id: Self.morphID, in: morphNamespace)
            } else {
                shape
            }
        }
        // 先合成再投影：描边与填充作为整体投影，形变过程中阴影不会跳变
        .compositingGroup()
        .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
    }

    // 1pt 极浅描边：白底主界面下与内容分割（与全局悬浮页签栏 / mini 播放器统一为 cardBorder，/379）
    private var shape: some View {
        Capsule()
            .fill(AppColors.cardBackground)
            .overlay(Capsule().stroke(AppColors.cardBorder, lineWidth: 1))
    }
}

/// 浏览器底部工具栏按钮按压样式
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
