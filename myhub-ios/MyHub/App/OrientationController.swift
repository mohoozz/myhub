import SwiftUI
import UIKit

/// 全屏播放器横竖屏切换（对齐 Flutter 端播放页方向控制）。
///
/// iOS 的界面方向由 App 的 `supportedInterfaceOrientations` 收口：SwiftUI 无直接 API，
/// 需经 `AppDelegate.application(_:supportedInterfaceOrientationsFor:)` 返回动态方向掩码，
/// 再用 iOS 16 的 `UIWindowScene.requestGeometryUpdate(_:)` 触发编程旋转。
///
/// 设计：
/// * 平时（非播放）锁竖屏，App 行为与旋转前一致；
/// * 进入播放页按「设置 → 播放器偏好 → 横竖屏切换」初始化方向：
///   - 手动：沿用上次缓存的方向（`player.landscapePreferred`），点播放页按钮切换并更新缓存；
///   - 自动：跟随设备横放/竖放（mask 放开全方向，系统自动旋转 + 通知纠偏）；
/// * 退出 / 进 mini 时恢复竖屏，但方向偏好保留，下次播放沿用。
@MainActor
final class OrientationController: ObservableObject {
    static let shared = OrientationController()

    /// 当前允许的方向掩码（供 AppDelegate 回调返回；默认竖屏）。
    private(set) var mask: UIInterfaceOrientationMask = .portrait

    /// 播放器当前是否处于横屏（驱动控制栏按钮图标）。
    @Published private(set) var isLandscape = false

    /// 当前是否为手动切换模式（自动模式隐藏播放页旋转按钮）。
    @Published private(set) var isManualMode = true

    /// 播放页是否活跃（auto 模式只在播放页内跟随设备方向）。
    private var isPlayerActive = false
    /// 进入播放页的方向初始化任务（延迟到呈现转场结束后执行）。
    private var enterTask: Task<Void, Never>?
    /// 设备物理方向监听（auto 模式）。
    private var deviceObserver: NSObjectProtocol?

    private init() {}

    // MARK: - 播放页生命周期

    /// 进入播放页：按偏好初始化方向。
    ///
    /// 延迟到全屏封面呈现转场结束再旋转：转场进行中调用 `requestGeometryUpdate`
    /// 会与转场并发，导致 iOS 16 崩溃（与 dismiss 侧同一已知问题）。
    func enterPlayer() {
        isPlayerActive = true
        let mode = AppSettings.Player.orientationMode
        isManualMode = mode == .manual
        enterTask?.cancel()
        enterTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, self.isPlayerActive else { return }
            switch mode {
            case .manual:
                // 手动模式：沿用上次缓存的方向偏好
                if AppSettings.Player.landscapePreferred {
                    self.lockLandscape()
                } else if self.isLandscape {
                    self.lockPortrait()
                }
            case .auto:
                self.startAutoFollow()
            }
        }
    }

    /// 退出播放页：停止自动跟随并恢复竖屏（由 `fullScreenCover(onDismiss:)` 调用，此时转场已结束）。
    func exitPlayer() {
        isPlayerActive = false
        enterTask?.cancel()
        stopAutoFollow()
        // auto 模式下 mask 可能已放开全方向，退出必须归位竖屏，保证非播放页锁竖屏
        if isLandscape || mask != .portrait {
            lockPortrait()
        }
    }

    // MARK: - 手动切换

    /// 切换横竖屏：竖 → 横、横 → 竖；并缓存方向偏好供下次播放沿用。
    func toggle() {
        guard AppSettings.Player.orientationMode == .manual else { return }
        if isLandscape {
            lockPortrait()
        } else {
            lockLandscape()
        }
        AppSettings.Player.landscapePreferred = isLandscape
        AppLogger.shared.log("toggle -> isLandscape=\(isLandscape)（已缓存方向偏好）", module: "orientation")
    }

    /// 锁定横屏并请求旋转到横屏。
    func lockLandscape() {
        // 自动模式放开全方向，系统才能随设备自由旋转
        mask = AppSettings.Player.orientationMode == .auto ? .allButUpsideDown : .landscape
        isLandscape = true
        apply(.landscapeRight)
        AppLogger.shared.log("lockLandscape -> requestGeometryUpdate(.landscapeRight)", module: "orientation")
    }

    /// 锁定竖屏并请求旋转回竖屏（退出播放页 / 切纯音频调用）。
    func lockPortrait() {
        mask = .portrait
        isLandscape = false
        apply(.portrait)
        AppLogger.shared.log("lockPortrait -> requestGeometryUpdate(.portrait)", module: "orientation")
    }

    // MARK: - 自动跟随设备方向（auto 模式）

    /// 开始监听设备物理方向，并立即同步一次当前方向。
    private func startAutoFollow() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        if deviceObserver == nil {
            deviceObserver = NotificationCenter.default.addObserver(
                forName: UIDevice.orientationDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.syncWithDeviceOrientation() }
            }
        }
        syncWithDeviceOrientation()
        AppLogger.shared.log("startAutoFollow 设备方向=\(UIDevice.current.orientation.rawValue)", module: "orientation")
    }

    /// 停止监听设备方向（退出播放页调用）。
    private func stopAutoFollow() {
        if let deviceObserver {
            NotificationCenter.default.removeObserver(deviceObserver)
            self.deviceObserver = nil
        }
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    /// 重新同步设备方向（auto 模式切回视频时调用，例如纯音频强制竖屏后恢复跟随）。
    func resyncWithDevice() {
        syncWithDeviceOrientation()
    }

    /// 把界面方向同步到设备物理方向（mask 放开全方向由系统自动跟随，通知纠偏兜底）。
    private func syncWithDeviceOrientation() {
        guard isPlayerActive, AppSettings.Player.orientationMode == .auto else { return }
        let target: UIInterfaceOrientation
        switch UIDevice.current.orientation {
        case .portrait: target = .portrait
        case .landscapeLeft: target = .landscapeRight   // 设备方向与界面方向定义相反
        case .landscapeRight: target = .landscapeLeft
        default: return   // faceUp / faceDown / unknown：保持当前方向
        }
        mask = .allButUpsideDown
        if activeWindowScene?.interfaceOrientation != target {
            apply(target)
        }
        if isLandscape != target.isLandscape {
            isLandscape = target.isLandscape
        }
    }

    /// 下发方向掩码更新，并请求几何旋转到目标方向。
    private func apply(_ orientation: UIInterfaceOrientation) {
        guard let scene = activeWindowScene else { return }
        // 通知系统重新询问 supportedInterfaceOrientations（返回最新 mask）
        if #available(iOS 16.0, *) {
            let prefs = UIWindowScene.GeometryPreferences.iOS(
                interfaceOrientations: mask
            )
            scene.requestGeometryUpdate(prefs) { _ in }
            rootController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }

    private var activeWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
    }

    private var rootController: UIViewController? {
        activeWindowScene?.keyWindow?.rootViewController
    }
}

/// App 方向回调宿主：把动态方向掩码交给系统。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationController.shared.mask
    }
}
