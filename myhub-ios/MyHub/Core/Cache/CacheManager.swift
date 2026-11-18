import Foundation

/// 沙盒 Caches 分区管理（《需求分析文档》§2.3 / IOS-605）。
/// 各分区均可重建、受系统清理；统一容量上限与 LRU（TODO §11）：
/// - 各分区配额按权重切分 `AppSettings.Cache.totalLimitMB`（权重和 = 1，配额之和 = 总预算），
///   超出只回收本分区；分区写入方在落盘后调用 `evictPartitionIfNeeded`（节流 10s）；
/// - 漫画/小说分区按「文件目录粒度」由 `FingerprintDiskCache` 整目录 LRU 淘汰（页/章需成组保留）；
/// - `enforceGlobalLimit` 为统一兜底：总占用超上限时跨分区按最久未访问淘汰（仅在启动时跑）。
final class CacheManager {
    static let shared = CacheManager()

    enum Partition: String, CaseIterable {
        case mediaSegments = "MediaSegments"   // 视频/音频边下边播分片
        case thumbnails = "Thumbnails"         // 封面缩略图
        case comicPages = "ComicPages"         // 漫画解压页
        case novelChapters = "NovelChapters"   // 小说章节
        case novelIndexes = "NovelIndexes"     // 小说章节索引（可重建）
        case directoryListings = "DirectoryListings"   // 目录结果缓存（IOS-102 二次进入加速）

        var displayName: String {
            switch self {
            case .mediaSegments: return "媒体分片缓存"
            case .thumbnails: return "封面缩略图"
            case .comicPages: return "漫画解压页"
            case .novelChapters: return "小说章节"
            case .novelIndexes: return "小说章节索引"
            case .directoryListings: return "目录缓存"
            }
        }
    }

    private let root: URL

    private init() {
        root = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyHub", isDirectory: true)
    }

    /// 分区目录（不存在则创建）
    func url(for partition: Partition) -> URL {
        let url = root.appendingPathComponent(partition.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 占用统计（设置页分类查看）

    func size(of partition: Partition) -> Int64 {
        directorySize(at: url(for: partition))
    }

    func totalSize() -> Int64 {
        Partition.allCases.reduce(0) { $0 + size(of: $1) }
    }

    // MARK: - 清理

    func clear(_ partition: Partition) throws {
        let dir = url(for: partition)
        let fm = FileManager.default
        for item in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            try fm.removeItem(at: item)
        }
    }

    func clearAll() throws {
        for partition in Partition.allCases {
            try clear(partition)
        }
    }

    // MARK: - 统一容量上限与 LRU（IOS-605）

    /// 各分区占总预算的权重（和恰为 1；均为 2 的负幂次，相加无误差）
    private static let weights: [Partition: Double] = [
        .mediaSegments: 0.5,        // 媒体分片由 SegmentCache 自管（含单文件 1/4 上限）
        .comicPages: 0.25,
        .thumbnails: 0.125,
        .novelChapters: 0.0625,
        .novelIndexes: 0.03125,
        .directoryListings: 0.03125
    ]

    /// 分区配额（字节）：派生自总预算 `AppSettings.Cache.totalLimitMB`。
    /// 按权重切分且各分区之和恰好 = 总预算。原先「保底配额 + 比例」相加超出预算
    /// （默认 2048MB 档合计 3008MB），超额只能靠启动时的跨分区回收兜底 → 容易挤掉别的分区缓存。
    func limitBytes(for partition: Partition) -> Int64 {
        let total = Int64(max(256, AppSettings.Cache.totalLimitMB)) * 1024 * 1024
        return Int64(Double(total) * (Self.weights[partition] ?? 0))
    }

    /// 命中刷新访问时间（mtime 即 lastAccess，供 LRU 淘汰）
    func touch(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: url.path
        )
    }

    /// 淘汰检查节流：统计分区占用要遍历整个分区（数千次 stat），原先每次写封面/目录都做一次，
    /// 写入稍多就把写入方（以及主线程上的统计）拖慢。短时超配额可接受，下一轮检查补上。
    private static let evictCheckInterval: TimeInterval = 10
    private var lastEvictCheck: [Partition: Date] = [:]
    private let evictCheckLock = NSLock()

    /// 淘汰单元：一个或多个需整组删除的文件
    private struct EvictionUnit {
        var urls: [URL]
        var size: Int64
        var mtime: Date
    }

    /// 分区内 LRU：占用超配额时按 mtime 从最旧开始删除，**只动本分区**。
    /// 封面分区的图片与元数据同名成对（`<key>.jpg` + `<key>.json`），成组删除：
    /// 只删图会留下“有元数据没图”的条目，命中后仍要重新发起网络请求。
    func evictPartitionIfNeeded(_ partition: Partition) {
        guard beginEvictCheck(partition) else { return }
        let limit = limitBytes(for: partition)
        let units = evictionUnits(of: partition)
        var total = units.reduce(Int64(0)) { $0 + $1.size }
        guard total > limit else { return }
        for unit in units.sorted(by: { $0.mtime < $1.mtime }) {
            guard total > limit else { break }
            remove(unit)
            total -= unit.size
        }
    }

    /// 统一上限兜底：总占用超总预算时，跨分区按最久未访问淘汰（媒体分片由 SegmentCache 自管不动）。
    /// 各分区配额之和已 = 总预算，正常运行不会走到这里（仅启动时作为保险跑一次，
    /// 避免运行期因某分区写满就跨区回收别的分区缓存）。
    /// 漫画/小说分区按文件目录整体淘汰（页/章成组保留），其余分区按单文件（封面成对）。
    func enforceGlobalLimit() {
        let limit = Int64(max(256, AppSettings.Cache.totalLimitMB)) * 1024 * 1024
        var total = totalSize()
        guard total > limit else { return }
        var units: [EvictionUnit] = []
        for partition in Partition.allCases {
            switch partition {
            case .mediaSegments:
                continue   // 自管 LRU，上限即分区配额
            case .comicPages, .novelChapters:
                units.append(contentsOf: directoryUnits(of: partition))
            default:
                units.append(contentsOf: evictionUnits(of: partition))
            }
        }
        for unit in units.sorted(by: { $0.mtime < $1.mtime }) {
            guard total > limit else { break }
            remove(unit)
            total -= unit.size
        }
    }

    /// 配额变更后立即按新上限回收（绕过节流门），避免要等下次写入才回落。
    /// 漫画/小说分区由 `FingerprintDiskCache` 按目录粒度自管（会保留元数据），这里不能按单文件裁。
    func evictAllPartitions() {
        evictCheckLock.lock()
        lastEvictCheck.removeAll()
        evictCheckLock.unlock()
        for partition in Partition.allCases {
            switch partition {
            case .mediaSegments, .comicPages, .novelChapters:
                continue
            default:
                evictPartitionIfNeeded(partition)
            }
        }
    }

    /// 节流门：距上次检查不足 `evictCheckInterval` 则跳过（返回 false）
    private func beginEvictCheck(_ partition: Partition) -> Bool {
        let now = Date()
        evictCheckLock.lock()
        defer { evictCheckLock.unlock() }
        if let last = lastEvictCheck[partition],
           now.timeIntervalSince(last) < Self.evictCheckInterval {
            return false
        }
        lastEvictCheck[partition] = now
        return true
    }

    private func remove(_ unit: EvictionUnit) {
        for url in unit.urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 分区内淘汰单元：默认单文件；封面分区把同名「图片 + json」合并为一个单元
    private func evictionUnits(of partition: Partition) -> [EvictionUnit] {
        let files = fileUnits(of: partition)
        guard partition == .thumbnails else { return files }
        var grouped: [String: EvictionUnit] = [:]
        for file in files {
            guard let url = file.urls.first else { continue }
            let key = url.deletingLastPathComponent().path
                + "|" + url.deletingPathExtension().lastPathComponent
            if var unit = grouped[key] {
                unit.urls.append(url)
                unit.size += file.size
                unit.mtime = max(unit.mtime, file.mtime)
            } else {
                grouped[key] = file
            }
        }
        return Array(grouped.values)
    }

    /// 淘汰单元（单文件）：分区目录下所有普通文件
    private func fileUnits(of partition: Partition) -> [EvictionUnit] {
        let dir = url(for: partition)
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        ) else { return [] }
        var units: [EvictionUnit] = []
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            )
            guard values?.isRegularFile == true else { continue }
            units.append(EvictionUnit(
                urls: [file],
                size: Int64(values?.fileSize ?? 0),
                mtime: values?.contentModificationDate ?? .distantPast
            ))
        }
        return units
    }

    /// 淘汰单元（目录粒度）：分区下的每个文件缓存目录（mtime 取 _identity.json 访问时间）
    private func directoryUnits(of partition: Partition) -> [EvictionUnit] {
        let dir = url(for: partition)
        let subs = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        var units: [EvictionUnit] = []
        for sub in subs {
            guard (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let identity = sub.appendingPathComponent("_identity.json")
            let mtime = (try? identity.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
                ?? (try? sub.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
                ?? .distantPast
            units.append(EvictionUnit(urls: [sub], size: directorySize(at: sub), mtime: mtime))
        }
        return units
    }

    private func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}
