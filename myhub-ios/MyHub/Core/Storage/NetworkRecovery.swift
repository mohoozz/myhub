import Foundation

/// 长时间后台（熄屏）后的网络自愈调度（TODO 366）。
///
/// 熄屏长时间会让两类进程级状态失效，此前只有「重启 App」才能恢复：
/// ① 内外网地址锁定（`RoutedWebDAVAdapter` 进程级共享）停留在熄屏前的网络环境——
///    WiFi 重连换 IP / 出门或回家等网络变化后该地址不可达，音视频分片读取全部失败，
///    且锁定不再重新判定，重试永远走同一个不可达地址；
/// ② 本地串流代理（`LocalStreamProxy` 的 127.0.0.1 监听）长期挂起后可能进入
///    waiting/failed，端口不再可用，解码器连接回环地址被拒 → 所有音视频无法加载。
///
/// 回到前台且后台时长超过阈值时：清除地址锁定（下次请求自动重新竞速判定可达地址）
/// 并检查本地代理监听健康（异常则重建）。阈值用于避免频繁切换 App 时反复判定。
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
        AppLogger.shared.log("进入后台，记录网络自愈基准", level: .debug, module: "network-route")
    }

    /// App 回到前台：后台时长超过阈值时执行网络自愈
    func recoverAfterReturningToForeground() {
        guard let backgroundAt else { return }
        let elapsed = Date().timeIntervalSince(backgroundAt)
        self.backgroundAt = nil
        guard elapsed >= minimumBackgroundDuration else { return }

        AppLogger.shared.log(
            "后台 \(Int(elapsed))s 后回到前台：执行网络自愈（清地址锁定 + 检查串流代理）",
            level: .info, module: "network-route"
        )
        // ① 地址锁定失效：下次请求重新竞速判定（网络环境可能已变化，如 WiFi 重连换 IP）
        RoutedWebDAVAdapter.invalidateAllLocks(reason: "后台 \(Int(elapsed))s 回前台")
        // ② 本地串流代理：监听不健康（waiting/failed）时异步重建；
        //    健康的监听不动，避免打断后台音频仍在进行的分片连接
        LocalStreamProxy.shared.recoverIfNeeded()
    }
}
