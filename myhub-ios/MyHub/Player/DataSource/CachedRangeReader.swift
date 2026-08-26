import Foundation

/// 缓存分片读取器（IOS-203 边下边播核心，参考 nPlayer 缓存架构）。
/// 请求区间按 1MB 分片对齐装配：命中缓存直接返回，未命中经数据源拉取并写盘（断点续播复用）；
/// in-flight 去重（同一分片并发请求合并）；读完后按预读窗口向后预取。
final class CachedRangeReader: @unchecked Sendable {
    let source: RangeDataSource
    let identity: SegmentCache.FileIdentity
    /// 内容缓存本地化开关（AppSettings.Cache.contentCachingEnabled）；关闭时直读不落盘
    let cachingEnabled: Bool
    /// 离线模式（IOS-605）：stat 失败后以缓存身份起播——未命中分片快速抛错，不重试不预取
    let offlineMode: Bool
    /// 预读开关：封面抽帧等一次性按需读取场景关闭，避免每次 read 向后预取 15MB
    /// 造成大量并发 NAS 请求（3 个视频 × 16 分片 = 48 并发）打爆连接导致文件头读取超时
    let prefetchEnabled: Bool

    private let inFlight = InFlightSegments()
    /// 预取并发信号量：限制同时在飞的分片预取数量，避免 seek/播放时大量并发请求打爆远端存储（Connection reset by peer）
    private let prefetchLimiter = PrefetchLimiter(limit: 3)
    /// 线程安全的网络拉取字节累计（跨分片/Task）
    private let networkBytes = NetworkByteCounter()

    var contentLength: Int64 { source.contentLength }

    /// 本 reader 生命周期内实际从数据源（网络）拉取的字节数（不含分片缓存命中）
    var networkBytesFetched: Int64 { networkBytes.total }

    init(source: RangeDataSource, identity: SegmentCache.FileIdentity, cachingEnabled: Bool, offlineMode: Bool = false, prefetchEnabled: Bool = true) {
        self.source = source
        self.identity = identity
        self.cachingEnabled = cachingEnabled
        self.offlineMode = offlineMode
        self.prefetchEnabled = prefetchEnabled
    }

    /// 取消所有 in-flight 分片拉取（播放器关闭 / 会话注销时调用），
    /// 阻止后台预取与未完成的 NAS 请求继续占用连接
    func cancel() {
        Task { await inFlight.cancelAll() }
    }

    /// 读取 [lowerBound, upperBound)：按分片装配，命中缓存的分片不再走网络
    func read(range: Range<Int64>) async throws -> Data {
        guard range.upperBound > range.lowerBound else { return Data() }
        let segLen = SegmentCache.segmentLength
        let firstSegment = range.lowerBound / segLen
        let lastSegment = (range.upperBound - 1) / segLen

        var result = Data()
        result.reserveCapacity(min(Int(range.count), 8 * 1024 * 1024))
        var index = firstSegment
        while index <= lastSegment {
            let data = try await segment(index)
            let segmentStart = index * segLen
            let cutLower = Int(max(range.lowerBound, segmentStart) - segmentStart)
            let cutUpper = Int(min(range.upperBound, segmentStart + Int64(data.count)) - segmentStart)
            if cutUpper > cutLower, cutLower >= 0, cutUpper <= data.count {
                result.append(contentsOf: data[cutLower..<cutUpper])
            }
            index += 1
        }
        prefetch(afterSegment: lastSegment)
        return result
    }

    /// 单分片：缓存命中直出；未命中拉取 + 写盘（in-flight 去重）；离线模式未命中即失败
    private func segment(_ index: Int64) async throws -> Data {
        // 离线兜底时无视本地化开关读存量缓存（开关只约束新内容是否落盘）
        if cachingEnabled || offlineMode,
           let cached = await SegmentCache.shared.data(file: identity, segment: index) {
            return cached
        }
        if offlineMode {
            throw StorageError.offline("该时段视频")
        }
        return try await inFlight.value(for: index) { [source, identity, cachingEnabled, networkBytes] in
            let lower = index * SegmentCache.segmentLength
            let upper = min(lower + SegmentCache.segmentLength, source.contentLength)
            let data = try await source.read(range: lower..<upper)
            networkBytes.add(Int64(data.count))
            if cachingEnabled {
                await SegmentCache.shared.store(file: identity, segment: index, data: data)
            }
            return data
        }
    }

    /// 预读窗口：当前位置向后预取（秒数 × 估算码率，AppSettings.Player.preloadSeconds 可配）；
    /// 弱网抖动时窗口内分片已就绪，保证平滑播放；离线模式不预取
    private func prefetch(afterSegment index: Int64) {
        guard prefetchEnabled, !offlineMode else { return }
        let count = max(1, Int(ceil(Double(Self.readaheadBytes) / Double(SegmentCache.segmentLength))))
        let maxSegment = (contentLength - 1) / SegmentCache.segmentLength
        for offset in 1...Int64(count) {
            let next = index + offset
            guard next <= maxSegment else { break }
            Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                await self.prefetchLimiter.acquire()
                _ = try? await self.segment(next)
                await self.prefetchLimiter.release()
            }
        }
    }

    /// 预读窗口字节数：preloadSeconds 秒 × 0.5MB/s（约 4Mbps 平均码率估算；默认 30s ≈ 15MB）
    static var readaheadBytes: Int64 {
        Int64(max(1, AppSettings.Player.preloadSeconds) * 0.5 * 1024 * 1024)
    }
}

/// 分片级 in-flight 去重：同一分片的并发拉取合并为一次网络请求
private actor InFlightSegments {
    private var tasks: [Int64: Task<Data, Error>] = [:]

    func value(for key: Int64, operation: @escaping @Sendable () async throws -> Data) async throws -> Data {
        if let existing = tasks[key] {
            return try await existing.value
        }
        let task = Task { try await operation() }
        tasks[key] = task
        defer { tasks[key] = nil }
        return try await task.value
    }

    /// 取消所有 in-flight 分片拉取：终止其底层 NAS 请求并释放连接（会话注销时调用）
    func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
    }
}

/// 预取并发信号量：限制同时在飞的分片预取数量（避免 seek/拖动时向后 15 个分片并发拉取打爆远端存储连接）
private actor PrefetchLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// 线程安全的字节计数器（跨 Task / 分片累计实际网络拉取量）
private final class NetworkByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0

    func add(_ bytes: Int64) {
        lock.lock()
        value += bytes
        lock.unlock()
    }

    var total: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
