import AVFoundation
import AVKit
import MobileVLCKit
import SwiftUI

/// 画中画持有（硬解路径生效；AVPictureInPictureController 依赖 AVPlayerLayer）
@MainActor
final class PiPState: ObservableObject {
    @Published private(set) var isSupported = false
    private var controller: AVPictureInPictureController?

    func attach(layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        controller = AVPictureInPictureController(playerLayer: layer)
        isSupported = true
    }

    /// 运行期清理（硬解→软解引擎切换时调用）：视图仍存活，需同步更新 isSupported 通知 UI。
    func detach() {
        controller = nil
        isSupported = false
    }

    /// 视图拆除期清理（dismantleUIView）：视图正在被 SwiftUI 销毁。
    /// 绝不能在此同步修改 @Published（会触发 Combine send 与视图拆除事务并发，
    /// 导致 exclusivity violation → abort）。本对象随 PlayerView 一起释放，无需再通知 UI。
    func teardown() {
        controller = nil
    }

    func start() {
        controller?.startPictureInPicture()
    }
}

/// 视频渲染桥：硬解 → AVPlayerLayer（videoGravity .resizeAspect，不同分辨率/竖屏正确适配，不拉伸不裁切）；
/// 软解 → VLCMediaPlayer.drawable 指向宿主 UIView。引擎切换（硬解失败回退软解）时透明重挂。
struct VideoRenderView: UIViewRepresentable {
    /// PlayerCore.videoOutput（AVPlayer / VLCMediaPlayer）
    let output: Any?
    let pip: PiPState

    func makeCoordinator() -> Coordinator {
        Coordinator(pip: pip)
    }

    func makeUIView(context: Context) -> PlayerRenderUIView {
        let view = PlayerRenderUIView()
        context.coordinator.attach(output: output, to: view)
        return view
    }

    func updateUIView(_ uiView: PlayerRenderUIView, context: Context) {
        context.coordinator.attach(output: output, to: uiView)
    }

    static func dismantleUIView(_ uiView: PlayerRenderUIView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator {
        private let pip: PiPState
        private weak var attachedOutput: AnyObject?
        private var playerLayer: AVPlayerLayer?

        init(pip: PiPState) {
            self.pip = pip
        }

        func attach(output: Any?, to view: PlayerRenderUIView) {
            let object = output as AnyObject?
            if let object, object === attachedOutput { return }
            detach()

            if let player = object as? AVPlayer {
                let layer = AVPlayerLayer(player: player)
                layer.videoGravity = .resizeAspect
                layer.backgroundColor = UIColor.black.cgColor
                layer.frame = view.bounds
                view.layer.addSublayer(layer)
                playerLayer = layer
                attachedOutput = player
                pip.attach(layer: layer)
            } else if let mediaPlayer = object as? VLCMediaPlayer {
                mediaPlayer.drawable = view
                attachedOutput = mediaPlayer
            }
        }

        func detach() {
            cleanup()
            pip.detach()
        }

        func teardown() {
            cleanup()
            pip.teardown()
        }

        private func cleanup() {
            if let mediaPlayer = attachedOutput as? VLCMediaPlayer,
               mediaPlayer.drawable as? PlayerRenderUIView != nil {
                mediaPlayer.drawable = nil
            }
            playerLayer?.removeFromSuperlayer()
            playerLayer = nil
            attachedOutput = nil
        }
    }
}

/// 宿主视图：随布局同步 AVPlayerLayer 尺寸
final class PlayerRenderUIView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.sublayers?.forEach { $0.frame = bounds }
    }
}
