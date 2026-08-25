import Foundation
import UIKit
import AVFoundation
import CryptoKit
import GRDB
import UnrarKit

/// 封面结果：图片 + 可选媒体时长（视频抽帧时顺带探测，供时长角标）
struct CoverResult {
    var image: UIImage?
    var duration: Double?
}

/// 封面加载服务（IOS-102 / IOS-702）：
/// - 图片：流式读取 + ImageIO 下采样；视频：本地直读 / 远程前缀下载后 AVAssetImageGenerator 抽首帧；
/// - 漫画：zip/cbz 经 RangeZipReader 仅拉中央目录与首页，rar/cbr 本地经 UnrarKit；
/// - 音频：同目录同名 / cover / folder / front 图片（复用浏览页已加载的兄弟列表，零额外请求）。
/// 内存 + 磁盘双缓存（Caches/Thumbnails），失败结果仅在会话内记忆；
/// 全部异步执行，UI 侧先展示占位——封面加载不阻塞点击进入播放/阅读。
actor CoverService {
    static let shared = CoverService()

    /// 单条封面读取的字节上限（防大图/异常文件撑爆内存）
    private let maxImageBytes: Int64 = 24 * 1024 * 1024
    /// 远程视频抽帧的前缀下载量（moov 前置的 mp4/mov 足够；失败则占位）
    private let videoProbeBytes: Int64 = 32 * 1024 * 1024
    /// 远程音频内嵌封面整文件下载上限（音频通常较小，内嵌封面位置不可预测）
    private let audioCoverMaxBytes: Int64 = 64 * 1024 * 1024
    /// 远程 rar/cbr 漫画封面整文件下载上限（UnrarKit 需本地文件）
    private let rarCoverMaxBytes: Int64 = 150 * 1024 * 1024

    private final class Box {
        let result: CoverResult
        init(_ result: CoverResult) { self.result = result }
    }

    private let memory = NSCache<NSString, Box>()
    private var inflight: [String: Task<CoverResult, Never>] = [:]
    /// 失败冷却（IOS-702）：加载失败的封面在冷却期内不重试，直接返回占位；
    /// 冷却期过后（滚动重新可见触发 .task）自动重试，避免弱网抖动导致「一次失败永久占位」。
    private var failedAt: [String: Date] = [:]
    /// 失败冷却时长（秒）：期间返回占位不重试；期满允许重新加载
    private let failureCooldown: TimeInterval = 30
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let maxConcurrent = 4

    private init() {
        memory.countLimit = 300
    }

    // MARK: - 入口

    /// 加载封面（去重 + 限并发 + 双缓存）。siblings 传当前目录条目（音频找同名封面用）。
    func cover(
        for entry: FileEntry,
        connection: Connection,
        adapter: StorageAdapter,
        siblings: [FileEntry] = []
    ) async -> CoverResult {
        // 恒无封面的类型提前短路：txt 小说 / 字幕 / 其它文件（epub 有内嵌封面，不短路）。
        // 省去缓存查找、并发许可与 actor 调度，浏览大目录时更省。
        if Self.hasNoCover(entry) { return CoverResult(image: nil, duration: nil) }

        let key = cacheKey(for: entry, connection: connection)

        if let hit = memory.object(forKey: key as NSString) { return hit.result }
        if let disk = loadFromDisk(key: key) {
            memory.setObject(Box(disk), forKey: key as NSString)
            return disk
        }
        // 失败冷却期内不重试，直接返回占位（期满则清除标记，走正常加载）
        if let failedTime = failedAt[key] {
            if Date().timeIntervalSince(failedTime) < failureCooldown {
                return CoverResult(image: nil, duration: nil)
            }
            failedAt[key] = nil
        }
        if let task = inflight[key] { return await task.value }

        let task = Task<CoverResult, Never> {
            await self.acquirePermit()
            let result = await self.produce(
                for: entry, connection: connection, adapter: adapter, siblings: siblings
            )
            self.releasePermit()
            if result.image != nil || result.duration != nil {
                // 成功：写内存 + 磁盘缓存，清除失败标记
                self.memory.setObject(Box(result), forKey: key as NSString)
                self.failedAt[key] = nil
                self.saveToDisk(key: key, result: result)
            } else {
                // 失败：不写内存（否则本会话永不重试），仅记冷却时间供限流
                self.failedAt[key] = Date()
                self.trimFailedIfNeeded()
            }
            return result
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        return result
    }

    /// 按播放条目取封面（音频播放页 / 锁屏共用）：
    /// 内部经 connectionID 解析连接与适配器，构造条目并复用 `cover(for:)` 全套内存/磁盘缓存与去重。
    /// 播放页与浏览页命中同一磁盘缓存键（连接 + 路径 + 指纹），避免重复网络拉取。
    func cover(forItem item: PlayableItem) async -> CoverResult {
        guard let connectionID = item.connectionID,
              let db = AppDatabase.shared.dbQueue,
              let connection = try? await db.read({ try Connection.fetchOne($0, id: connectionID) }),
              let adapter = try? AdapterFactory.makeAdapter(for: connection) else {
            return CoverResult(image: nil, duration: nil)
        }
        // 同目录兄弟条目（音频封面约定：同名 / cover / folder / front）
        let parent = StoragePath.parent(of: item.path)
        let siblings = (try? await adapter.list(parent)) ?? []
        // 指纹信息不便获取时，从兄弟列表回填自身条目（size/modTime 参与缓存键，命中浏览页缓存）
        let entry = siblings.first(where: { $0.path == item.path }) ?? FileEntry(
            name: (item.path as NSString).lastPathComponent,
            path: item.path,
            isDir: false,
            size: 0,
            modTime: Date(timeIntervalSince1970: 0),
            ext: StoragePath.ext(of: item.path)
        )
        return await cover(for: entry, connection: connection, adapter: adapter, siblings: siblings)
    }

    // MARK: - 并发许可

    private func acquirePermit() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func releasePermit() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// 失败冷却表容量控制：超过阈值时清除已过冷却期的条目（过期即可重试，无需保留）
    private func trimFailedIfNeeded() {
        guard failedAt.count > 500 else { return }
        let now = Date()
        failedAt = failedAt.filter { now.timeIntervalSince($0.value) < failureCooldown }
    }

    // MARK: - 缓存

    private func cacheKey(for entry: FileEntry, connection: Connection) -> String {
        let raw = "\(connection.id ?? 0)|\(entry.path)|\(entry.size)|\(entry.modTime.timeIntervalSince1970)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private struct DiskMeta: Codable {
        var duration: Double?
        var hasImage: Bool
    }

    private func diskURL(key: String, ext: String) -> URL {
        CacheManager.shared.url(for: .thumbnails).appendingPathComponent("\(key).\(ext)")
    }

    private func loadFromDisk(key: String) -> CoverResult? {
        let metaURL = diskURL(key: key, ext: "json")
        guard let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(DiskMeta.self, from: metaData) else { return nil }
        var image: UIImage?
        if meta.hasImage, let data = try? Data(contentsOf: diskURL(key: key, ext: "jpg")) {
            image = UIImage(data: data)
            CacheManager.shared.touch(diskURL(key: key, ext: "jpg"))   // 刷新访问时间（LRU）
        }
        CacheManager.shared.touch(metaURL)
        return CoverResult(image: image, duration: meta.duration)
    }

    private func saveToDisk(key: String, result: CoverResult) {
        let hasImage = result.image != nil
        if let data = result.image?.jpegData(compressionQuality: 0.8) {
            try? data.write(to: diskURL(key: key, ext: "jpg"), options: .atomic)
        }
        let meta = DiskMeta(duration: result.duration, hasImage: hasImage)
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: diskURL(key: key, ext: "json"), options: .atomic)
        }
        // IOS-605：封面分区超配额时按 LRU 淘汰（统一容量上限）
        CacheManager.shared.evictPartitionIfNeeded(.thumbnails)
    }

    // MARK: - 按类型产出

    /// 恒无封面（`CoverService` 视角）：目录、字幕、其它文件、小说。
    /// 注：epub 封面由 `EpubBook.cacheCoverThumbnail` 单独提取写入缩略图分区，
    /// 不经本服务的 `produce`（`.novel` 分支恒返回 nil），故 txt/epub 均可短路。
    private static func hasNoCover(_ entry: FileEntry) -> Bool {
        if entry.isDir { return true }
        switch MediaType.detect(ext: entry.ext) {
        case .novel, .subtitle, .other:
            return true
        case .video, .audio, .comic, .image:
            return false
        }
    }

    private func produce(
        for entry: FileEntry,
        connection: Connection,
        adapter: StorageAdapter,
        siblings: [FileEntry]
    ) async -> CoverResult {
        guard !entry.isDir else { return CoverResult(image: nil, duration: nil) }
        do {
            switch MediaType.detect(ext: entry.ext) {
            case .image:
                let data = try await readAll(adapter: adapter, path: entry.path, limit: maxImageBytes)
                let image = await Task.detached { ImageDownsampler.downsample(data: data) }.value
                return CoverResult(image: image, duration: nil)
            case .video:
                return try await videoCover(entry: entry, connection: connection, adapter: adapter)
            case .audio:
                // 1. 同目录图片约定（同名 / cover / folder / front）
                if let coverEntry = Self.audioCoverEntry(in: siblings, for: entry) {
                    let data = try await readAll(adapter: adapter, path: coverEntry.path, limit: maxImageBytes)
                    let image = await Task.detached { ImageDownsampler.downsample(data: data) }.value
                    if image != nil { return CoverResult(image: image, duration: nil) }
                }
                // 2. 音频内嵌封面（ID3 APIC / m4a covr / flac PICTURE）
                if let image = try await embeddedAudioCover(entry: entry, adapter: adapter) {
                    return CoverResult(image: image, duration: nil)
                }
                return CoverResult(image: nil, duration: nil)
            case .comic:
                let image = try await comicCover(entry: entry, connection: connection, adapter: adapter)
                return CoverResult(image: image, duration: nil)
            case .novel, .subtitle, .other:
                return CoverResult(image: nil, duration: nil)
            }
        } catch {
            return CoverResult(image: nil, duration: nil)   // 失败占位，不抛出
        }
    }

    // MARK: - 视频：抽帧 + 时长

    private func videoCover(
        entry: FileEntry, connection: Connection, adapter: StorageAdapter
    ) async throws -> CoverResult {
        if let local = adapter as? LocalAdapter, let url = local.localFileURL(for: entry.path) {
            return try await local.withLocalAccess {
                try await Self.probeVideo(url: url)
            }
        }
        // 远程：抽帧需 moov 前置格式的前缀。IOS-203 与边下边播共享分片缓存：
        // 播放已缓存前缀时零下载；未命中下载后写入分片缓存，播放时直接命中，互不重复。
        let identity = SegmentCache.FileIdentity(
            connectionID: connection.id ?? 0,
            path: entry.path,
            size: entry.size,
            modTime: entry.modTime.timeIntervalSince1970
        )
        let cachingEnabled = AppSettings.Cache.contentCachingEnabled
        let probeBytes = min(videoProbeBytes, max(entry.size, 1))
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cover-\(UUID().uuidString).\(entry.ext.isEmpty ? "bin" : entry.ext)")
        defer { try? FileManager.default.removeItem(at: temp) }

        // 1. 优先复用播放已缓存的前缀分片（抽帧成功即返回，前缀不足则回退下载）
        if cachingEnabled,
           let cached = await SegmentCache.shared.prefix(file: identity, maxBytes: probeBytes) {
            try? cached.write(to: temp)
            if let result = try? await Self.probeVideo(url: temp) { return result }
        }

        // 2. 下载前缀抽帧，并回填分片缓存供播放复用
        let data = try await readAll(adapter: adapter, path: entry.path, range: 0..<probeBytes)
        try data.write(to: temp)
        if cachingEnabled {
            await SegmentCache.shared.storePrefix(file: identity, data: data)
        }
        return try await Self.probeVideo(url: temp)
    }

    /// 抽首帧 + 读时长（本地/临时文件 URL）
    private static func probeVideo(url: URL) async throws -> CoverResult {
        let asset = AVAsset(url: url)
        let duration = try? await asset.load(.duration)
        let seconds: Double? = duration.flatMap {
            let value = $0.seconds
            return (value.isFinite && value > 0) ? value : nil
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        let (image, _) = try await generator.image(at: time)
        return CoverResult(image: UIImage(cgImage: image), duration: seconds)
    }

    // MARK: - 漫画：zip/cbz Range 解析；rar/cbr 本地 UnrarKit

    private func comicCover(
        entry: FileEntry, connection: Connection, adapter: StorageAdapter
    ) async throws -> UIImage? {
        // 首页原始解压数据顺带写入漫画页缓存（对齐阅读器键：entry 指纹 + 页名），
        // 阅读器打开时首页直接命中，免重复 Range 下载/解压（隐患5）。
        let cacheIdentity = SegmentCache.FileIdentity(
            connectionID: connection.id ?? 0,
            path: entry.path,
            size: entry.size,
            modTime: entry.modTime.timeIntervalSince1970
        )
        switch entry.ext {
        case "zip", "cbz":
            let reader = RangeZipReader(totalSize: entry.size) { range in
                try await self.readAll(adapter: adapter, path: entry.path, range: range)
            }
            guard let first = try await reader.firstImageEntry() else { return nil }
            let data = try await reader.extract(first)
            Task.detached(priority: .utility) {
                await Self.cacheComicFirstPage(data, name: first.name, identity: cacheIdentity)
            }
            return await Task.detached { ImageDownsampler.downsample(data: data) }.value
        case "rar", "cbr":
            // 本地源直接 UnrarKit；远程源整文件下载后解析（设上限，超大归档跳过）
            if let local = adapter as? LocalAdapter, let url = local.localFileURL(for: entry.path) {
                return try await local.withLocalAccess {
                    try Self.unrarCover(url: url, identity: cacheIdentity)
                }
            }
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("comic-cover-\(UUID().uuidString).\(entry.ext)")
            do {
                let data = try await readAll(adapter: adapter, path: entry.path, limit: rarCoverMaxBytes)
                try data.write(to: temp)
                defer { try? FileManager.default.removeItem(at: temp) }
                return try Self.unrarCover(url: temp, identity: cacheIdentity)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                return nil
            }
        default:
            return nil
        }
    }

    /// rar/cbr 抽取首个图片条目（本地/临时文件 URL 通用），首页原始数据顺带写页缓存
    private static func unrarCover(url: URL, identity: SegmentCache.FileIdentity) throws -> UIImage? {
        let archive = try URKArchive(url: url)
        let names = try archive.listFilenames()
            .filter { ["jpg", "jpeg", "png", "gif", "webp", "bmp"].contains(StoragePath.ext(of: $0)) }
        guard let first = names.naturalSorted().first else { return nil }
        let data = try archive.extractData(fromFile: first)
        Task.detached(priority: .utility) {
            await CoverService.cacheComicFirstPage(data, name: first, identity: identity)
        }
        return ImageDownsampler.downsample(data: data)
    }

    /// 首页原始解压数据写入漫画页缓存（与阅读器同键，打开首页直接命中；受内容缓存开关约束）
    fileprivate static func cacheComicFirstPage(
        _ data: Data, name: String, identity: SegmentCache.FileIdentity
    ) async {
        await ComicPageCache.storePage(data, file: identity, name: name)
    }

    // MARK: - 音频：同目录封面约定

    /// 同目录同名图片 / cover / folder / front（大小写不敏感）
    static func audioCoverEntry(in siblings: [FileEntry], for audio: FileEntry) -> FileEntry? {
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp"]
        let base = (audio.name as NSString).deletingPathExtension.lowercased()
        var fallback: FileEntry?
        for sibling in siblings where !sibling.isDir && imageExts.contains(sibling.ext) {
            let stem = (sibling.name as NSString).deletingPathExtension.lowercased()
            if stem == base { return sibling }   // 同名优先
            if fallback == nil, ["cover", "folder", "front"].contains(stem) { fallback = sibling }
        }
        return fallback
    }

    // MARK: - 音频：内嵌封面

    /// 音频内嵌封面（ID3 APIC / m4a covr / flac PICTURE）。
    /// 本地直接读 metadata；远程整文件下载（限上限，内嵌封面位置不可预测）。
    private func embeddedAudioCover(entry: FileEntry, adapter: StorageAdapter) async throws -> UIImage? {
        if let local = adapter as? LocalAdapter, let url = local.localFileURL(for: entry.path) {
            return try await local.withLocalAccess {
                try await Self.audioArtwork(url: url)
            }
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-cover-\(UUID().uuidString).\(entry.ext.isEmpty ? "bin" : entry.ext)")
        do {
            let data = try await readAll(adapter: adapter, path: entry.path, limit: audioCoverMaxBytes)
            try data.write(to: temp)
            defer { try? FileManager.default.removeItem(at: temp) }
            return try await Self.audioArtwork(url: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return nil
        }
    }

    /// 读取音频文件的 artwork 内嵌封面（AVFoundation 支持 mp3/m4a/aac/flac/wav 等）
    private static func audioArtwork(url: URL) async throws -> UIImage? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
        for element in metadata where element.commonKey == AVMetadataKey.commonKeyArtwork {
            if let data = try? await element.load(.dataValue), let image = UIImage(data: data) {
                return image
            }
        }
        return nil
    }

    // MARK: - 流收集

    /// 收集适配器流到 Data（可选 Range，带字节上限防失控）
    private func readAll(
        adapter: StorageAdapter, path: String, range: Range<Int64>? = nil, limit: Int64? = nil
    ) async throws -> Data {
        let stream = try await adapter.readStream(path, range: range)
        var data = Data()
        let cap = limit ?? (range.map { $0.upperBound - $0.lowerBound }) ?? maxImageBytes
        for try await chunk in stream {
            if Task.isCancelled { throw CancellationError() }
            data.append(chunk)
            if Int64(data.count) > cap { throw StorageError.invalidPath("封面读取超过上限") }
        }
        return data
    }
}
