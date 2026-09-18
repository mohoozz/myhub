import Foundation

/// 长时间后台（熄屏）后的网络自愈调度（TODO 366）。
///
/// 熄屏长时间会让两类进程级状态失效，此前只有「重启 App」才能恢复：
/// ① 内外网地址锁定（`RoutedWebDAVAdapter` 进程级共享）停留在熄屏前的网络环境——
///    WiFi 重连换 IP / 出门或回家等网络变化后该地址不可达，音视频分片读取全部失败，
///    且锁定不再重新判定，重试永远走同一个不可达地址；
/// ② 本地串流代理（`LocalStreamProxy` 的 127.0.0.1 监听）在 App 被系统挂起期间会被
///    iOS 回收回环监听 socket，端口不再可用，解码器连接回环地址被拒 → 所有音视频无法加载。
///    注意：此场景 `NWListener` 不会回调 waiting/failed/cancelled，被动健康标记仍为 ready，
///    必须靠真实回环探活才能发现（详见 `LocalStreamProxy.probe`）。
///
/// 回到前台时：本地代理监听做一次探活（成本约 1ms，故每次前台都做）；
/// 后台时长超过阈值时再清除地址锁定（下次请求自动重新竞速判定可达地址）。
/// 阈值用于避免频繁切换 App 时反复做竞速判定。
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
        AppLogger.shared.log(
            "进入后台（记录网络自愈基准）播放=\(PlayerCore.shared.state.logDescription) item=\(PlayerCore.shared.currentItem?.title ?? "nil") 锁定=[\(RoutedWebDAVAdapter.lockSnapshot())] 代理=\(LocalStreamProxy.shared.healthSnapshot()) 网络=\(NetworkPathMonitor.shared.snapshot())",
            level: .info, module: "network-route"
        )
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

        // ③ 本地串流代理：与后台时长无关——挂起十几秒就足以让系统回收回环监听 socket，
        //    且被动标记不会翻转，故每次回前台都做一次真实探活（成本约 1ms），
        //    不健康即重建；健康的监听不动，避免打断后台音频仍在进行的分片连接（TODO 366）
        LocalStreamProxy.shared.recoverIfNeeded()

        guard elapsed >= minimumBackgroundDuration else {
            // 短切换也留面包屑（debug）：确认「熄屏回来了、但时长未达地址重判定阈值」这类情况
            AppLogger.shared.log(
                "后台 \(Int(elapsed))s 后回到前台（未达 \(Int(minimumBackgroundDuration))s 地址重判定阈值，跳过；已做代理探活）代理=\(LocalStreamProxy.shared.healthSnapshot()) 网络=\(NetworkPathMonitor.shared.snapshot())",
                level: .debug, module: "network-route"
            )
            return
        }

        // 自愈前快照（TODO 380）：网络路径是否在熄屏期间变化、锁定与代理是否健康
        AppLogger.shared.log(
            "后台 \(Int(elapsed))s 后回到前台：执行网络自愈 播放=\(PlayerCore.shared.state.logDescription) 锁定=[\(RoutedWebDAVAdapter.lockSnapshot())] 代理=\(LocalStreamProxy.shared.healthSnapshot()) 网络=\(NetworkPathMonitor.shared.snapshot())",
            level: .info, module: "network-route"
        )
        // ① 地址锁定失效：下次请求重新竞速判定（网络环境可能已变化，如 WiFi 重连换 IP）
        RoutedWebDAVAdapter.invalidateAllLocks(reason: "后台 \(Int(elapsed))s 回前台")
        AppLogger.shared.log(
            "网络自愈执行完毕 锁定=[\(RoutedWebDAVAdapter.lockSnapshot())] 代理=\(LocalStreamProxy.shared.healthSnapshot())",
            level: .info, module: "network-route"
        )
    }
}
