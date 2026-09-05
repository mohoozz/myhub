import Foundation
import UIKit
import AVFoundation
import CryptoKit
import GRDB
import UnrarKit
import MobileVLCKit

/// 封面结果：图片 + 可选媒体时长（视频抽帧时顺带探测，供时长角标）
struct CoverResult {
    var image: UIImage?
    var duration: Double?
}

/// 封面加载服务（IOS-102 / IOS-702）：
/// - 图片：流式读取 + ImageIO 下采样；视频：本地直读 / 远程经边下边播回环串流按需 Range 抽帧；
/// - 漫画：zip/cbz 经 RangeZipReader 仅拉中央目录与首页，rar/cbr 本地经 UnrarKit；
/// - 音频：同目录同名 / cover / folder / front 图片（复用浏览页已加载的兄弟列表，零额外请求）。
/// 内存 + 磁盘双缓存（Caches/Thumbnails），失败结果仅在会话内记忆；
/// 全部异步执行，UI 侧先展示占位——封面加载不阻塞点击进入播放/阅读。
actor CoverService {
    static let shared = CoverService()

    /// 单条封面读取的字节上限（防大图/异常文件撑爆内存）
    private let maxImageBytes: Int64 = 24 * 1024 * 1024
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

    /// 恒无封面（`CoverService` 视角）：目录、字幕、其它文件、txt 小说。
    /// epub 封面改由本服务 `produce` 轻量提取（`EpubBook.extractCover`），供浏览目录直接显示封面；
    /// txt 纯文本仍短路。原「epub 封面仅打开后经 cacheCoverThumbnail 写缩略图分区」不再承担目录封面。
    private static func hasNoCover(_ entry: FileEntry) -> Bool {
        if entry.isDir { return true }
        switch MediaType.detect(ext: entry.ext) {
        case .novel:
            // epub 有内嵌封面（目录层轻量提取）；txt 纯文本恒无封面
            return entry.ext == "txt"
        case .subtitle, .other:
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
        let mediaType = MediaType.detect(ext: entry.ext)
        do {
            switch mediaType {
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
                    if image != nil {
                        Self.logCover(.info, "audio 同目录封面命中: \(coverEntry.name) -> \(entry.name)", entry: entry)
                        return CoverResult(image: image, duration: nil)
                    }
                    Self.logCover(.warn, "audio 同目录封面图片解码失败: \(coverEntry.name) -> \(entry.name)", entry: entry)
                } else {
                    Self.logCover(.debug, "audio 同目录无同名/cover/folder/front 图片", entry: entry)
                }
                // 2. 音频内嵌封面（ID3 APIC / m4a covr / flac PICTURE）
                if let image = try await embeddedAudioCover(entry: entry, connection: connection, adapter: adapter) {
                    Self.logCover(.info, "audio 内嵌封面命中", entry: entry)
                    return CoverResult(image: image, duration: nil)
                }
                Self.logCover(.warn, "audio 封面缺失（同目录约定 + 内嵌均无）", entry: entry)
                return CoverResult(image: nil, duration: nil)
            case .comic:
                let image = try await comicCover(entry: entry, connection: connection, adapter: adapter)
                if image == nil {
                    Self.logCover(.warn, "comic 封面缺失", entry: entry)
                }
                return CoverResult(image: image, duration: nil)
            case .novel:
                // epub：轻量提取内嵌封面（封面缺失/解析失败则占位，由失败冷却限流重试）
                if entry.ext == "epub" {
                    let image = await EpubBook.extractCover(adapter: adapter, entry: entry)
                    if image == nil {
                        Self.logCover(.warn, "epub 封面缺失", entry: entry)
                    }
                    return CoverResult(image: image, duration: nil)
                }
                return CoverResult(image: nil, duration: nil)
            case .subtitle, .other:
                return CoverResult(image: nil, duration: nil)
            }
        } catch {
            Self.logCover(.warn, "封面加载异常 type=\(mediaType) error=\(String(describing: error))", entry: entry)
            return CoverResult(image: nil, duration: nil)   // 失败占位，不抛出
        }
    }

    /// 统一的封面日志出口：附带连接、扩展名、大小，便于按文件定位问题
    private static func logCover(
        _ level: AppLogger.Level, _ message: String, entry: FileEntry
    ) {
        AppLogger.shared.log(
            "\(message) | ext=\(entry.ext) size=\(entry.size) path=\(entry.path)",
            level: level, module: "cover"
        )
    }

    // MARK: - 视频：抽帧 + 时长

    private func videoCover(
        entry: FileEntry, connection: Connection, adapter: StorageAdapter
    ) async throws -> CoverResult {
        if let local = adapter as? LocalAdapter, let url = local.localFileURL(for: entry.path) {
            Self.logCover(.debug, "video 本地抽帧", entry: entry)
            do {
                let result = try await local.withLocalAccess {
                    try await Self.probeVideo(url: url)
                }
                return result
            } catch {
                Self.logCover(.warn, "video 本地抽帧失败 error=\(String(describing: error))", entry: entry)
                throw error
            }
        }
        // 远程：优先手动解析 mp4（只按需读 moov + 首帧关键帧，总量数百 KB~数 MB）。
        // moov 后置（非 faststart）时 VLC/AVFoundation 会发起「读整个文件」Range 请求（几 GB），
        // 在 NAS 上读不完必然超时，且几百个并发请求会把连接打爆（连读 1 字节都超时）。
        if let result = await manualMP4Cover(entry: entry, adapter: adapter) {
            return result
        }
        // 手动解析未命中（非 mp4 或解析失败）：回退边下边播回环串流 URL + VLC/AVFoundation 抽帧
        guard let url = try await PlaybackSourceResolver.makeRemoteStreamURL(connection: connection, entry: entry, enablePrefetch: false) else {
            Self.logCover(.warn, "video 远程无可用的串流源", entry: entry)
            throw StorageError.invalidPath(entry.path)
        }
        Self.logCover(.debug, "video 远程串流抽帧", entry: entry)
        defer {
            let bytes = LocalStreamProxy.shared.unregister(url)
            Self.logCover(.info, "video 远程串流抽帧 网络拉取=\(DisplayFormatters.size(bytes))", entry: entry)
        }
        do {
            return try await Self.probeRemoteVideo(url: url)
        } catch {
            Self.logCover(.warn, "video VLC 抽帧失败，回退 AVFoundation error=\(String(describing: error))", entry: entry)
            do {
                return try await Self.probeVideo(url: url)
            } catch {
                Self.logCover(.warn, "video 远程串流抽帧失败 error=\(String(describing: error))", entry: entry)
                throw error
            }
        }
    }

    /// 远程视频手动解析 mp4 取封面 + 时长：只按需读 moov（末尾）与首帧关键帧，
    /// 完全不读整个文件，规避 moov 后置时 VLC/AVFoundation 读整个文件打爆 NAS。
    /// 返回 nil 表示未命中（非 mp4 或解析失败），由调用方回退 VLC/AVFoundation。
    private func manualMP4Cover(entry: FileEntry, adapter: StorageAdapter) async -> CoverResult? {
        guard ["mp4", "m4v", "mov"].contains(entry.ext), entry.size > 0 else { return nil }
        do {
            var fetched: Int64 = 0
            let result = try await MP4CoverExtractor.extract(fileSize: entry.size) { range in
                let data = try await self.readAll(adapter: adapter, path: entry.path, range: range)
                fetched += Int64(data.count)
                return data
            }
            // 只有真的拿到封面（内嵌 covr 或首帧解码成功）才算命中。
            // image 为 nil 但 duration 有值（首帧手动解码失败）不能直接返回占位 ——
            // VLC 抽帧更健壮，能抽到 H.264/HEVC 首帧，应继续回退 VLC，否则这些视频永久变占位符。
            guard result.image != nil else {
                Self.logCover(.warn, "video 手动 mp4 解析无封面 duration=\(result.duration ?? 0)，回退 VLC 抽帧", entry: entry)
                return nil
            }
            Self.logCover(.info, "video 手动 mp4 解析命中 网络拉取=\(DisplayFormatters.size(fetched)) duration=\(result.duration ?? 0)", entry: entry)
            return CoverResult(image: result.image, duration: result.duration)
        } catch {
            Self.logCover(.warn, "video 手动 mp4 解析失败 error=\(String(describing: error))", entry: entry)
            return nil
        }
    }

    /// 抽首帧 + 读时长（本地 file:// 或回环串流 http://127.0.0.1 URL，均按需 Range 读取）
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

    /// 远程视频用 VLCKit（ffmpeg 内核）抽首帧 + 读时长。
    /// libavformat 对 moov 后置 mp4 会精确 seek 读末尾 moov + 首帧，规避 AVFoundation 读整个文件。
    private static func probeRemoteVideo(url: URL, timeout: TimeInterval = 8) async throws -> CoverResult {
        let media = VLCMedia(url: url)
        media.addOption(":avcodec-hw=videotoolbox")
        let holder = VLCCoverThumbnailHolder(media: media, timeout: timeout)
        let cgImage = try await holder.fetch()
        let duration: Double? = {
            guard let value = media.length.value?.doubleValue, value > 0 else { return nil }
            return value / 1000.0
        }()
        return CoverResult(image: UIImage(cgImage: cgImage), duration: duration)
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
            guard let first = try await reader.firstImageEntry() else {
                Self.logCover(.warn, "comic zip 未找到图片条目", entry: entry)
                return nil
            }
            do {
                let data = try await reader.extract(first)
                Task.detached(priority: .utility) {
                    await Self.cacheComicFirstPage(data, name: first.name, identity: cacheIdentity)
                }
                let image = await Task.detached { ImageDownsampler.downsample(data: data) }.value
                if image == nil {
                    Self.logCover(.warn, "comic zip 首页解码失败: \(first.name)", entry: entry)
                }
                return image
            } catch {
                Self.logCover(.warn, "comic zip 解压失败 error=\(String(describing: error))", entry: entry)
                throw error
            }
        case "rar", "cbr":
            // 本地源直接 UnrarKit；远程源整文件下载后解析（设上限，超大归档跳过）
            if let local = adapter as? LocalAdapter, let url = local.localFileURL(for: entry.path) {
                Self.logCover(.debug, "comic rar 本地解析", entry: entry)
                do {
                    return try await local.withLocalAccess {
                        try Self.unrarCover(url: url, identity: cacheIdentity)
                    }
                } catch {
                    Self.logCover(.warn, "comic rar 本地解析失败 error=\(String(describing: error))", entry: entry)
                    throw error
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
                Self.logCover(.warn, "comic rar 远程解析失败 error=\(String(describing: error))", entry: entry)
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
    /// 本地直接读 metadata；远程复用边下边播回环串流 URL，AVFoundation 按需读头部/moov 取 artwork。
    private func embeddedAudioCover(
        entry: FileEntry, connection: Connection, adapter: StorageAdapter
    ) async throws -> UIImage? {
        if let local = adapter as? LocalAdapter, let url = local.localFileURL(for: entry.path) {
            Self.logCover(.debug, "audio 内嵌封面本地读取", entry: entry)
            do {
                let image = try await local.withLocalAccess {
                    try await Self.audioArtwork(url: url)
                }
                if image == nil { Self.logCover(.debug, "audio 本地内嵌 artwork 为空", entry: entry) }
                return image
            } catch {
                Self.logCover(.warn, "audio 本地内嵌封面读取失败 error=\(String(describing: error))", entry: entry)
                throw error
            }
        }
        // 远程：复用边下边播回环串流 URL，AVFoundation 只按需读头部/moov 取 artwork
        // （ID3 APIC / flac PICTURE 在头部、m4a covr 在 moov），不再整文件下载。
        guard let url = try await PlaybackSourceResolver.makeRemoteStreamURL(connection: connection, entry: entry, enablePrefetch: false) else {
            Self.logCover(.debug, "audio 远程无可用的串流源", entry: entry)
            return nil
        }
        Self.logCover(.debug, "audio 远程串流读内嵌封面", entry: entry)
        defer {
            let bytes = LocalStreamProxy.shared.unregister(url)
            Self.logCover(.info, "audio 远程串流读封面 网络拉取=\(DisplayFormatters.size(bytes))", entry: entry)
        }
        do {
            let image = try await Self.audioArtwork(url: url)
            if image == nil { Self.logCover(.debug, "audio 远程内嵌 artwork 为空", entry: entry) }
            return image
        } catch {
            Self.logCover(.warn, "audio 远程串流读内嵌封面失败 error=\(String(describing: error))", entry: entry)
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

/// VLC 抽帧失败（超时等）
private enum VLCCoverError: Error {
    case timeout
}

/// VLCMediaThumbnailer 抽帧的一次性 async 桥接。
/// - `VLCMediaThumbnailer.delegate` 为 weak，这里让 holder 自身即 delegate，由调用方
///   `probeRemoteVideo` 的 async 帧持有 holder 直到完成，保证 delegate/thumbnailer 生命周期；
/// - 内部 `finished` 标记 + 兜底超时，防止 VLC 不回调或重复回调导致 continuation 悬挂/二次 resume。
private final class VLCCoverThumbnailHolder: NSObject, VLCMediaThumbnailerDelegate {
    private let timeout: TimeInterval
    private var thumbnailer: VLCMediaThumbnailer?
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var finished = false

    init(media: VLCMedia, timeout: TimeInterval) {
        self.timeout = timeout
        super.init()
        let thumbnailer = VLCMediaThumbnailer(media: media, andDelegate: self)
        thumbnailer.thumbnailWidth = 512
        thumbnailer.thumbnailHeight = 512
        thumbnailer.snapshotPosition = 0   // 首帧
        self.thumbnailer = thumbnailer
    }

    func fetch() async throws -> CGImage {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.thumbnailer?.fetchThumbnail()
            // 兜底超时：VLC 极端情况不回调时避免 async 永久挂起
            DispatchQueue.global().asyncAfter(deadline: .now() + self.timeout) { [weak self] in
                guard let self else { return }
                self.mediaThumbnailerDidTimeOut(self.thumbnailer!)
            }
        }
    }

    func mediaThumbnailerDidTimeOut(_ mediaThumbnailer: VLCMediaThumbnailer) {
        finish(.failure(VLCCoverError.timeout))
    }

    func mediaThumbnailer(_ mediaThumbnailer: VLCMediaThumbnailer, didFinishThumbnail thumbnail: CGImage) {
        finish(.success(thumbnail))
    }

    private func finish(_ result: Result<CGImage, Error>) {
        guard !finished else { return }
        finished = true
        continuation?.resume(with: result)
        continuation = nil
    }
}
