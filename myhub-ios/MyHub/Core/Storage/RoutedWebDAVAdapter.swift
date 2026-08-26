import Foundation

/// 连接路由：实际生效的是内网还是外网地址
enum ConnectionRoute: Equatable {
    case internalNetwork
    case externalNetwork
}

/// WebDAV 内外网双地址适配器（路径源优化，IOS-101）：
/// - 进入连接源时优先走内网地址，内网不可达自动回退外网；
/// - 内网失败进入冷却期（默认 3 分钟），冷却期内直接走外网，避免每次操作都重复超时；
/// - `testConnection()` 总是先探测内网，成功后在 `activeRoute` 上报告实际生效路径（内网/外网），
///   供列表绿点旁提示、表单测试结果展示。
final class RoutedWebDAVAdapter: StorageAdapter {
    /// 内网失败后的冷却时长：期间不再尝试内网
    static let internalRetryInterval: TimeInterval = 180

    private let internalAdapter: WebDAVAdapter
    private let externalAdapter: WebDAVAdapter

    /// 最近一次 testConnection 生效的路径（nil = 尚未测试）
    private(set) var activeRoute: ConnectionRoute?

    private struct State {
        var internalFailedAt: Date?
    }
    private var state = State()
    private let lock = NSLock()

    init(internalAdapter: WebDAVAdapter, externalAdapter: WebDAVAdapter) {
        self.internalAdapter = internalAdapter
        self.externalAdapter = externalAdapter
    }

    // MARK: - 路由决策

    /// 是否应走内网：无失败记录，或已过冷却期则重试内网
    private var shouldUseInternal: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let failedAt = state.internalFailedAt else { return true }
        return Date().timeIntervalSince(failedAt) >= Self.internalRetryInterval
    }

    private func markInternalFailed() {
        lock.lock(); defer { lock.unlock() }
        state.internalFailedAt = Date()
    }

    private func markInternalOK() {
        lock.lock(); defer { lock.unlock() }
        state.internalFailedAt = nil
    }

    // MARK: - StorageAdapter（内网优先，失败回退外网）

    func list(_ dir: String) async throws -> [FileEntry] {
        if shouldUseInternal {
            do {
                let entries = try await internalAdapter.list(dir)
                markInternalOK()
                return entries
            } catch {
                markInternalFailed()
            }
        }
        return try await externalAdapter.list(dir)
    }

    func stat(_ path: String) async throws -> FileEntry {
        if shouldUseInternal {
            do {
                let entry = try await internalAdapter.stat(path)
                markInternalOK()
                return entry
            } catch {
                markInternalFailed()
            }
        }
        return try await externalAdapter.stat(path)
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
        // （此时内网已进入冷却，下次重试会直接走外网）
        if shouldUseInternal {
            do {
                try await internalAdapter.writeStream(path, data: data)
                markInternalOK()
                return
            } catch {
                markInternalFailed()
                throw error
            }
        }
        try await externalAdapter.writeStream(path, data: data)
    }

    func move(_ src: String, _ dest: String) async throws {
        if shouldUseInternal {
            do {
                try await internalAdapter.move(src, dest)
                markInternalOK()
                return
            } catch {
                markInternalFailed()
            }
        }
        try await externalAdapter.move(src, dest)
    }

    func copy(_ src: String, _ dest: String) async throws {
        if shouldUseInternal {
            do {
                try await internalAdapter.copy(src, dest)
                markInternalOK()
                return
            } catch {
                markInternalFailed()
            }
        }
        try await externalAdapter.copy(src, dest)
    }

    func delete(_ path: String) async throws {
        if shouldUseInternal {
            do {
                try await internalAdapter.delete(path)
                markInternalOK()
                return
            } catch {
                markInternalFailed()
            }
        }
        try await externalAdapter.delete(path)
    }

    func mkdir(_ path: String) async throws {
        if shouldUseInternal {
            do {
                try await internalAdapter.mkdir(path)
                markInternalOK()
                return
            } catch {
                markInternalFailed()
            }
        }
        try await externalAdapter.mkdir(path)
    }

    func testConnection() async throws {
        // 测试总是先探测内网，让用户明确看到当前哪条路径可用
        do {
            try await internalAdapter.testConnection()
            markInternalOK()
            activeRoute = .internalNetwork
            return
        } catch {
            markInternalFailed()
        }
        try await externalAdapter.testConnection()
        activeRoute = .externalNetwork
    }
}
