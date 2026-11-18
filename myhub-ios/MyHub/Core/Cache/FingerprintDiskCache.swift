import Foundation

/// 按文件指纹组织的磁盘 LRU 缓存（IOS-605 内容缓存本地化）。
/// 目录布局：`<分区>/<fileKey>/<条目>` + `<分区>/<fileKey>/_identity.json`；
/// - fileKey 含文件指纹（size + modTime），文件被替换则键变、旧目录经 LRU 自然淘汰；
/// - `_identity.json` 记录 `SegmentCache.FileIdentity`，其 mtime 即最近访问时间（LRU 依据）；
/// - 供漫画解压页 / 小说章节等「需成组保留」的内容缓存使用；配额见 `CacheManager.limitBytes`。
actor FingerprintDiskCache {
    private let partition: CacheManager.Partition
    private let manager = CacheManager.shared

    init(partition: CacheManager.Partition) {
        self.partition = partition
    }

    // MARK: - 读写

    /// 读取条目（命中刷新目录访问时间；不存在/损坏返回 nil）
    func data(named name: String, for file: SegmentCache.FileIdentity) -> Data? {
        let url = entryURL(named: name, for: file)
        guard let data = try? Data(contentsOf: url) else { return nil }
        touchIdentity(for: file)
        return data
    }

    /// 写入条目（原子写 + 刷新访问时间 + 超配额整目录 LRU 淘汰）
    func store(named name: String, data: Data, for file: SegmentCache.FileIdentity) {
        let dir = directory(for: file)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: entryURL(named: name, for: file), options: .atomic)
        touchIdentity(for: file)
        evictIfNeeded(keeping: dir)
    }

    /// 条目 URL（供大文件直接读写，如远程 rar 整包）；调用方写入后应调用 `touch(_:)` 触发淘汰检查
    func url(named name: String, for file: SegmentCache.FileIdentity) -> URL {
        let dir = directory(for: file)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return entryURL(named: name, for: file)
    }

    /// 外部写入完成后的统一入口：刷新访问时间 + 淘汰检查
    func touch(_ file: SegmentCache.FileIdentity) {
        touchIdentity(for: file)
        evictIfNeeded(keeping: directory(for: file))
    }

    /// 移除某文件的全部缓存
    func remove(file: SegmentCache.FileIdentity) {
        try? FileManager.default.removeItem(at: directory(for: file))
    }

    // MARK: - 离线身份反查（已完整缓存内容无网络可用：指纹随身份一并取回）

    /// 按连接 + 路径反查最近访问的缓存身份（离线时 stat 失败的兜底入口）
    func identity(connectionID: Int64, path: String) -> SegmentCache.FileIdentity? {
        let dir = manager.url(for: partition)
        guard let subs = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
        ) else { return nil }
        var best: (identity: SegmentCache.FileIdentity, mtime: Date)?
        for sub in subs {
            let identityURL = sub.appendingPathComponent("_identity.json")
            guard let data = try? Data(contentsOf: identityURL),
                  let identity = try? JSONDecoder().decode(SegmentCache.FileIdentity.self, from: data),
                  identity.connectionID == connectionID, identity.path == path else { continue }
            let mtime = (try? identityURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if best == nil || mtime > best!.mtime {
                best = (identity, mtime)
            }
        }
        return best?.identity
    }

    // MARK: - LRU（目录粒度：页/章需成组保留，按 _identity.json 访问时间整目录淘汰）

    /// 淘汰检查节流：统计分区占用要遍历所有缓存文件（数千次 stat），原先每写一页/一章就做一次，
    /// 会让缓存读写这个 actor 长时间排队（缓存越大打开/翻页越慢）。改为最多 10s 检查一次。
    private var lastEvictCheck = Date.distantPast
    private static let evictCheckInterval: TimeInterval = 10
    /// 元数据条目不可裁（页名列表/宽高比/身份：丢了就得重新整包解析）
    private static let protectedNames: Set<String> = ["_identity.json", "pages.json", "ratios.json"]

    /// - Parameter active: 正在读写的目录（本次写入所属文件）；不整体删除，避免把
    ///   「刚缓存完正在读的这本」连页名列表一起清空 → 下次打开又走完整归档解析
    private func evictIfNeeded(keeping active: URL) {
        let now = Date()
        guard now.timeIntervalSince(lastEvictCheck) >= Self.evictCheckInterval else { return }
        lastEvictCheck = now

        let limit = manager.limitBytes(for: partition)
        let dir = manager.url(for: partition)
        guard let subs = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        var units: [(url: URL, mtime: Date)] = []
        var total: Int64 = 0
        for sub in subs {
            guard (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let identityURL = sub.appendingPathComponent("_identity.json")
            let mtime = (try? identityURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            units.append((sub, mtime))
            total += manager.size(of: sub)
        }
        guard total > limit else { return }
        // 1) 先淘汰其它文件（最久未访问优先），活跃目录不动
        for unit in units.sorted(by: { $0.mtime < $1.mtime })
        where unit.url.standardizedFileURL != active.standardizedFileURL {
            guard total > limit else { break }
            let size = manager.size(of: unit.url)
            try? FileManager.default.removeItem(at: unit.url)
            total -= size
        }
        // 2) 只有活跃目录、且它自身就超配额（单本漫画缓存 > 分区上限）：裁掉其中最旧的条目，
        //    保留元数据。否则整目录被删 = 页名列表丢失，下次打开必然重新解析归档（缓存形同失效）
        if total > limit {
            trimOldestEntries(in: active, total: total, limit: limit)
        }
    }

    /// 删除目录内最旧的普通条目（页/章），保留元数据
    private func trimOldestEntries(in dir: URL, total: Int64, limit: Int64) {
        var remaining = total
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }
        let candidates = files
            .filter { !Self.protectedNames.contains($0.lastPathComponent) }
            .compactMap { url -> (url: URL, size: Int64, mtime: Date)? in
                guard let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey]
                ), let size = values.fileSize else { return nil }
                return (url, Int64(size), values.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.mtime < $1.mtime }
        for file in candidates {
            guard remaining > limit else { break }
            try? FileManager.default.removeItem(at: file.url)
            remaining -= file.size
        }
    }

    // MARK: - 路径

    private func directory(for file: SegmentCache.FileIdentity) -> URL {
        manager.url(for: partition).appendingPathComponent(file.key, isDirectory: true)
    }

    private func entryURL(named name: String, for file: SegmentCache.FileIdentity) -> URL {
        directory(for: file).appendingPathComponent(name)
    }

    private func touchIdentity(for file: SegmentCache.FileIdentity) {
        let url = directory(for: file).appendingPathComponent("_identity.json")
        if FileManager.default.fileExists(atPath: url.path) {
            manager.touch(url)
        } else {
            try? FileManager.default.createDirectory(
                at: directory(for: file), withIntermediateDirectories: true
            )
            guard let data = try? JSONEncoder().encode(file) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

private extension CacheManager {
    /// 目录占用（供 FingerprintDiskCache 统计淘汰单元）
    func size(of directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
}
