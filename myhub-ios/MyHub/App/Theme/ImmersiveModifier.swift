import SwiftUI

private struct ImmersiveModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.black.ignoresSafeArea())
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    /// 沉浸场景（播放器 / 阅读器）强制纯黑背景 + 暗色方案
    func immersive() -> some View {
        modifier(ImmersiveModifier())
    }
}
