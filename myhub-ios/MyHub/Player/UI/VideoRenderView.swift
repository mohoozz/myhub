import AVFoundation
import AVKit
import MobileVLCKit
import SwiftUI

/// 画中画持有（硬解路径生效；AVPictureInPictureController 依赖 AVPlayerLayer）
@MainActor
final class PiPState: NSObject, ObservableObject {
    @Published private(set) var isSupported = false
    /// 画中画是否处于激活状态（由 delegate 回调同步，UI 据此切换按钮图标）
    @Published private(set) var isActive = false
    /// 启动失败原因（PlayerView 据此弹出提示，避免点击无反馈）
    @Published var lastError: String?
    private var controller: AVPictureInPictureController?

    func attach(layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let controller = AVPictureInPictureController(playerLayer: layer) else { return }
        controller.delegate = self
        // App 退后台时自动进入画中画（需 Info.plist 声明 UIBackgroundModes = audio）
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        self.controller = controller
        isSupported = true
    }

    /// 运行期清理（硬解→软解引擎切换时调用）：视图仍存活，需同步更新 isSupported 通知 UI。
    func detach() {
        controller?.stopPictureInPicture()
        controller?.delegate = nil
        controller = nil
        isSupported = false
        isActive = false
    }

    /// 视图拆除期清理（dismantleUIView）：视图正在被 SwiftUI 销毁。
    /// 绝不能在此同步修改 @Published（会触发 Combine send 与视图拆除事务并发，
    /// 导致 exclusivity violation → abort）。本对象随 PlayerView 一起释放，无需再通知 UI。
    func teardown() {
        // 先断开 delegate 再 stop：防止 stopPictureInPicture 触发
        // pictureInPictureControllerDidStopPictureInPicture → isActive = false（改 @Published）
        // 与 dismantleUIView 拆除事务并发 → exclusivity violation → abort。
        controller?.delegate = nil
        controller?.stopPictureInPicture()
        controller = nil
    }

    /// 切换画中画：激活中点击则退出，未激活则启动
    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            lastError = nil
            controller.startPictureInPicture()
        }
    }
}

extension PiPState: AVPictureInPictureControllerDelegate {
    // AVPictureInPictureControllerDelegate 为 nonisolated 协议，而 PiPState 是 @MainActor 类；
    // 直接实现会触发「main actor-isolated instance method cannot satisfy nonisolated requirement」。
    // 故方法标 nonisolated，回调线程通过 Task 派发到主线程再改 @Published（与 VLCEngine delegate 同款）。
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = false }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            self.isActive = false
            self.lastError = "画中画启动失败：\(error.localizedDescription)"
        }
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
        /// 自己挂载的宿主（VLC 软解路径：全屏收起瞬间 mini 可能已接管 drawable，
        /// 清理时必须只断自己，避免误清 mini 封面画面）
        private weak var hostView: PlayerRenderUIView?
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
                hostView = view
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
