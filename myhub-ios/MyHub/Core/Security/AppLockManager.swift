import Foundation
import LocalAuthentication

/// 应用锁（TODO §10 / IOS-501 安全设置）：
/// 开启后应用进入后台再上滑返回时要求 Face ID / Touch ID（无生物识别回退设备密码）验证。
/// 开关本身需先通过身份验证，防止他人直接关闭。
final class AppLockManager: ObservableObject {
    static let shared = AppLockManager()

    @Published private(set) var isLocked = false

    private init() {}

    var isEnabled: Bool { AppSettings.Security.appLockEnabled }

    /// 生物识别名称（Face ID / Touch ID / 设备密码）
    var biometryName: String {
        switch biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "设备密码"
        }
    }

    var biometrySymbol: String {
        switch biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        default: return "lock.fill"
        }
    }

    private var biometryType: LABiometryType {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }
        return context.biometryType
    }

    /// 进入后台时上锁（开启应用锁时）
    func lockForBackground() {
        guard isEnabled else { return }
        isLocked = true
    }

    /// 验证并解锁
    func unlock() async {
        let ok = await Self.authenticate(reason: "解锁 MyHub")
        if ok {
            await MainActor.run { isLocked = false }
            AppLogger.shared.log("应用锁解锁成功")
        }
    }

    /// 开启/关闭应用锁，需先验证身份；返回是否生效
    @discardableResult
    func setEnabled(_ enabled: Bool) async -> Bool {
        let ok = await Self.authenticate(reason: enabled ? "开启应用锁" : "关闭应用锁")
        if ok {
            AppSettings.Security.appLockEnabled = enabled
            AppLogger.shared.log(enabled ? "已开启应用锁" : "已关闭应用锁")
        }
        return ok
    }

    /// 生物识别优先，不可用时回退设备密码
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        let policy: LAPolicy = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication
        guard context.canEvaluatePolicy(policy, error: &error) else { return false }
        return (try? await context.evaluatePolicy(policy, localizedReason: reason)) ?? false
    }
}
