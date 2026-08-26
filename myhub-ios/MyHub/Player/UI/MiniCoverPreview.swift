import AVFoundation
import MobileVLCKit
import SwiftUI

/// mini 播放器封面实时视频预览（与 Flutter 端 `_MusicCoverArt` 对应）。
///
/// 复用 `PlayerCore.videoOutput`（AVPlayer / VLCMediaPlayer）把小画面渲染到封面
/// 宿主视图上，实现「封面实时画面」。全屏播放器收起后其 `VideoRenderView` 已
/// dismantle（AVPlayerLayer 移除 / VLC drawable 释放），因此 mini 出现后可安全
/// 重新挂载。
///
/// 与全屏 `VideoRenderView` 的差异：
/// - 不绑定画中画（mini 无 PiP 入口）；
/// - VLC 软解路径仅清除**自己挂载**的宿主（全屏收起瞬间 mini 可能已接管
///   `drawable`，互不干扰，避免 mini 画面被全屏清理误清）。
struct MiniCoverPreview: UIViewRepresentable {
    /// PlayerCore.videoOutput（AVPlayer / VLCMediaPlayer）
    let output: Any?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerRenderUIView {
        let view = PlayerRenderUIView()
        context.coordinator.attach(output: output, to: view)
        return view
    }

    func updateUIView(_ uiView: PlayerRenderUIView, context: Context) {
        context.coordinator.attach(output: output, to: uiView)
    }

    static func dismantleUIView(_ uiView: PlayerRenderUIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        private weak var attachedOutput: AnyObject?
        private weak var hostView: PlayerRenderUIView?
        private var playerLayer: AVPlayerLayer?

        func attach(output: Any?, to view: PlayerRenderUIView) {
            let object = output as AnyObject?
            if let object, object === attachedOutput { return }
            detach()

            if let player = object as? AVPlayer {
                let layer = AVPlayerLayer(player: player)
                // 封面填满（对齐 Flutter `BoxFit.cover`）
                layer.videoGravity = .resizeAspectFill
                layer.backgroundColor = UIColor.black.cgColor
                layer.frame = view.bounds
                view.layer.addSublayer(layer)
                playerLayer = layer
                attachedOutput = player
            } else if let mediaPlayer = object as? VLCMediaPlayer {
                mediaPlayer.drawable = view
                attachedOutput = mediaPlayer
                hostView = view
            }
        }

        func detach() {
            if let mediaPlayer = attachedOutput as? VLCMediaPlayer,
               let host = hostView,
               mediaPlayer.drawable as? PlayerRenderUIView === host {
                mediaPlayer.drawable = nil
            }
            playerLayer?.removeFromSuperlayer()
            playerLayer = nil
            attachedOutput = nil
            hostView = nil
        }
    }
}
