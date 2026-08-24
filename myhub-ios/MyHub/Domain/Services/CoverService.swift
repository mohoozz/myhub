import Foundation
import UIKit
import AVFoundation
import CryptoKit
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
    private let videoProbeBytes: Int64 = 8 * 1024 * 1024

    private final class Box {
        let result: CoverResult
        init(_ result: CoverResult) { self.result = result }
    }

    private let memory = NSCache<NSString, Box>()
    private var inflight: [String: Task<CoverResult, Never>] = [:]
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
        let key = cacheKey(for: entry, connection: connection)

        if let hit = memory.object(forKey: key as NSString) { return hit.result }
        if let disk = loadFromDisk(key: key) {
            memory.setObject(Box(disk), forKey: key as NSString)
            return disk
        }
        if let task = inflight[key] { return await task.value }

        let task = Task<CoverResult, Never> {
            await self.acquirePermit()
            let result = await self.produce(
                for: entry, connection: connection, adapter: adapter, siblings: siblings
            )
            self.releasePermit()
            self.memory.setObject(Box(result), forKey: key as NSString)
            if result.image != nil || result.duration != nil {
                self.saveToDisk(key: key, result: result)
            }
            return result
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        return result
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
                guard let coverEntry = Self.audioCoverEntry(in: siblings, for: entry) else {
                    return CoverResult(image: nil, duration: nil)
                }
                let data = try await readAll(adapter: adapter, path: coverEntry.path, limit: maxImageBytes)
                let image = await Task.detached { ImageDownsampler.downsample(data: data) }.value
                return CoverResult(image: image, duration: nil)
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
        // 远程：下载前缀到临时文件再抽帧（moov 前置格式可成；失败返回占位）
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cover-\(UUID().uuidString).\(entry.ext.isEmpty ? "bin" : entry.ext)")
        do {
            let data = try await readAll(
                adapter: adapter, path: entry.path,
                range: 0..<min(videoProbeBytes, max(entry.size, 1))
            )
            try data.write(to: temp)
            defer { try? FileManager.default.removeItem(at: temp) }
            return try await Self.probeVideo(url: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
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
        let (image, _, _) = try await generator.image(at: time)
        return CoverResult(image: UIImage(cgImage: image), duration: seconds)
    }

    // MARK: - 漫画：zip/cbz Range 解析；rar/cbr 本地 UnrarKit

    private func comicCover(
        entry: FileEntry, connection: Connection, adapter: StorageAdapter
    ) async throws -> UIImage? {
        switch entry.ext {
        case "zip", "cbz":
            let reader = RangeZipReader(totalSize: entry.size) { range in
                try await self.readAll(adapter: adapter, path: entry.path, range: range)
            }
            guard let first = try await reader.firstImageEntry() else { return nil }
            let data = try await reader.extract(first)
            return await Task.detached { ImageDownsampler.downsample(data: data) }.value
        case "rar", "cbr":
            // UnrarKit 需要文件 URL：仅本地源支持；远程源待 §4.2 数据源层落地后接入
            guard let local = adapter as? LocalAdapter, let url = local.localFileURL(for: entry.path) else {
                return nil
            }
            return try await local.withLocalAccess {
                let archive = try URKArchive(url: url)
                let names = try archive.listFilenames()
                    .filter { ["jpg", "jpeg", "png", "gif", "webp", "bmp"].contains(StoragePath.ext(of: $0)) }
                guard let first = names.naturalSorted().first,
                      let data = try archive.extractData(from: first) else { return nil }
                return ImageDownsampler.downsample(data: data)
            }
        default:
            return nil
        }
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
