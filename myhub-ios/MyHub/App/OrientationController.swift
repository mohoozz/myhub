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
/// * 进入播放页可切横屏，退出/进 mini 时恢复竖屏；
/// * 方向偏好**不持久化**——每次进播放页默认竖屏（与 Flutter 端会话级切换一致）。
@MainActor
final class OrientationController: ObservableObject {
    static let shared = OrientationController()

    /// 当前允许的方向掩码（供 AppDelegate 回调返回；默认竖屏）。
    private(set) var mask: UIInterfaceOrientationMask = .portrait

    /// 播放器当前是否处于横屏（驱动控制栏按钮图标）。
    @Published private(set) var isLandscape = false

    private init() {}

    /// 切换横竖屏：竖 → 横、横 → 竖。
    func toggle() {
        isLandscape ? lockPortrait() : lockLandscape()
    }

    /// 锁定横屏并请求旋转到横屏。
    func lockLandscape() {
        mask = .landscape
        isLandscape = true
        apply(.landscapeRight)
    }

    /// 锁定竖屏并请求旋转回竖屏（退出播放页调用）。
    func lockPortrait() {
        mask = .portrait
        isLandscape = false
        apply(.portrait)
    }

    /// 下发方向掩码更新，并请求几何旋转到目标方向。
    private func apply(_ orientation: UIInterfaceOrientation) {
        guard let scene = activeWindowScene else { return }
        // 通知系统重新询问 supportedInterfaceOrientations（返回最新 mask）
        if #available(iOS 16.0, *) {
            let prefs = UIWindowSceneGeometryPreferencesIOS(
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
