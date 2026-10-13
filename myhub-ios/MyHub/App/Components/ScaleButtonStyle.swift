import SwiftUI

/// 按压缩放反馈（0.97，《需求分析文档》§2.10），动画 ≤ 200ms。
///
/// 按压态经 `PressVisualGate` 过闸：按下瞬时点亮保证跟手，抬起补足最短可见时长再回弹，
/// 避免快速单点时「按下 + 抬起」被合并进同一次渲染导致一帧动画都看不到（TODO 402）。
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
