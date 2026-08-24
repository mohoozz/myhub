import SwiftUI

/// 按压缩放反馈（0.97，《需求分析文档》§2.10），动画 ≤ 200ms。
struct ScaleButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.appFast, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == ScaleButtonStyle {
    /// 按压缩放 0.97
    static var pressScale: ScaleButtonStyle { ScaleButtonStyle() }
}
