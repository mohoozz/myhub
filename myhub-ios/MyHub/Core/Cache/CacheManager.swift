import Foundation

/// 沙盒 Caches 分区管理（《需求分析文档》§2.3 / IOS-605）。
/// 各分区均可重建、受系统清理；统一容量上限与 LRU（TODO §11）：
/// - 各分区配额派生自 `AppSettings.Cache.totalLimitMB`，分区写入方在落盘后调用 `evictPartitionIfNeeded`；
/// - 漫画/小说分区按「文件目录粒度」由 `FingerprintDiskCache` 整目录 LRU 淘汰（页/章需成组保留）；
/// - `enforceGlobalLimit` 为统一兜底：总占用超上限时跨分区按最久未访问淘汰。
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

    /// 分区配额（字节）：派生自总预算 `AppSettings.Cache.totalLimitMB`，一处配置全局受控
    func limitBytes(for partition: Partition) -> Int64 {
        let total = Int64(max(256, AppSettings.Cache.totalLimitMB)) * 1024 * 1024
        switch partition {
        case .mediaSegments: return total                  // SegmentCache 自管（含单文件 1/4 上限）
        case .comicPages: return max(256 * 1024 * 1024, total / 4)
        case .thumbnails: return max(64 * 1024 * 1024, total / 8)
        case .novelChapters: return max(32 * 1024 * 1024, total / 16)
        case .novelIndexes: return max(16 * 1024 * 1024, total / 64)
        case .directoryListings: return max(16 * 1024 * 1024, total / 64)
        }
    }

    /// 命中刷新访问时间（mtime 即 lastAccess，供 LRU 淘汰）
    func touch(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: url.path
        )
    }

    /// 文件粒度 LRU：分区占用超配额时按 mtime 从最旧开始删除（thumbnails / directoryListings / novelIndexes 用）
    func evictPartitionIfNeeded(_ partition: Partition) {
        let limit = limitBytes(for: partition)
        var total = size(of: partition)
        guard total > limit else { return }
        for unit in fileUnits(of: partition).sorted(by: { $0.mtime < $1.mtime }) {
            guard total > limit else { break }
            try? FileManager.default.removeItem(at: unit.url)
            total -= unit.size
        }
    }

    /// 统一上限兜底：总占用超总预算时，跨分区按最久未访问淘汰（媒体分片由 SegmentCache 自管不动）
    /// 漫画/小说分区按文件目录整体淘汰（页/章成组保留），其余分区按单文件。
    func enforceGlobalLimit() {
        let limit = Int64(max(256, AppSettings.Cache.totalLimitMB)) * 1024 * 1024
        var total = totalSize()
        guard total > limit else { return }
        var units: [(url: URL, size: Int64, mtime: Date)] = []
        for partition in Partition.allCases {
            switch partition {
            case .mediaSegments:
                continue   // 自管 LRU，上限即总预算
            case .comicPages, .novelChapters:
                units.append(contentsOf: directoryUnits(of: partition))
            default:
                units.append(contentsOf: fileUnits(of: partition))
            }
        }
        for unit in units.sorted(by: { $0.mtime < $1.mtime }) {
            guard total > limit else { break }
            try? FileManager.default.removeItem(at: unit.url)
            total -= unit.size
        }
    }

    /// 淘汰单元（单文件）：分区目录下所有普通文件
    private func fileUnits(of partition: Partition) -> [(url: URL, size: Int64, mtime: Date)] {
        let dir = url(for: partition)
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        ) else { return [] }
        var units: [(URL, Int64, Date)] = []
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            )
            guard values?.isRegularFile == true else { continue }
            units.append((
                file,
                Int64(values?.fileSize ?? 0),
                values?.contentModificationDate ?? .distantPast
            ))
        }
        return units
    }

    /// 淘汰单元（目录粒度）：分区下的每个文件缓存目录（mtime 取 _identity.json 访问时间）
    private func directoryUnits(of partition: Partition) -> [(url: URL, size: Int64, mtime: Date)] {
        let dir = url(for: partition)
        let subs = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        var units: [(URL, Int64, Date)] = []
        for sub in subs {
            guard (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let identity = sub.appendingPathComponent("_identity.json")
            let mtime = (try? identity.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
                ?? (try? sub.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
                ?? .distantPast
            units.append((sub, directorySize(at: sub), mtime))
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
