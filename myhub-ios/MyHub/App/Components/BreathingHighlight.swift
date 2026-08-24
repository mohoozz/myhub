import SwiftUI

/// 呼吸灯高亮（IOS-704）：「定位到原路径」等场景的临时强调——
/// 主色底/描边透明度循环呼吸，仅提示一段时间（由外部控制 active 开关，约 10s），不常亮。
struct BreathingHighlightModifier: ViewModifier {
    let active: Bool
    var cornerRadius: CGFloat = 12

    @State private var bright = false

    func body(content: Content) -> some View {
        content
            // 半透明 overlay：不被卡片不透明背景遮住
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(AppColors.primary.opacity(active ? (bright ? 0.18 : 0.05) : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppColors.primary.opacity(active ? (bright ? 0.75 : 0.25) : 0), lineWidth: 1.5)
            )
            .onAppear { update(active) }
            .onChange(of: active) { update($0) }
    }

    private func update(_ active: Bool) {
        if active {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                bright = true
            }
        } else {
            withAnimation(.appQuick) { bright = false }
        }
    }
}

extension View {
    /// 呼吸灯高亮（active 期间呼吸闪烁，关闭后淡出）
    func breathingHighlight(_ active: Bool, cornerRadius: CGFloat = 12) -> some View {
        modifier(BreathingHighlightModifier(active: active, cornerRadius: cornerRadius))
    }
}
