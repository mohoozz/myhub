import SwiftUI

/// mini 播放器封面实时视频预览（与 Flutter 端 `_MusicCoverArt` 对应）。
///
/// 画面本体来自 `VideoSurface`（与全屏共用同一个 UIView）：
/// 软解（VLC）的 drawable 在播放中无法迁移，只有「搬父视图」才能让 mini 拿到实时画面。
struct MiniCoverPreview: UIViewRepresentable {
    /// PlayerCore.videoOutput（AVPlayer / VLCMediaPlayer）
    let output: Any?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SurfaceHostView {
        let view = SurfaceHostView()
        view.style = .cover
        context.coordinator.attach(output: output, to: view)
        return view
    }

    func updateUIView(_ uiView: SurfaceHostView, context: Context) {
        context.coordinator.attach(output: output, to: uiView)
    }

    static func dismantleUIView(_ uiView: SurfaceHostView, coordinator: Coordinator) {
        coordinator.detach(host: uiView)
    }

    @MainActor
    final class Coordinator {
        func attach(output: Any?, to host: SurfaceHostView) {
            VideoSurface.shared.bind(output)
            VideoSurface.shared.claim(host)
        }

        func detach(host: SurfaceHostView) {
            // 画面本体不解绑：全屏宿主会接着承载同一个视图
            VideoSurface.shared.release(host)
        }
    }
}
