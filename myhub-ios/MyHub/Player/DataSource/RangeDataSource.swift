import Foundation

/// 可 Range 读取的数据源（《需求分析文档》§4.3 数据源层）：
/// 本地文件 / WebDAV HTTP Range / SMB 分块统一为随机访问读取，供播放器/阅读器按需拉取。
protocol RangeDataSource: AnyObject {
    var contentLength: Int64 { get }
    func read(range: Range<Int64>) async throws -> Data
}

/// 存储适配器数据源。
/// 弱网自适应：单次读取超时递增（10s / 20s / 30s）+ 最多 3 次重试 + 退避间隔；
/// 拖动进度条时由上层传入目标区间，实现秒开与快速 seek。
final class AdapterRangeDataSource: RangeDataSource, @unchecked Sendable {
    let adapter: StorageAdapter
    let path: String
    let contentLength: Int64
    /// 重试次数（离线模式传 1 快速失败，已缓存分片不经过数据源）
    let maxAttempts: Int

    init(adapter: StorageAdapter, path: String, contentLength: Int64, maxAttempts: Int = 3) {
        self.adapter = adapter
        self.path = path
        self.contentLength = contentLength
        self.maxAttempts = max(1, maxAttempts)
    }

    func read(range: Range<Int64>) async throws -> Data {
        guard range.count > 0 else { return Data() }
        var lastError: Error = PlayerPlaybackError("数据读取失败")
        for attempt in 1...maxAttempts {
            do {
                return try await withTimeout(seconds: 10 * Double(attempt)) {
                    try await self.collect(range: range)
                }
            } catch {
                // 任务取消（播放器关闭 / 会话注销）快速失败，不再重试发起新的 NAS 请求
                if Task.isCancelled {
                    throw CancellationError()
                }
                lastError = error
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 400_000_000)
                }
            }
        }
        throw lastError
    }

    private func collect(range: Range<Int64>) async throws -> Data {
        let stream = try await adapter.readStream(path, range: range)
        var data = Data()
        data.reserveCapacity(Int(range.count))
        for try await chunk in stream {
            data.append(chunk)
        }
        guard !data.isEmpty else { throw PlayerPlaybackError("数据读取为空") }
        return data
    }
}

/// 带超时的异步执行（超时取消并抛错）
func withTimeout<T>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw PlayerPlaybackError("网络读取超时")
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
