import Foundation
import Network

/// 网络路径监测（TODO 380）：记录熄屏/长时间后台期间的网络环境变化
/// （WiFi 断开/重连换 IP、切换蜂窝、整体断网、受限网络），
/// 为「熄屏一段时间回来后视频无法播放」提供环境侧证据——判断问题是否与网络变化有关。
/// 仅记录日志与提供只读快照，不改变任何请求行为（自愈仍由 NetworkRecovery 负责）。
final class NetworkPathMonitor {
    static let shared = NetworkPathMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "myhub.networkpath")
    private let lock = NSLock()
    private var started = false
    /// 最近一次路径描述（供播放请求 / 失败快照引用）
    private var latest = "未启动"

    private init() {}

    /// 启动监测（App 启动时调用一次；重复调用无副作用）
    func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()

        AppLogger.shared.log("网络路径监测启动 path=\(snapshot())", level: .debug, module: "network-route")
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let desc = Self.describe(path)
            self.lock.lock()
            let changed = self.latest != desc
            self.latest = desc
            self.lock.unlock()
            guard changed else { return }
            AppLogger.shared.log("网络路径变化 -> \(desc)", level: .info, module: "network-route")
        }
        monitor.start(queue: queue)
    }

    /// 当前网络路径快照（诊断日志用）
    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// 路径可读描述：状态 + 接口 + 是否昂贵（蜂窝）/受限
    private static func describe(_ path: NWPath) -> String {
        let status: String
        switch path.status {
        case .satisfied: status = "satisfied"
        case .unsatisfied: status = "unsatisfied"
        case .requiresConnection: status = "requiresConnection"
        @unknown default: status = "unknown"
        }
        var interfaces: [String] = []
        if path.usesInterfaceType(.wifi) { interfaces.append("wifi") }
        if path.usesInterfaceType(.cellular) { interfaces.append("cellular") }
        if path.usesInterfaceType(.wiredEthernet) { interfaces.append("wired") }
        if path.usesInterfaceType(.loopback) { interfaces.append("loopback") }
        if path.usesInterfaceType(.other) { interfaces.append("other") }
        var parts = [status, "if=\(interfaces.isEmpty ? "none" : interfaces.joined(separator: "+"))"]
        if path.isExpensive { parts.append("expensive") }
        if path.isConstrained { parts.append("constrained") }
        return parts.joined(separator: " ")
    }
}
