import AVFoundation
import AVKit
import MobileVLCKit
import SwiftUI
import UIKit

/// 画中画持有（硬解路径生效；AVPictureInPictureController 依赖 AVPlayerLayer）
@MainActor
final class PiPState: NSObject, ObservableObject {
    @Published private(set) var isSupported = false
    /// 画中画是否处于激活状态（由 delegate 回调同步，UI 据此切换按钮图标）
    @Published private(set) var isActive = false
    /// 启动失败原因（PlayerView 据此弹出提示，避免点击无反馈）
    @Published var lastError: String?
    private var controller: AVPictureInPictureController?
    /// 当前渲染层（引擎切换时透明替换）。开关关闭时不建立 controller，需要时据此按需创建
    private weak var playerLayer: AVPlayerLayer?
    /// 本次画中画启动是否由播放页按钮手动触发（用于区分系统「退后台自动画中画」）
    private var manualRequest = false
    /// App 退后台前同步「自动画中画」开关的观察者
    private var backgroundObserver: NSObjectProtocol?

    func attach(layer: AVPlayerLayer) {
        playerLayer = layer
        isSupported = AVPictureInPictureController.isPictureInPictureSupported()
        // 「退后台自动画中画」默认关闭。系统只有在 App 持有 AVPictureInPictureController
        syncAutoPreference()
        // AVPlayerLayer/Controller 只在开播/引擎切换时重建，开关却可能在播放过程中被改动
        startObservingBackground()
    }

    /// 依据「退后台自动画中画」开关决定是否持有 AVPictureInPictureController
    private func syncAutoPreference() {
        if AppSettings.Player.autoPiPOnBackground {
            ensureController()?.canStartPictureInPictureAutomaticallyFromInline = true
        } else {
            releaseController()
        }
    }

    /// 按需创建 controller（手动画中画按钮 / 开关开启时）
    @discardableResult
    private func ensureController() -> AVPictureInPictureController? {
        if let controller { return controller }
        guard let playerLayer,
              AVPictureInPictureController.isPictureInPictureSupported(),
              let controller = AVPictureInPictureController(playerLayer: playerLayer) else { return nil }
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = AppSettings.Player.autoPiPOnBackground
        self.controller = controller
        return controller
    }

    /// 释放 controller：画中画正在显示时不释放（否则会强制退出用户已开启的画中画）
    private func releaseController() {
        guard !(controller?.isPictureInPictureActive ?? false) else { return }
        controller?.delegate = nil
        controller?.stopPictureInPicture()
        controller = nil
    }

    /// 注册「即将退后台（失活）」观察者，在系统决定是否自动进入画中画前刷新开关
    private func startObservingBackground() {
        stopObservingBackground()
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncAutoPreference() }
        }
    }

    private func stopObservingBackground() {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        backgroundObserver = nil
    }

    /// 运行期清理（硬解→软解引擎切换时调用）：视图仍存活，需同步更新 isSupported 通知 UI。
    func detach() {
        controller?.stopPictureInPicture()
        controller?.delegate = nil
        controller = nil
        playerLayer = nil
        stopObservingBackground()
        isSupported = false
        isActive = false
    }

    /// 视图拆除期清理（dismantleUIView）：视图正在被 SwiftUI 销毁。
    func teardown() {
        // 先断开 delegate 再 stop：防止 stopPictureInPicture 触发
        controller?.delegate = nil
        controller?.stopPictureInPicture()
        controller = nil
        playerLayer = nil
        stopObservingBackground()
    }

    /// 切换画中画：激活中点击则退出，未激活则启动
    func toggle() {
        guard let controller = ensureController() else {
            lastError = "当前设备不支持画中画"
            return
        }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            lastError = nil
            manualRequest = true
            startWhenPossible(controller)
        }
    }

    /// 刚创建的 controller 可能尚未进入「可画中画」状态（按需创建的场景）
    private func startWhenPossible(_ controller: AVPictureInPictureController, attempt: Int = 0) {
        guard self.controller === controller else { return }
        if controller.isPictureInPicturePossible || attempt >= 2 {
            controller.startPictureInPicture()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.manualRequest else { return }
                self.startWhenPossible(controller, attempt: attempt + 1)
            }
        }
    }
}

extension PiPState: AVPictureInPictureControllerDelegate {
    // AVPictureInPictureControllerDelegate 为 nonisolated 协议，而 PiPState 是 @MainActor 类
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            // 兜底：非手动触发（即系统「退后台自动画中画」）且开关为关闭时，取消本次启动
            if !self.manualRequest, !AppSettings.Player.autoPiPOnBackground {
                controller.stopPictureInPicture()
            }
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            self.manualRequest = false
            self.isActive = true
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            self.manualRequest = false
            self.isActive = false
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            self.manualRequest = false
            self.isActive = false
            self.lastError = "画中画启动失败：\(error.localizedDescription)"
        }
    }
}

/// 视频渲染桥：硬解 → AVPlayerLayer（videoGravity .resizeAspect，不同分辨率/竖屏正确适配，不拉伸不裁切）
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
        /// 自己挂载的宿主
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
                // 渲染桥面包屑：确认熄屏回前台/引擎切换后画面输出层是否重新挂载
                AppLogger.shared.log("渲染桥挂载 硬解 AVPlayerLayer", level: .debug, module: "player")
            } else if let mediaPlayer = object as? VLCMediaPlayer {
                mediaPlayer.drawable = view
                attachedOutput = mediaPlayer
                hostView = view
                AppLogger.shared.log("渲染桥挂载 软解 VLC drawable", level: .debug, module: "player")
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
