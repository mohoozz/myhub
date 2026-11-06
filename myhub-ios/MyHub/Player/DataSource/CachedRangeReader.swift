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
    /// 预读开关：封面抽帧等一次性按需读取场景关闭，避免每次 read 向后预取整个窗口
    /// 造成大量并发 NAS 请求（3 个视频 × 多分片并发）打爆连接导致文件头读取超时
    let prefetchEnabled: Bool
    /// 网络拉取字节上限（nil = 不限，TODO 404）：封面抽帧专用护栏。
    /// AVFoundation / VLC 对 moov 后置文件会发起「读整个文件」Range 请求（几 GB），
    /// 超出上限即自我注销取消，避免单个封面吃光连接与带宽、拖垮播放与后续封面。
    let networkByteBudget: Int64?

    private let inFlight = InFlightSegments()
    /// 预取并发信号量：限制同时在飞的分片预取数量，避免 seek/播放时大量并发请求打爆远端存储（Connection reset by peer）
    private let prefetchLimiter = PrefetchLimiter(limit: 3)
    /// 预读窗口记账：同一分片只安排一次预取（read 每 512KB 触发一次，不去重会反复预取同一窗口）
    private let prefetchTracker = PrefetchTracker()
    /// 线程安全的网络拉取字节累计（跨分片/Task）
    private let networkBytes = NetworkByteCounter()
    /// 会话取消标记（TODO 372）：置位后拒绝一切新的读取/预取网络请求
    private let cancelFlag = CancelFlag()

    var contentLength: Int64 { source.contentLength }

    /// 会话是否已注销取消（取消后 read/segment/预取不再发起任何新请求）
    var isCancelled: Bool { cancelFlag.isCancelled }

    /// 本 reader 生命周期内实际从数据源（网络）拉取的字节数（不含分片缓存命中）
    var networkBytesFetched: Int64 { networkBytes.total }

    init(
        source: RangeDataSource,
        identity: SegmentCache.FileIdentity,
        cachingEnabled: Bool,
        offlineMode: Bool = false,
        prefetchEnabled: Bool = true,
        networkByteBudget: Int64? = nil
    ) {
        self.source = source
        self.identity = identity
        self.cachingEnabled = cachingEnabled
        self.offlineMode = offlineMode
        self.prefetchEnabled = prefetchEnabled
        self.networkByteBudget = networkByteBudget
    }

    /// 取消所有 in-flight 分片拉取（播放器关闭 / 会话注销时调用），
    /// 阻止后台预取与未完成的 NAS 请求继续占用连接。
    /// 先置取消标记再取消在途请求：read/segment 之后直接失败、排队中的预取任务获得额度后立即退出、
    /// in-flight 去重器拒绝 cancel 之后的新请求——避免快速切换视频时旧视频的残留分片请求
    /// （预读窗口 3MB）继续占用连接池与 NAS 带宽，拖慢新视频加载（TODO 372）
    func cancel() {
        guard cancelFlag.markCancelled() else { return }
        AppLogger.shared.log(
            "reader 已取消（会话注销），停止后续分片拉取与预取",
            level: .info, module: "stream"
        )
        Task { await inFlight.cancelAll() }
    }

    /// 读取 [lowerBound, upperBound)：按分片装配，命中缓存的分片不再走网络
    func read(range: Range<Int64>) async throws -> Data {
        guard !isCancelled else { throw CancellationError() }
        guard range.upperBound > range.lowerBound else { return Data() }
        let segLen = SegmentCache.segmentLength
        let firstSegment = range.lowerBound / segLen
        let lastSegment = (range.upperBound - 1) / segLen

        var result = Data()
        result.reserveCapacity(min(Int(range.count), 8 * 1024 * 1024))
        var index = firstSegment
        while index <= lastSegment {
            guard !isCancelled else { throw CancellationError() }
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
        guard !isCancelled else { throw CancellationError() }
        // 离线兜底时无视本地化开关读存量缓存（开关只约束新内容是否落盘）
        if cachingEnabled || offlineMode,
           let cached = await SegmentCache.shared.data(file: identity, segment: index) {
            return cached
        }
        if offlineMode {
            throw StorageError.offline("该时段视频")
        }
        // 网络预算护栏（TODO 404）：超限即注销取消，阻断后续分片与预取，
        // 把失控的「整文件抽帧」限制在可控流量内
        if let budget = networkByteBudget, networkBytes.total >= budget {
            AppLogger.shared.log(
                "reader 网络拉取超出上限 \(DisplayFormatters.size(budget))，取消会话（避免占满连接池）",
                level: .warn, module: "stream"
            )
            cancel()
            throw PlayerPlaybackError("网络拉取超出上限")
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

    /// 预读窗口：当前位置向后预取固定 3 个分片（发热优化）。
    /// - 逐分片去重：read 由串流代理按 512KB 一块反复调用，不去重时同一窗口会被反复预取，
    ///   每次即使命中磁盘缓存也是一次 1MB 文件读 + Data 拷贝，持续播放即持续发热；
    /// - 窗口与 `preloadSeconds` 解耦：后者是播放器内部前向缓冲目标（AVPlayer/VLC），
    ///   代理侧预读只需覆盖网络抖动，窗口过大会让边下边播长期满速下载并反复写盘。
    private func prefetch(afterSegment index: Int64) {
        guard prefetchEnabled, !offlineMode, !isCancelled else { return }
        let count = max(1, Int(ceil(Double(Self.readaheadBytes) / Double(SegmentCache.segmentLength))))
        let maxSegment = (contentLength - 1) / SegmentCache.segmentLength
        let upper = min(index + Int64(count), maxSegment)
        guard upper > index else { return }
        // 只认领窗口内尚未安排过的分片：播放推进时窗口整体前移，重复 read 直接空转返回
        let claimed = prefetchTracker.claim(
            Array((index + 1)...upper), droppingBelow: index + 1
        )
        guard !claimed.isEmpty else { return }
        for next in claimed {
            Task.detached(priority: .utility) { [weak self] in
                guard let self, !self.isCancelled else { return }
                await self.prefetchLimiter.acquire()
                // 排队等待并发额度期间会话可能已注销（快速切换视频）：
                // 立即归还额度退出，不再发起残留分片请求（TODO 372）
                guard !self.isCancelled else {
                    await self.prefetchLimiter.release()
                    return
                }
                do {
                    _ = try await self.segment(next)
                } catch {
                    // 预取失败/取消：归还认领，后续 read 仍可重试该分片
                    self.prefetchTracker.release(next)
                }
                await self.prefetchLimiter.release()
            }
        }
    }

    /// 预读窗口字节数：固定 3MB（3 个分片，约 6 秒 4Mbps 片源）。
    /// 旧实现按 preloadSeconds × 0.5MB/s 取到 15MB，等于随播放持续满速下载整片并全量落盘缓存。
    static var readaheadBytes: Int64 { 3 * 1024 * 1024 }
}

/// 预读窗口记账（线程安全）：记录已安排预取的分片号，避免同一分片被反复预取。
private final class PrefetchTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled: Set<Int64> = []

    /// 认领窗口内尚未安排的分片；顺带丢弃落后于当前播放位置的记录，避免集合随播放无限增长
    func claim(_ indices: [Int64], droppingBelow lowerBound: Int64) -> [Int64] {
        lock.lock()
        defer { lock.unlock() }
        if scheduled.contains(where: { $0 < lowerBound }) {
            scheduled = scheduled.filter { $0 >= lowerBound }
        }
        var claimed: [Int64] = []
        for index in indices where !scheduled.contains(index) {
            scheduled.insert(index)
            claimed.append(index)
        }
        return claimed
    }

    /// 预取失败后归还认领，允许后续重试
    func release(_ index: Int64) {
        lock.lock()
        scheduled.remove(index)
        lock.unlock()
    }
}

/// 分片级 in-flight 去重：同一分片的并发拉取合并为一次网络请求
private actor InFlightSegments {
    private var tasks: [Int64: Task<Data, Error>] = [:]
    /// 已取消标记：cancelAll 后拒绝一切新请求——覆盖「取消瞬间恰好有新 segment 正在进入」的
    /// 竞态窗口，避免会话注销后又新建 NAS 请求（TODO 372）
    private var cancelled = false

    func value(for key: Int64, operation: @escaping @Sendable () async throws -> Data) async throws -> Data {
        guard !cancelled else { throw CancellationError() }
        if let existing = tasks[key] {
            return try await existing.value
        }
        let task = Task { try await operation() }
        tasks[key] = task
        defer { tasks[key] = nil }
        return try await task.value
    }

    /// 取消所有 in-flight 分片拉取并置取消标记：终止底层 NAS 请求、释放连接（会话注销时调用），
    /// 之后同一 reader 不会再发起任何新请求
    func cancelAll() {
        cancelled = true
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
    }
}

/// 线程安全的取消标记：NSLock 保护，跨 Task / 线程读写安全（TODO 372）
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// 首次置位返回 true（幂等：重复 cancel 不重复触发）
    func markCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !value else { return false }
        value = true
        return true
    }
}

/// 预取并发信号量：限制同时在飞的分片预取数量（避免 seek/拖动时整窗口分片并发拉取打爆远端存储连接）
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
