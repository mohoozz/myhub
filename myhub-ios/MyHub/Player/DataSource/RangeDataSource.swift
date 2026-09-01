import Foundation

/// 可 Range 读取的数据源（《需求分析文档》§4.3 数据源层）：
/// 本地文件 / WebDAV HTTP Range / SMB 分块统一为随机访问读取，供播放器/阅读器按需拉取。
protocol RangeDataSource: AnyObject {
    var contentLength: Int64 { get }
    func read(range: Range<Int64>) async throws -> Data
}

/// 存储适配器数据源。
/// 弱网自适应（TODO 356）：增量流式下载 + 停滞超时（只要持续收到数据就不超时）+ 断点续传
/// （超时/中断保留已下载数据、从断点续拉不重下）+ 连续零进展退避重试；
/// 拖动进度条时由上层传入目标区间，实现秒开与快速 seek。
final class AdapterRangeDataSource: RangeDataSource, @unchecked Sendable {
    let adapter: StorageAdapter
    let path: String
    let contentLength: Int64
    /// 连续「零进展」容忍次数（离线模式传 1 快速失败）；有进展即清零持续续传，已缓存分片不经过数据源
    let maxAttempts: Int
    /// 停滞判定阈值（秒）：连续无新字节到达超过该时长才视为停滞（TODO 356）
    let stallTimeout: TimeInterval = 15

    init(adapter: StorageAdapter, path: String, contentLength: Int64, maxAttempts: Int = 3) {
        self.adapter = adapter
        self.path = path
        self.contentLength = contentLength
        self.maxAttempts = max(1, maxAttempts)
    }

    func read(range: Range<Int64>) async throws -> Data {
        guard range.count > 0 else { return Data() }
        var accumulated = Data()
        accumulated.reserveCapacity(Int(range.count))
        var lastError: Error = PlayerPlaybackError("数据读取失败")
        var stallStrikes = 0   // 连续「零进展」次数：有进展即清零，弱网慢速持续下载不因固定次数被判失败

        while Int64(accumulated.count) < range.count {
            if Task.isCancelled { throw CancellationError() }
            let start = range.lowerBound + Int64(accumulated.count)
            let before = accumulated.count
            do {
                // 断点续传（TODO 356）：从已累积末尾继续请求剩余区间
                let part = try await collectStalled(range: start..<range.upperBound)
                accumulated.append(part)
            } catch let partial as PartialReadError {
                // 停滞超时 / 中途失败：保留已收到的字节，下一轮从断点续传（不丢弃、不重下）
                accumulated.append(partial.data)
                lastError = partial.underlying
                if partial.underlying is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
            }

            if Int64(accumulated.count) >= range.count { return accumulated }

            if accumulated.count > before {
                stallStrikes = 0   // 本轮有进展，继续续传直至取满
            } else {
                stallStrikes += 1
                if stallStrikes >= maxAttempts { break }
                try? await Task.sleep(nanoseconds: UInt64(stallStrikes) * 400_000_000)
            }
        }

        if Int64(accumulated.count) >= range.count { return accumulated }
        throw lastError
    }

    /// 停滞超时收集：只要在持续接收数据就不超时；连续 `stallTimeout` 秒无新字节判定停滞，
    /// 抛出 `PartialReadError` 携带已收数据供断点续传（TODO 356）。
    /// 相比旧的「整段绝对超时」，弱网慢速但持续的下载不会被误杀、已下载数据不作废。
    private func collectStalled(range: Range<Int64>) async throws -> Data {
        let stream = try await adapter.readStream(path, range: range)
        let stall = StallGuard()
        return try await withThrowingTaskGroup(of: Data?.self) { group in
            // 消费者：累积网络分块；流正常结束返回完整快照
            group.addTask {
                for try await chunk in stream {
                    try Task.checkCancellation()
                    await stall.append(chunk)
                }
                return await stall.snapshot()
            }
            // 看门狗：周期检查距上次收到数据的空闲时长，超过阈值判停滞
            let timeout = stallTimeout
            group.addTask {
                while true {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    let idle = await stall.idleSeconds(now: ProcessInfo.processInfo.systemUptime)
                    if idle >= timeout {
                        throw PlayerPlaybackError("网络停滞超时")
                    }
                }
            }
            do {
                let result = try await group.next() ?? nil
                group.cancelAll()
                return result ?? Data()
            } catch {
                group.cancelAll()
                // 带出已累积的部分数据供上层断点续传
                let partial = await stall.snapshot()
                throw PartialReadError(data: partial, underlying: error)
            }
        }
    }
}

/// 停滞看门狗共享状态（actor 串行化累积与时间戳读写，供停滞超时断点续传，TODO 356）
private actor StallGuard {
    private var data = Data()
    private var lastAdvance: TimeInterval = ProcessInfo.processInfo.systemUptime

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        data.append(chunk)
        lastAdvance = ProcessInfo.processInfo.systemUptime
    }

    func snapshot() -> Data { data }

    func idleSeconds(now: TimeInterval) -> TimeInterval { now - lastAdvance }
}

/// 停滞超时 / 中途失败时携带已下载的部分数据，供上层断点续传（TODO 356）
private struct PartialReadError: Error {
    let data: Data
    let underlying: Error
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
