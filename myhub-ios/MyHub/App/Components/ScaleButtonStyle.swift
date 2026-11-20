import SwiftUI

/// 按压缩放反馈（0.97），动画 ≤ 200ms。
struct ScaleButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        PressVisualGate(isPressed: configuration.isPressed) { pressed in
            configuration.label
                .scaleEffect(pressed ? scale : 1)
        }
        // 位于滚动容器内时关掉 ~150ms 触摸延迟；不在滚动容器内则为空操作
        .instantPressInScrollView()
    }
}

extension ButtonStyle where Self == ScaleButtonStyle {
    /// 按压缩放 0.97
    static var pressScale: ScaleButtonStyle { ScaleButtonStyle() }
}
