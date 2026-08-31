import Foundation

/// 连接路由：实际生效的是内网还是外网地址
enum ConnectionRoute: Equatable {
    case internalNetwork
    case externalNetwork
}

/// WebDAV 内外网双地址适配器（路径源优化，IOS-101 / TODO 324、351、352）：
/// - 路由判定采用「内外网竞速」（Happy Eyeballs）：内网优先探测，外网延迟 ~700ms 兜底并发，
///   谁先成功用谁并锁定。内网环境下内网 RTT 极低会在外网启动前完成、锁内网；
///   外网环境下内网不可达（超时/拒绝），外网在 ~700ms 后成功即锁外网——
///   不再像旧逻辑那样死等内网 5s 超时才回退，App 启动后内外网判定显著加快（TODO 352）。
/// - 锁定结果按「内网根 URL」进程级共享：目录浏览每进入一级目录都会新建适配器实例，
///   共享后各实例复用同一份判定结论；
/// - 关键修复（TODO 351）：`readStream`/`writeStream` 在未锁定时先执行竞速判定再选址，
///   不再盲目走内网。此前启动探测尚未完成时点击播放会直连内网、外网环境下必然失败且不回退，
///   导致「刚打开 App 点视频有时无法播放」；
/// - 重新判定时机只有两个：用户手动「测试连接」、重启 App。
final class RoutedWebDAVAdapter: StorageAdapter {
    /// 进程级路由锁定表：key = 内网根 URL，缺省 = 尚未判定
    private static let sharedLock = NSLock()
    private static var lockedRouteByURL: [String: ConnectionRoute] = [:]

    /// 外网探测延迟（内网优先窗口）：内网 RTT 通常 < 100ms，此窗口内足以完成内网判定，
    /// 给内网优先机会避免内网环境误走公网外网地址；窗口后仍未判定则并发外网加速回退。
    private static let externalProbeDelayNanos: UInt64 = 700_000_000

    private let internalAdapter: WebDAVAdapter
    private let externalAdapter: WebDAVAdapter

    /// 内网根 URL：作为共享锁定的 key（不同连接源的内网地址互不干扰）
    private let routeKey: String

    /// 最近一次 testConnection 生效的路径（nil = 尚未测试）
    private(set) var activeRoute: ConnectionRoute?

    init(internalAdapter: WebDAVAdapter, externalAdapter: WebDAVAdapter) {
        self.internalAdapter = internalAdapter
        self.externalAdapter = externalAdapter
        self.routeKey = internalAdapter.rootURLString
    }

    // MARK: - 路由锁定

    private var lockedRoute: ConnectionRoute? {
        Self.sharedLock.lock(); defer { Self.sharedLock.unlock() }
        return Self.lockedRouteByURL[routeKey]
    }

    private func lockRoute(_ route: ConnectionRoute) {
        Self.sharedLock.lock(); defer { Self.sharedLock.unlock() }
        Self.lockedRouteByURL[routeKey] = route
    }

    private func clearLock() {
        Self.sharedLock.lock(); defer { Self.sharedLock.unlock() }
        Self.lockedRouteByURL[routeKey] = nil
    }

    // MARK: - 路由判定（竞速）

    /// 内外网竞速判定（Happy Eyeballs）：内网优先启动，外网延迟兜底并发，谁先成功返回谁。
    /// 内外网均不可达返回 nil。探测轻量（PROPFIND Depth:0），失败快速返回。
    private func raceRoute() async -> ConnectionRoute? {
        let internalAdapter = self.internalAdapter
        let externalAdapter = self.externalAdapter
        let externalDelay = Self.externalProbeDelayNanos
        return await withTaskGroup(of: ConnectionRoute?.self) { group in
            // 内网：立即探测（优先）
            group.addTask {
                do { try await internalAdapter.testConnection(); return .internalNetwork }
                catch { return nil }
            }
            // 外网：延迟启动兜底，给内网优先窗口；被取消（内网已成功）则不发起
            group.addTask {
                try? await Task.sleep(nanoseconds: externalDelay)
                if Task.isCancelled { return nil }
                do { try await externalAdapter.testConnection(); return .externalNetwork }
                catch { return nil }
            }
            for await result in group {
                if let route = result {
                    group.cancelAll()   // 先成功者胜出，取消另一方，尽快返回
                    return route
                }
            }
            return nil
        }
    }

    /// 确保已判定生效路由：已锁定直接返回；未锁定则竞速判定并锁定。
    /// 竞速都失败（内外网均不可达）时不锁定，返回内网兜底——交由真实请求报错触发上层重试，
    /// 下次（测试连接 / 重启 / 再次读取）重新判定。
    private func resolveRoute() async -> ConnectionRoute {
        if let lockedRoute { return lockedRoute }
        if let route = await raceRoute() {
            lockRoute(route)
            return route
        }
        return .internalNetwork
    }

    // MARK: - 通用请求路由

    /// 未锁定时先竞速判定生效路由，再执行对应地址的操作；
    /// 内网锁定后操作失败（内网可能刚断）回退外网并重新锁定，保证可用性。
    private func route<T>(
        _ internalOp: () async throws -> T,
        externalOp: () async throws -> T
    ) async throws -> T {
        let route = await resolveRoute()
        if route == .internalNetwork {
            do {
                return try await internalOp()
            } catch {
                // 内网锁定后临时不可达：回退外网并改锁外网
                let value = try await externalOp()
                lockRoute(.externalNetwork)
                return value
            }
        }
        return try await externalOp()
    }

    // MARK: - StorageAdapter

    func list(_ dir: String) async throws -> [FileEntry] {
        try await route({ try await internalAdapter.list(dir) },
                        externalOp: { try await externalAdapter.list(dir) })
    }

    func stat(_ path: String) async throws -> FileEntry {
        try await route({ try await internalAdapter.stat(path) },
                        externalOp: { try await externalAdapter.stat(path) })
    }

    func readStream(_ path: String, range: Range<Int64>?) async throws -> AsyncThrowingStream<Data, Error> {
        // 流式传输无法在流内切换地址：先竞速判定生效路由再选址，避免未锁定时盲目走内网
        // （外网环境下内网不可达会导致播放失败且不回退，TODO 351）。
        let route = await resolveRoute()
        if route == .internalNetwork {
            return try await internalAdapter.readStream(path, range: range)
        }
        return try await externalAdapter.readStream(path, range: range)
    }

    func writeStream(_ path: String, data: AsyncThrowingStream<Data, Error>) async throws {
        // 数据流只能消费一次，内网失败后无法完整回退外网重写：直接抛出，由用户重试
        // （内网失败记为外网生效，重试直接走外网）。未锁定时先竞速判定再选址。
        let route = await resolveRoute()
        if route == .internalNetwork {
            do {
                try await internalAdapter.writeStream(path, data: data)
                lockRoute(.internalNetwork)
                return
            } catch {
                lockRoute(.externalNetwork)
                throw error
            }
        }
        try await externalAdapter.writeStream(path, data: data)
    }

    func move(_ src: String, _ dest: String) async throws {
        try await route({ try await internalAdapter.move(src, dest) },
                        externalOp: { try await externalAdapter.move(src, dest) })
    }

    func copy(_ src: String, _ dest: String) async throws {
        try await route({ try await internalAdapter.copy(src, dest) },
                        externalOp: { try await externalAdapter.copy(src, dest) })
    }

    func delete(_ path: String) async throws {
        try await route({ try await internalAdapter.delete(path) },
                        externalOp: { try await externalAdapter.delete(path) })
    }

    func mkdir(_ path: String) async throws {
        try await route({ try await internalAdapter.mkdir(path) },
                        externalOp: { try await externalAdapter.mkdir(path) })
    }

    func testConnection() async throws {
        // 手动测试 / 启动探测：清除旧锁定后竞速重新判定，成功即锁定生效地址
        activeRoute = nil
        clearLock()
        if let route = await raceRoute() {
            lockRoute(route)
            activeRoute = route
            return
        }
        // 竞速判定内外网均不可达：以外网真实错误对外反馈（保留原「不可达」提示语义）
        try await externalAdapter.testConnection()
        // 兜底：外网这次又可达则锁外网
        lockRoute(.externalNetwork)
        activeRoute = .externalNetwork
    }
}
