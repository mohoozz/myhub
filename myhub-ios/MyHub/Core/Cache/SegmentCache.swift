import CryptoKit
import Foundation

/// 视频/音频边下边播分片磁盘缓存（IOS-203 / IOS-605，参考 nPlayer 缓存架构）。
/// - 分片 1MB；命中直接返回，未命中由上层（CachedRangeReader）拉取并写盘；
/// - LRU 淘汰 + 总容量上限（AppSettings.Cache.totalLimitMB）+ 单文件上限（总额 1/4）；
/// - 缓存键含文件指纹（fileSize + modTime）：文件被替换则键变、旧分片经 LRU 自然淘汰；
/// - 断点续播复用：重进同一文件命中已持久化分片，无需重新下载。
actor SegmentCache {
    static let shared = SegmentCache()
    static let segmentLength: Int64 = 1024 * 1024

    /// 缓存文件身份：连接 + 路径 + 指纹（Codable 供离线身份反查与内容缓存分区共享）
    struct FileIdentity: Codable, Sendable {
        let connectionID: Int64
        let path: String
        let size: Int64
        let modTime: TimeInterval

        var key: String {
            let raw = "\(connectionID)|\(path)|\(size)|\(Int64(modTime))"
            return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    private struct FileMeta: Codable {
        var lastAccess: Date
        var totalBytes: Int64
        /// 缓存身份（离线反查用；旧版索引缺省为 nil，随下次写入补齐）
        var identity: FileIdentity?
    }

    private var metas: [String: FileMeta] = [:]
    private var indexLoaded = false

    private init() {}

    // MARK: - 读取 / 写入

    /// 读取分片（命中更新访问时间；未命中返回 nil 由上层拉取）
    func data(file: FileIdentity, segment index: Int64) -> Data? {
        loadIndexIfNeeded()
        let key = file.key
        guard let data = try? Data(contentsOf: segmentURL(key: key, index: index)) else { return nil }
        metas[key]?.lastAccess = Date()
        return data
    }

    /// 写入分片并执行单文件上限 / 全库 LRU 淘汰
    func store(file: FileIdentity, segment index: Int64, data: Data) {
        loadIndexIfNeeded()
        let key = file.key
        let dir = directory(for: key)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = segmentURL(key: key, index: index)
        let existed = FileManager.default.fileExists(atPath: url.path)
        try? data.write(to: url, options: .atomic)

        var meta = metas[key] ?? FileMeta(lastAccess: Date(), totalBytes: 0)
        meta.lastAccess = Date()
        meta.identity = file
        if !existed { meta.totalBytes += Int64(data.count) }
        metas[key] = meta

        enforceFileCap(key: key, aroundIndex: index)
        saveIndex()
        evictIfNeeded()
    }

    /// 主动清除某文件全部分片（文件删除等场景）
    func remove(file: FileIdentity) {
        loadIndexIfNeeded()
        let key = file.key
        try? FileManager.default.removeItem(at: directory(for: key))
        metas.removeValue(forKey: key)
        saveIndex()
    }

    /// 离线身份反查（IOS-605）：stat 失败（无网络）时按连接 + 路径取回最近访问的缓存身份，
    /// 命中后已缓存分片可离线播放（键与在线时一致）
    func cachedIdentity(connectionID: Int64, path: String) -> FileIdentity? {
        loadIndexIfNeeded()
        return metas
            .filter { $0.value.identity?.connectionID == connectionID && $0.value.identity?.path == path }
            .sorted { $0.value.lastAccess > $1.value.lastAccess }
            .compactMap(\.value.identity)
            .first
    }

    // MARK: - LRU / 容量

    private var totalLimitBytes: Int64 {
        Int64(max(256, AppSettings.Cache.totalLimitMB)) * 1024 * 1024
    }

    private var fileLimitBytes: Int64 { totalLimitBytes / 4 }

    /// 单文件上限：距当前播放位置最远的分片优先淘汰（预读向前，回退方向分片重新拉取即可）
    private func enforceFileCap(key: String, aroundIndex: Int64) {
        guard let meta = metas[key], meta.totalBytes > fileLimitBytes else { return }
        let dir = directory(for: key)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let segments = names
            .compactMap { name -> (url: URL, index: Int64)? in
                guard let idx = Self.segmentIndex(from: name) else { return nil }
                return (dir.appendingPathComponent(name), idx)
            }
            .sorted { abs($0.index - aroundIndex) > abs($1.index - aroundIndex) }

        var bytes = meta.totalBytes
        for segment in segments where bytes > fileLimitBytes {
            let size = Int64((try? segment.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            try? fm.removeItem(at: segment.url)
            bytes -= size
        }
        metas[key]?.totalBytes = max(0, bytes)
    }

    /// 全库 LRU：超出总容量上限时按最近访问时间从最旧开始整文件淘汰
    private func evictIfNeeded() {
        var total = metas.values.reduce(into: 0) { $0 += $1.totalBytes }
        guard total > totalLimitBytes else { return }
        for (key, _) in metas.sorted(by: { $0.value.lastAccess < $1.value.lastAccess }) {
            guard total > totalLimitBytes else { break }
            let dir = directory(for: key)
            let size = directorySize(at: dir)
            try? FileManager.default.removeItem(at: dir)
            metas.removeValue(forKey: key)
            total -= size
        }
        saveIndex()
    }

    // MARK: - 索引持久化（重建成本低，仅加速淘汰决策）

    private var indexURL: URL {
        CacheManager.shared.url(for: .mediaSegments).appendingPathComponent("_index.json")
    }

    private func loadIndexIfNeeded() {
        guard !indexLoaded else { return }
        indexLoaded = true
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([String: FileMeta].self, from: data) else { return }
        metas = decoded
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(metas) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: - 路径

    private func directory(for key: String) -> URL {
        CacheManager.shared.url(for: .mediaSegments).appendingPathComponent(key, isDirectory: true)
    }

    private func segmentURL(key: String, index: Int64) -> URL {
        directory(for: key).appendingPathComponent(String(format: "seg_%08lld", index))
    }

    private static func segmentIndex(from name: String) -> Int64? {
        guard name.hasPrefix("seg_") else { return nil }
        return Int64(name.dropFirst(4))
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
