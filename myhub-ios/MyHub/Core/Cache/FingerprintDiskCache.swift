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
        evictIfNeeded()
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
        evictIfNeeded()
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

    private func evictIfNeeded() {
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
        for unit in units.sorted(by: { $0.mtime < $1.mtime }) {
            guard total > limit else { break }
            let size = manager.size(of: unit.url)
            try? FileManager.default.removeItem(at: unit.url)
            total -= size
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
