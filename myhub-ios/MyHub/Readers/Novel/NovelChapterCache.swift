import Foundation

/// epub 元数据缓存快照（Codable）：离线打开时重建 `EpubBook` 的结构基础
struct CachedEpubMeta: Codable {
    var title: String
    var spine: [EpubBook.ManifestItem]
    var toc: [EpubBook.TocItem]
    var coverImageName: String?
    var isComicLike: Bool
}

/// 小说章节磁盘缓存（IOS-605 内容缓存本地化 / TODO §11）：
/// - txt：按章缓存解码产物（原始字节 + 行字节范围表），键 = 文件指纹 + 章下标；
/// - epub：按 spine 缓存内容块（文本段 + 插图数据）+ 元数据快照 → **已缓存章节支持离线阅读**；
/// - 指纹与索引/进度同源（txt 用章节索引的 fileSize/modTime，epub 用打开时 entry 指纹），文件替换键即失效；
/// - 目录粒度 LRU + 分区配额（`CacheManager.limitBytes(for: .novelChapters)`），受「内容缓存本地化」开关约束。
enum NovelChapterCache {
    private static let store = FingerprintDiskCache(partition: .novelChapters)

    static var enabled: Bool { AppSettings.Cache.contentCachingEnabled }

    /// 离线身份反查（打开失败后兜底；指纹随身份取回，供元数据/章节缓存键与进度校验共用）
    static func identity(connectionID: Int64, path: String) async -> SegmentCache.FileIdentity? {
        await store.identity(connectionID: connectionID, path: path)
    }

    // MARK: - txt 章节

    private struct CachedChapterText: Codable {
        struct CachedLine: Codable {
            var text: String
            var start: Int64
            var end: Int64
        }
        var encodingRaw: UInt
        var baseOffset: Int64
        var rawData: Data
        var lines: [CachedLine]
    }

    static func chapterText(
        file: SegmentCache.FileIdentity, chapter: Int
    ) async -> TxtChapterLoader.ChapterText? {
        guard enabled, let data = await store.data(named: "ch_\(chapter).json", for: file),
              let cached = try? JSONDecoder().decode(CachedChapterText.self, from: data) else { return nil }
        return TxtChapterLoader.ChapterText(
            encoding: String.Encoding(rawValue: cached.encodingRaw),
            rawData: cached.rawData,
            baseOffset: cached.baseOffset,
            lines: cached.lines.map { .init(text: $0.text, byteRange: $0.start..<$0.end) }
        )
    }

    static func storeChapterText(
        _ chapterText: TxtChapterLoader.ChapterText,
        file: SegmentCache.FileIdentity, chapter: Int
    ) async {
        guard enabled else { return }
        let cached = CachedChapterText(
            encodingRaw: chapterText.encoding.rawValue,
            baseOffset: chapterText.baseOffset,
            rawData: chapterText.rawData,
            lines: chapterText.lines.map {
                .init(text: $0.text, start: $0.byteRange.lowerBound, end: $0.byteRange.upperBound)
            }
        )
        guard let data = try? JSONEncoder().encode(cached) else { return }
        await store.store(named: "ch_\(chapter).json", data: data, for: file)
    }

    // MARK: - epub 章节内容块

    private struct CachedBlock: Codable {
        var text: String?
        var heading: Int?
        var imageName: String?
        var imageData: Data?
    }

    static func blocks(file: SegmentCache.FileIdentity, spine: Int) async -> [ReaderBlock]? {
        guard enabled, let data = await store.data(named: "sp_\(spine).json", for: file),
              let cached = try? JSONDecoder().decode([CachedBlock].self, from: data) else { return nil }
        return cached.compactMap { block in
            if let text = block.text { return .text(text, heading: block.heading ?? 0) }
            if let name = block.imageName { return .image(name: name, data: block.imageData) }
            return nil
        }
    }

    static func storeBlocks(
        _ blocks: [ReaderBlock], file: SegmentCache.FileIdentity, spine: Int
    ) async {
        guard enabled else { return }
        // 插图加载失败（data=nil）的章不缓存，留待下次重试
        let cacheable = blocks.allSatisfy { block in
            if case .image(_, let data) = block { return data != nil }
            return true
        }
        guard cacheable else { return }
        let cached = blocks.map { block -> CachedBlock in
            switch block {
            case .text(let text, let heading):
                return CachedBlock(text: text, heading: heading)
            case .image(let name, let data):
                return CachedBlock(imageName: name, imageData: data)
            }
        }
        guard let data = try? JSONEncoder().encode(cached) else { return }
        await store.store(named: "sp_\(spine).json", data: data, for: file)
    }

    // MARK: - epub 元数据（离线打开重建用）

    static func meta(file: SegmentCache.FileIdentity) async -> CachedEpubMeta? {
        guard let data = await store.data(named: "meta.json", for: file) else { return nil }
        return try? JSONDecoder().decode(CachedEpubMeta.self, from: data)
    }

    static func storeMeta(_ meta: CachedEpubMeta, file: SegmentCache.FileIdentity) async {
        guard enabled, let data = try? JSONEncoder().encode(meta) else { return }
        await store.store(named: "meta.json", data: data, for: file)
    }
}
