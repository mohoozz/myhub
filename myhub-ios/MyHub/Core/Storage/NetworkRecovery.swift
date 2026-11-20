import Foundation

/// 长时间后台（熄屏）后的网络自愈调度。
@MainActor
final class NetworkRecovery {
    static let shared = NetworkRecovery()

    /// 触发自愈的最短后台时长（秒）：低于该时长的前后台切换视为「短暂切换」，不做重新判定
    private let minimumBackgroundDuration: TimeInterval = 60

    /// 最近一次进入后台的时刻（nil = 当前不在后台或已消费）
    private var backgroundAt: Date?

    private init() {}

    /// App 进入后台（含熄屏）：记录时刻，供回前台判断后台时长
    func noteDidEnterBackground() {
        backgroundAt = Date()
        // 进入后台的快照由 App 级 lifecycle（scenePhase -> background）记录，此处不再重复
    }

    /// App 回到前台：本地代理探活每次必做，地址重判定按后台时长阈值执行
    func recoverAfterReturningToForeground() {
        guard let backgroundAt else {
            AppLogger.shared.log(
                "回到前台（无后台基准，跳过自愈）网络=\(NetworkPathMonitor.shared.snapshot())",
                level: .debug, module: "network-route"
            )
            return
        }
        let elapsed = Date().timeIntervalSince(backgroundAt)
        self.backgroundAt = nil

        // ③ 本地串流代理：与后台时长无关——挂起十几秒就足以让系统回收回环监听 socket
        LocalStreamProxy.shared.recoverIfNeeded()

        guard elapsed >= minimumBackgroundDuration else {
            // 短切换也留面包屑（debug）：确认「熄屏回来了、但时长未达地址重判定阈值」这类情况
            AppLogger.shared.log(
                "后台 \(Int(elapsed))s 后回到前台（未达 \(Int(minimumBackgroundDuration))s 地址重判定阈值，跳过；已做代理探活）代理=\(LocalStreamProxy.shared.healthSnapshot()) 网络=\(NetworkPathMonitor.shared.snapshot())",
                level: .debug, module: "network-route"
            )
            return
        }

        // 自愈前后快照合并为一条：后台时长 + 锁定/代理变化 + 当前网络
        let locksBefore = RoutedWebDAVAdapter.lockSnapshot()
        // ① 地址锁定失效：下次请求重新竞速判定（网络环境可能已变化，如 WiFi 重连换 IP）
        RoutedWebDAVAdapter.invalidateAllLocks(reason: "后台 \(Int(elapsed))s 回前台")
        AppLogger.shared.log(
            "后台 \(Int(elapsed))s 回前台：网络自愈 播放=\(PlayerCore.shared.state.logDescription) 锁定 \(locksBefore) → [\(RoutedWebDAVAdapter.lockSnapshot())] 代理=\(LocalStreamProxy.shared.healthSnapshot()) 网络=\(NetworkPathMonitor.shared.snapshot())",
            level: .info, module: "network-route"
        )
    }
}
