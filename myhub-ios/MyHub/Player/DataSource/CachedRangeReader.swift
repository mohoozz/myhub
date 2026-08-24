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

    private let inFlight = InFlightSegments()

    var contentLength: Int64 { source.contentLength }

    init(source: RangeDataSource, identity: SegmentCache.FileIdentity, cachingEnabled: Bool, offlineMode: Bool = false) {
        self.source = source
        self.identity = identity
        self.cachingEnabled = cachingEnabled
        self.offlineMode = offlineMode
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
        return try await inFlight.value(for: index) { [source, identity, cachingEnabled] in
            let lower = index * SegmentCache.segmentLength
            let upper = min(lower + SegmentCache.segmentLength, source.contentLength)
            let data = try await source.read(range: lower..<upper)
            if cachingEnabled {
                await SegmentCache.shared.store(file: identity, segment: index, data: data)
            }
            return data
        }
    }

    /// 预读窗口：当前位置向后预取（秒数 × 估算码率，AppSettings.Player.preloadSeconds 可配）；
    /// 弱网抖动时窗口内分片已就绪，保证平滑播放；离线模式不预取
    private func prefetch(afterSegment index: Int64) {
        guard !offlineMode else { return }
        let count = max(1, Int(ceil(Double(Self.readaheadBytes) / Double(SegmentCache.segmentLength))))
        let maxSegment = (contentLength - 1) / SegmentCache.segmentLength
        for offset in 1...Int64(count) {
            let next = index + offset
            guard next <= maxSegment else { break }
            Task.detached(priority: .utility) { [weak self] in
                _ = try? await self?.segment(next)
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
}
