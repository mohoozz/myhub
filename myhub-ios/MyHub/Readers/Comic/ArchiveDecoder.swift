import Foundation
import UnrarKit

/// 漫画页数据源（IOS-207）：按需解出单页图片 Data，不整包解压落盘。
/// 实现：zip/cbz/epub 走 `RangeZipReader`（仅拉中央目录 + 目标条目，远程源零整包下载）；
/// rar/cbr 走 UnrarKit（本地直读；远程源先流式落地临时文件，加载阶段带进度）。
protocol ComicPageSource {
    /// 页名列表（自然序），下标即页码
    var pageNames: [String] { get }
    var pageCount: Int { get }
    /// 解出指定页图片数据
    func pageData(at index: Int) async throws -> Data
    /// 释放临时资源（远程 rar 临时文件）
    func close()
}

extension ComicPageSource {
    var pageCount: Int { pageNames.count }
    func close() {}
}

enum ArchiveDecodeError: Error, LocalizedError {
    case noPages
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .noPages: return "压缩包中没有图片页，可能不是漫画文件"
        case .unsupported(let ext): return "暂不支持 .\(ext) 漫画格式"
        }
    }
}

/// 漫画归档解码入口：按扩展名路由到对应数据源
enum ArchiveDecoder {

    /// 打开归档并列出页（自然排序）。
    /// - Parameters:
    ///   - connectionID: 连接源 ID（rar/cbr 远程源整包缓存复用的指纹组成部分，IOS-605）
    ///   - onDownloadProgress: 仅 rar/cbr 远程源落地临时文件时回报（0~1）
    static func open(
        entry: FileEntry,
        adapter: StorageAdapter,
        connectionID: Int64,
        knownPageNames: [String]? = nil,
        onDownloadProgress: ((Double) -> Void)? = nil
    ) async throws -> ComicPageSource {
        AppLogger.shared.log(
            "ArchiveDecoder.open: ext=\(entry.ext) size=\(entry.size) path=\(entry.path)",
            module: "comic-reader"
        )
        switch entry.ext {
        case "zip", "cbz":
            return try await openZipFamily(entry: entry, adapter: adapter)
        case "epub":
            return try await openEpub(entry: entry, adapter: adapter, knownPageNames: knownPageNames)
        case "rar", "cbr":
            return try await openRar(
                entry: entry, adapter: adapter, connectionID: connectionID,
                onDownloadProgress: onDownloadProgress
            )
        default:
            AppLogger.shared.log("不支持的漫画扩展名: \(entry.ext)", level: .warn, module: "comic-reader")
            throw ArchiveDecodeError.unsupported(entry.ext)
        }
    }

    // MARK: - zip / cbz（Range 解包，不整包下载）

    private static func openZipFamily(entry: FileEntry, adapter: StorageAdapter) async throws -> ComicPageSource {
        let reader = RangeZipReader(totalSize: entry.size) { range in
            let stream = try await adapter.readStream(entry.path, range: range)
            var data = Data()
            data.reserveCapacity(Int(range.upperBound - range.lowerBound))
            for try await chunk in stream {
                if Task.isCancelled { throw CancellationError() }
                data.append(chunk)
            }
            return data
        }
        let all = try await reader.entries()
        AppLogger.shared.log("zip/cbz 条目数=\(all.count) ext=\(entry.ext)", module: "comic-reader")
        // 内容嗅探兜底（识别策略 2）：cbz 扩展名直接放行；zip 需图片占比 ≥90% + 自然序列
        if !ComicDetector.isComicExtension(entry.ext),
           !ComicDetector.sniff(entryNames: all.map(\.name)) {
            AppLogger.shared.log(
                "zip 内容嗅探未通过（判定非漫画）: 条目数=\(all.count)",
                level: .warn, module: "comic-reader"
            )
            throw ArchiveDecodeError.noPages
        }
        let pages = all
            .filter { !$0.isDirectory && ComicDetector.isImageName($0.name) }
            .sorted { $0.name.naturalCompare($1.name) == .orderedAscending }
        AppLogger.shared.log("zip/cbz 图片页数=\(pages.count)", module: "comic-reader")
        guard !pages.isEmpty else {
            AppLogger.shared.log("zip/cbz 无图片页 → noPages", level: .warn, module: "comic-reader")
            throw ArchiveDecodeError.noPages
        }
        return ZipComicSource(reader: reader, pages: pages)
    }

    // MARK: - epub 漫画（按 spine 阅读顺序提取插图页）

    private static func openEpub(
        entry: FileEntry, adapter: StorageAdapter, knownPageNames: [String]? = nil
    ) async throws -> ComicPageSource {
        let t0 = CFAbsoluteTimeGetCurrent()
        let book = try await EpubBook(adapter: adapter, entry: entry)
        let t1 = CFAbsoluteTimeGetCurrent()
        let pageNames: [String]
        if let known = knownPageNames, !known.isEmpty {
            // 缓存秒开后复用已缓存页名，跳过遍历 194 个 spine XHTML（每次 2 次 Range 请求）
            pageNames = known
            AppLogger.shared.log(
                String(format: "epub 复用缓存页名=%d 元数据耗时=%.0fms(跳过页名遍历)", pageNames.count, (t1 - t0) * 1000),
                module: "comic-reader"
            )
        } else {
            pageNames = try await book.comicPageNames()
            let t2 = CFAbsoluteTimeGetCurrent()
            AppLogger.shared.log(
                String(format: "epub 图集页数=%d 解包总耗时=%.0fms(元数据=%.0fms+页名遍历=%.0fms)", pageNames.count, (t2 - t0) * 1000, (t1 - t0) * 1000, (t2 - t1) * 1000),
                module: "comic-reader"
            )
        }
        guard !pageNames.isEmpty else {
            AppLogger.shared.log("epub 无图集页 → noPages", level: .warn, module: "comic-reader")
            throw ArchiveDecodeError.noPages
        }
        return EpubComicSource(book: book, pageNames: pageNames)
    }

    // MARK: - rar / cbr（UnrarKit 需要文件 URL）

    private static func openRar(
        entry: FileEntry,
        adapter: StorageAdapter,
        connectionID: Int64,
        onDownloadProgress: ((Double) -> Void)?
    ) async throws -> ComicPageSource {
        if let local = adapter as? LocalAdapter, let url = local.localFileURL(for: entry.path) {
            AppLogger.shared.log("rar/cbr 本地打开: url=\(url.lastPathComponent)", module: "comic-reader")
            // 本地源：直接引用文件 URL，security-scoped 目录在每次操作时进入访问作用域
            return try await local.withLocalAccess {
                let archive = try URKArchive(url: url)
                let all = try archive.listFilenames()
                AppLogger.shared.log("rar/cbr 本地条目数=\(all.count) ext=\(entry.ext)", module: "comic-reader")
                // 内容嗅探兜底：cbr 直接放行；rar 需图片占比 ≥90% + 自然序列
                if !ComicDetector.isComicExtension(entry.ext), !ComicDetector.sniff(entryNames: all) {
                    AppLogger.shared.log(
                        "rar/cbr 本地内容嗅探未通过（判定非漫画）: 条目数=\(all.count)",
                        level: .warn, module: "comic-reader"
                    )
                    throw ArchiveDecodeError.noPages
                }
                let names = all.filter { ComicDetector.isImageName($0) }
                AppLogger.shared.log("rar/cbr 本地图片页数=\(names.count)", module: "comic-reader")
                guard !names.isEmpty else {
                    AppLogger.shared.log("rar/cbr 本地无图片页 → noPages", level: .warn, module: "comic-reader")
                    throw ArchiveDecodeError.noPages
                }
                return LocalRarComicSource(
                    archive: archive, pageNames: names.naturalSorted(), local: local
                )
            }
        }
        // 远程源：UnrarKit 不支持 Range，需流式落地文件。
        // IOS-605：内容缓存本地化开启时落漫画页缓存分区（指纹键），下次/离线打开直接复用；
        // 关闭时退回临时文件，退出即删。
        let caching = AppSettings.Cache.contentCachingEnabled
        let identity = SegmentCache.FileIdentity(
            connectionID: connectionID,
            path: entry.path,
            size: entry.size,
            modTime: entry.modTime.timeIntervalSince1970
        )
        let temp: URL
        let keepFile: Bool
        AppLogger.shared.log(
            "rar/cbr 远程打开: caching=\(caching) size=\(entry.size)",
            module: "comic-reader"
        )
        if caching {
            temp = await ComicPageCache.archiveURL(for: identity, ext: entry.ext)
            keepFile = true
            // 已缓存整包（大小一致）→ 跳过下载直接复用；损坏则删除并回退重新下载
            let cached = try? temp.resourceValues(forKeys: [.fileSizeKey])
            if let size = cached?.fileSize, Int64(size) == entry.size, entry.size > 0 {
                AppLogger.shared.log("rar/cbr 命中整包缓存，跳过下载", module: "comic-reader")
                if let source = try? openRarArchive(at: temp, entry: entry, tempURL: temp, keepFile: true) {
                    await ComicPageCache.noteArchiveWritten(for: identity)
                    return source
                }
                AppLogger.shared.log("rar/cbr 缓存整包损坏，删除后重新下载", level: .warn, module: "comic-reader")
                try? FileManager.default.removeItem(at: temp)
            }
        } else {
            temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("comic-\(UUID().uuidString).\(entry.ext)")
            keepFile = false
        }
        do {
            let stream = try await adapter.readStream(entry.path, range: nil)
            FileManager.default.createFile(atPath: temp.path, contents: nil)
            let handle = try FileHandle(forWritingTo: temp)
            var received: Int64 = 0
            do {
                for try await chunk in stream {
                    if Task.isCancelled { throw CancellationError() }
                    try handle.write(contentsOf: chunk)
                    received += Int64(chunk.count)
                    if entry.size > 0 {
                        onDownloadProgress?(min(Double(received) / Double(entry.size), 1))
                    }
                }
                try handle.close()
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: temp)
                throw error
            }
            AppLogger.shared.log("rar/cbr 下载完成: received=\(received)", module: "comic-reader")
            let source = try openRarArchive(at: temp, entry: entry, tempURL: temp, keepFile: keepFile)
            if keepFile { await ComicPageCache.noteArchiveWritten(for: identity) }
            return source
        } catch {
            AppLogger.shared.log(
                "rar/cbr 远程下载/解析失败: \(error.localizedDescription)",
                level: .warn, module: "comic-reader"
            )
            // 下载不完整/校验失败的文件不保留（缓存分区内同样删除，避免下次误命中）
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// 打开已落地的 rar/cbr 文件并校验漫画内容（嗅探 + 图片页列表）
    private static func openRarArchive(
        at url: URL, entry: FileEntry, tempURL: URL, keepFile: Bool
    ) throws -> ComicPageSource {
        let archive = try URKArchive(url: url)
        let all = try archive.listFilenames()
        AppLogger.shared.log("rar/cbr 条目数=\(all.count) ext=\(entry.ext)", module: "comic-reader")
        if !ComicDetector.isComicExtension(entry.ext), !ComicDetector.sniff(entryNames: all) {
            AppLogger.shared.log(
                "rar/cbr 内容嗅探未通过（判定非漫画）: 条目数=\(all.count)",
                level: .warn, module: "comic-reader"
            )
            throw ArchiveDecodeError.noPages
        }
        let names = all.filter { ComicDetector.isImageName($0) }
        AppLogger.shared.log("rar/cbr 图片页数=\(names.count)", module: "comic-reader")
        guard !names.isEmpty else {
            AppLogger.shared.log("rar/cbr 无图片页 → noPages", level: .warn, module: "comic-reader")
            throw ArchiveDecodeError.noPages
        }
        return TempRarComicSource(
            archive: archive, pageNames: names.naturalSorted(), tempURL: tempURL, keepFile: keepFile
        )
    }
}

// MARK: - zip / cbz 数据源

private final class ZipComicSource: ComicPageSource {
    let pages: [RangeZipReader.Entry]
    let pageNames: [String]
    private let reader: RangeZipReader

    init(reader: RangeZipReader, pages: [RangeZipReader.Entry]) {
        self.reader = reader
        self.pages = pages
        self.pageNames = pages.map(\.name)
    }

    func pageData(at index: Int) async throws -> Data {
        guard pages.indices.contains(index) else { throw ArchiveDecodeError.noPages }
        return try await reader.extract(pages[index])
    }
}

// MARK: - epub 漫画数据源

private final class EpubComicSource: ComicPageSource {
    let pageNames: [String]
    private let book: EpubBook

    init(book: EpubBook, pageNames: [String]) {
        self.book = book
        self.pageNames = pageNames
    }

    func pageData(at index: Int) async throws -> Data {
        guard pageNames.indices.contains(index) else { throw ArchiveDecodeError.noPages }
        guard let data = try await book.imageData(named: pageNames[index]) else {
            throw ArchiveDecodeError.noPages
        }
        return data
    }
}

// MARK: - rar / cbr 数据源

private final class LocalRarComicSource: ComicPageSource {
    let pageNames: [String]
    private let archive: URKArchive
    private let local: LocalAdapter

    init(archive: URKArchive, pageNames: [String], local: LocalAdapter) {
        self.archive = archive
        self.pageNames = pageNames
        self.local = local
    }

    func pageData(at index: Int) async throws -> Data {
        guard pageNames.indices.contains(index) else { throw ArchiveDecodeError.noPages }
        let name = pageNames[index]
        return try await local.withLocalAccess {
            try archive.extractData(fromFile: name)
        }
    }
}

private final class TempRarComicSource: ComicPageSource {
    let pageNames: [String]
    private let archive: URKArchive
    private let tempURL: URL
    /// true = 文件落漫画页缓存分区（IOS-605 复用，LRU 管理），退出不删除
    private let keepFile: Bool

    init(archive: URKArchive, pageNames: [String], tempURL: URL, keepFile: Bool = false) {
        self.archive = archive
        self.pageNames = pageNames
        self.tempURL = tempURL
        self.keepFile = keepFile
    }

    func pageData(at index: Int) async throws -> Data {
        guard pageNames.indices.contains(index) else { throw ArchiveDecodeError.noPages }
        return try archive.extractData(fromFile: pageNames[index])
    }

    func close() {
        if !keepFile {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }
}
