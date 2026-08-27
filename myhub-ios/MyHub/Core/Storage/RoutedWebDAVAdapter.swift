import Foundation

/// 连接路由：实际生效的是内网还是外网地址
enum ConnectionRoute: Equatable {
    case internalNetwork
    case externalNetwork
}

/// WebDAV 内外网双地址适配器（路径源优化，IOS-101 / TODO 324）：
/// - 启动时 / 用户手动「测试连接」时探测一次内网地址，成功即锁定生效路由（内网/外网），
///   后续所有操作一直使用锁定地址，不再重复探测；
/// - 锁定结果按「内网根 URL」进程级共享：目录浏览每进入一级目录都会新建适配器实例，
///   共享后各实例复用同一份判定结论，外网环境下不再出现每次进目录都等待内网超时的问题；
/// - 尚未判定（锁定前）的业务请求按内网优先探测式回退，首次成功即完成锁定；
/// - 重新判定时机只有两个：用户手动「测试连接」、重启 App。
final class RoutedWebDAVAdapter: StorageAdapter {
    /// 进程级路由锁定表：key = 内网根 URL，缺省 = 尚未判定
    private static let sharedLock = NSLock()
    private static var lockedRouteByURL: [String: ConnectionRoute] = [:]

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

    /// 是否应走内网：已锁定按锁定结果；未锁定则内网优先（内网用 5s 短超时兜底回退）
    private var shouldUseInternal: Bool {
        lockedRoute != .externalNetwork
    }

    /// 未锁定时按内网优先探测，首次成功即锁定生效路由；已锁定时直接走锁定地址。
    /// 内网失败、外网也失败时保持未锁定，交由下次判定（测试连接/重启）重新探测。
    private func route<T>(
        _ internalOp: () async throws -> T,
        externalOp: () async throws -> T
    ) async throws -> T {
        if let lockedRoute {
            return lockedRoute == .internalNetwork
                ? try await internalOp()
                : try await externalOp()
        }
        do {
            let value = try await internalOp()
            lockRoute(.internalNetwork)
            return value
        } catch {
            let value = try await externalOp()
            lockRoute(.externalNetwork)
            return value
        }
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
        // 流式传输无法在流内切换地址：按当前路由决策直接选取，避免中途断流
        if shouldUseInternal {
            return try await internalAdapter.readStream(path, range: range)
        }
        return try await externalAdapter.readStream(path, range: range)
    }

    func writeStream(_ path: String, data: AsyncThrowingStream<Data, Error>) async throws {
        // 数据流只能消费一次，内网失败后无法完整回退外网重写：直接抛出，由用户重试
        // （未锁定时内网失败记为外网生效，重试直接走外网）
        if shouldUseInternal {
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
        // 手动测试 / 启动探测：总是重新判定一次，成功即锁定生效地址
        activeRoute = nil
        do {
            try await internalAdapter.testConnection()
            lockRoute(.internalNetwork)
            activeRoute = .internalNetwork
        } catch {
            try await externalAdapter.testConnection()
            lockRoute(.externalNetwork)
            activeRoute = .externalNetwork
        }
    }
}
