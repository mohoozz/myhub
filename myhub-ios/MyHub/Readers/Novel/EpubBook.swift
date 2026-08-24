import CryptoKit
import Foundation
import UIKit

/// epub 书籍（IOS-206）：epub 即 zip，经 `RangeZipReader` 按需 Range 解包（网络源不整包下载）。
/// - 解析 container.xml → OPF（manifest / spine / metadata）→ NCX 或 NAV 目录；
/// - 章节 XHTML 按需解析为「段落流」（排版无关锚点：spine 序号 + 段落序号 + 段内字符偏移）；
/// - **图集型（漫画）判断**：spine 正文图片占比高且文本稀少 → 提示/一键转漫画阅读器；
/// - 封面提取（manifest cover-image / meta cover），供「正在阅读」封面。
final class EpubBook {

    struct ManifestItem: Codable {
        let id: String
        let name: String          // 归一化 zip 条目名（绝对、小写）
        let mediaType: String
    }

    struct TocItem: Codable {
        let title: String
        let spineIndex: Int
    }

    enum BookError: Error, LocalizedError {
        case missingContainer
        case missingOPF
        case emptySpine
        /// 离线模式：章节内容未缓存（IOS-605）
        case offlineUncached

        var errorDescription: String? {
            switch self {
            case .missingContainer: return "epub 缺少 container.xml"
            case .missingOPF: return "epub 缺少 OPF 描述文件"
            case .emptySpine: return "epub 没有可阅读的章节"
            case .offlineUncached: return "离线模式：该章节未缓存"
            }
        }
    }

    let title: String
    let spine: [ManifestItem]          // 阅读顺序的 XHTML 项
    let toc: [TocItem]
    let coverImageName: String?        // zip 内封面图条目名
    /// 图集型（漫画）判定结果
    let isComicLike: Bool

    /// 在线模式为 zip 读取器；离线模式（元数据缓存构造）为 nil，内容全部走章节磁盘缓存
    private let zip: RangeZipReader?
    private let entryMap: [String: RangeZipReader.Entry]   // 归一化名 → 条目
    private let imageDataCache = NSCache<NSString, NSData>()

    // MARK: - 解包

    init(adapter: StorageAdapter, entry: FileEntry) async throws {
        let zip = RangeZipReader(totalSize: entry.size) { range in
            let stream = try await adapter.readStream(entry.path, range: range)
            var data = Data()
            for try await chunk in stream {
                data.append(chunk)
                try Task.checkCancellation()
            }
            return data
        }
        self.zip = zip

        let entries = try await zip.entries()
        var map: [String: RangeZipReader.Entry] = [:]
        for item in entries where !item.isDirectory {
            map[Self.normalizeName(item.name)] = item
        }
        self.entryMap = map

        // container.xml → OPF 路径
        guard let containerEntry = map["meta-inf/container.xml"] else { throw BookError.missingContainer }
        let containerXML = try await zip.extract(containerEntry)
        guard let opfPath = Self.parseContainer(containerXML) else { throw BookError.missingOPF }
        let opfName = Self.normalizeName(opfPath)
        guard let opfEntry = map[opfName] else { throw BookError.missingOPF }

        // OPF → manifest / spine / 标题 / 封面
        let opfData = try await zip.extract(opfEntry)
        let baseDir = Self.directory(of: opfName)
        let raw = Self.parseOPF(opfData)
        let spine: [ManifestItem] = raw.spineIds.compactMap { id in
            guard let item = raw.manifest[id] else { return nil }
            return ManifestItem(
                id: id,
                name: Self.absolutePath(base: baseDir, href: item.href),
                mediaType: item.mediaType
            )
        }
        guard !spine.isEmpty else { throw BookError.emptySpine }
        self.title = raw.title ?? (StoragePath.fileName(of: entry.name) as NSString).deletingPathExtension
        self.spine = spine
        self.coverImageName = raw.coverHref.map { Self.absolutePath(base: baseDir, href: $0) }

        // 目录：NAV（EPUB3）优先，其次 NCX（EPUB2），兜底 spine 直出
        let navItem = raw.navHref.map { Self.absolutePath(base: baseDir, href: $0) }
        let ncxItem = raw.ncxHref.map { Self.absolutePath(base: baseDir, href: $0) }
        if let navName = navItem, let navEntry = map[navName],
           let navData = try? await zip.extract(navEntry),
           let items = Self.parseNAV(navData, spine: spine), !items.isEmpty {
            self.toc = items
        } else if let ncxName = ncxItem, let ncxEntry = map[ncxName],
                  let ncxData = try? await zip.extract(ncxEntry),
                  let items = Self.parseNCX(ncxData, spine: spine), !items.isEmpty {
            self.toc = items
        } else {
            self.toc = spine.enumerated().map { index, item in
                let file = (item.name as NSString).lastPathComponent
                let stem = (file as NSString).deletingPathExtension
                return TocItem(title: stem.isEmpty ? "第 \(index + 1) 节" : stem, spineIndex: index)
            }
        }

        // 图集型判断：抽样 spine 前 5 个 XHTML —— 文本稀少且均含插图 → 漫画
        var comicPages = 0
        var sampled = 0
        for item in spine.prefix(5) {
            guard let zipEntry = map[item.name],
                  let data = try? await zip.extract(zipEntry) else { continue }
            let stats = EpubHTMLParser.statistics(data: data)
            sampled += 1
            if stats.imageCount >= 1 && stats.textLength < 120 {
                comicPages += 1
            }
        }
        self.isComicLike = sampled > 0 && Double(comicPages) / Double(sampled) >= 0.8
    }

    /// 离线构造（IOS-605）：元数据来自磁盘缓存，内容经章节磁盘缓存读取（zip 为 nil）
    init(offline meta: CachedEpubMeta) {
        self.title = meta.title
        self.spine = meta.spine
        self.toc = meta.toc
        self.coverImageName = meta.coverImageName
        self.isComicLike = meta.isComicLike
        self.zip = nil
        self.entryMap = [:]
    }

    /// 元数据快照（在线解包成功后落盘，供离线打开重建）
    var cacheMeta: CachedEpubMeta {
        CachedEpubMeta(
            title: title, spine: spine, toc: toc,
            coverImageName: coverImageName, isComicLike: isComicLike
        )
    }

    // MARK: - 章节内容（按需解析为段落流）

    /// 解析 spine 章为内容块（文本段 + 插图），插图数据一并预取
    func blocks(forSpine index: Int) async throws -> [ReaderBlock] {
        guard let zip else { throw BookError.offlineUncached }
        guard spine.indices.contains(index) else { return [] }
        let item = spine[index]
        guard let zipEntry = entryMap[item.name] else { return [] }
        let data = try await zip.extract(zipEntry)
        var blocks = EpubHTMLParser.parse(data: data, baseDir: Self.directory(of: item.name))
        for blockIndex in blocks.indices {
            if case .image(let href, _) = blocks[blockIndex] {
                let image = try? await imageData(named: href)
                blocks[blockIndex] = .image(name: href, data: image)
            }
        }
        return blocks
    }

    /// 漫画阅读器用：按 spine 阅读顺序返回所有插图条目名（仅解析 XHTML 内 <img>，不加载图片数据）
    func comicPageNames() async throws -> [String] {
        guard let zip else { throw BookError.offlineUncached }
        var names: [String] = []
        for item in spine {
            guard let zipEntry = entryMap[item.name],
                  let data = try? await zip.extract(zipEntry) else { continue }
            let blocks = EpubHTMLParser.parse(data: data, baseDir: Self.directory(of: item.name))
            for block in blocks {
                if case .image(let name, _) = block {
                    names.append(name)
                }
            }
        }
        return names
    }

    /// zip 内图片数据（内存缓存）
    func imageData(named name: String) async throws -> Data? {
        guard let zip else { return nil }
        let key = Self.normalizeName(name)
        if let cached = imageDataCache.object(forKey: key as NSString) {
            return cached as Data
        }
        guard let entry = entryMap[key] else { return nil }
        let data = try await zip.extract(entry)
        imageDataCache.setObject(data as NSData, forKey: key as NSString)
        return data
    }

    /// 封面提取后写缩略图缓存，返回缓存文件名（供 ReadingProgress.cover）
    func cacheCoverThumbnail(connectionID: Int64, path: String) async -> String? {
        guard let coverImageName,
              let data = try? await imageData(named: coverImageName),
              let image = await Task.detached(operation: {
                  ImageDownsampler.downsample(data: data)
              }).value,
              let jpeg = image.jpegData(compressionQuality: 0.8) else { return nil }
        // 稳定键（SHA256，跨启动一致；path.hashValue 每次启动随机化，不可用）
        let digest = SHA256.hash(data: Data("epub-cover|\(connectionID)|\(path)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let key = "epub-\(digest).jpg"
        let url = CacheManager.shared.url(for: .thumbnails).appendingPathComponent(key)
        try? jpeg.write(to: url, options: .atomic)
        CacheManager.shared.evictPartitionIfNeeded(.thumbnails)
        return key
    }

    // MARK: - 路径工具

    static func normalizeName(_ name: String) -> String {
        var path = name.replacingOccurrences(of: "\\", with: "/")
        if path.hasPrefix("/") { path.removeFirst() }
        var parts: [String] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(part))
            }
        }
        return parts.joined(separator: "/").lowercased()
    }

    static func absolutePath(base: String, href: String) -> String {
        let cleaned = href.removingPercentEncoding ?? href
        if cleaned.hasPrefix("/") { return normalizeName(cleaned) }
        return normalizeName(base.isEmpty ? cleaned : base + "/" + cleaned)
    }

    static func directory(of path: String) -> String {
        guard let index = path.lastIndex(of: "/") else { return "" }
        return String(path[..<index])
    }

    // MARK: - container.xml / OPF / NCX / NAV 解析

    private static func parseContainer(_ data: Data) -> String? {
        let delegate = ContainerParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.rootfilePath
    }

    private struct RawOPF {
        var title: String?
        var manifest: [String: (href: String, mediaType: String)]
        var spineIds: [String]
        var navHref: String?
        var ncxHref: String?
        var coverHref: String?
    }

    private static func parseOPF(_ data: Data) -> RawOPF {
        let delegate = OPFParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return RawOPF(
            title: delegate.title,
            manifest: delegate.manifest,
            spineIds: delegate.spineIds,
            navHref: delegate.navHref,
            ncxHref: delegate.ncxHref,
            coverHref: delegate.coverHref
        )
    }

    private static func parseNCX(_ data: Data, spine: [ManifestItem]) -> [TocItem]? {
        let delegate = NCXParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        var items: [TocItem] = []
        for point in delegate.points {
            let src = point.src.split(separator: "#").first.map(String.init) ?? point.src
            let normalized = normalizeName(src)
            if let index = spine.firstIndex(where: {
                $0.name == normalized || $0.name.hasSuffix(normalized)
            }) {
                items.append(TocItem(title: point.title, spineIndex: index))
            }
        }
        return items.isEmpty ? nil : deduplicated(items)
    }

    private static func parseNAV(_ data: Data, spine: [ManifestItem]) -> [TocItem]? {
        let delegate = NAVParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        var items: [TocItem] = []
        for link in delegate.links {
            let src = link.href.split(separator: "#").first.map(String.init) ?? link.href
            let normalized = normalizeName(src)
            if let index = spine.firstIndex(where: {
                $0.name == normalized || $0.name.hasSuffix(normalized)
            }) {
                items.append(TocItem(title: link.title, spineIndex: index))
            }
        }
        return items.isEmpty ? nil : deduplicated(items)
    }

    private static func deduplicated(_ items: [TocItem]) -> [TocItem] {
        var seen: Set<Int> = []
        var result: [TocItem] = []
        for item in items where !seen.contains(item.spineIndex) {
            seen.insert(item.spineIndex)
            result.append(item)
        }
        return result.sorted { $0.spineIndex < $1.spineIndex }
    }
}

// MARK: - XML 委托解析

private final class ContainerParser: NSObject, XMLParserDelegate {
    var rootfilePath: String?

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName.hasSuffix("rootfile"), rootfilePath == nil {
            rootfilePath = attributeDict["full-path"]
        }
    }
}

private final class OPFParser: NSObject, XMLParserDelegate {
    var title: String?
    var manifest: [String: (href: String, mediaType: String)] = [:]
    var spineIds: [String] = []
    var navHref: String?
    var ncxHref: String?
    var coverHref: String?
    private var coverId: String?
    private var inTitle = false
    private var titleText = ""

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let tag = elementName.components(separatedBy: ":").last ?? elementName
        switch tag {
        case "title":
            inTitle = true
            titleText = ""
        case "item":
            if let id = attributeDict["id"], let href = attributeDict["href"] {
                manifest[id] = (href, attributeDict["media-type"] ?? "")
                let properties = attributeDict["properties"] ?? ""
                if properties.contains("nav") { navHref = href }
                if properties.contains("cover-image") { coverHref = href }
            }
        case "itemref":
            if let idref = attributeDict["idref"] {
                spineIds.append(idref)
            }
        case "meta":
            if attributeDict["name"] == "cover", let content = attributeDict["content"] {
                coverId = content
            }
        case "spine":
            if let toc = attributeDict["toc"], let item = manifest[toc] {
                ncxHref = item.href
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTitle { titleText += string }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName: String?
    ) {
        let tag = elementName.components(separatedBy: ":").last ?? elementName
        switch tag {
        case "title":
            inTitle = false
            let trimmed = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { title = trimmed }
        case "package":
            // meta name="cover" 的 content 指向 manifest item id
            if coverHref == nil, let coverId, let item = manifest[coverId] {
                coverHref = item.href
            }
        default:
            break
        }
    }
}

private final class NCXParser: NSObject, XMLParserDelegate {
    struct NavPoint { let title: String; let src: String }
    var points: [NavPoint] = []
    private var inLabel = false
    private var labelText = ""
    private var pendingSrc: String?

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "navPoint":
            pendingSrc = nil
            labelText = ""
        case "content":
            if pendingSrc == nil { pendingSrc = attributeDict["src"] }
        case "text":
            inLabel = true
            labelText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inLabel { labelText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "text":
            inLabel = false
        case "navPoint":
            let title = labelText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let src = pendingSrc, !title.isEmpty {
                points.append(NavPoint(title: title, src: src))
            }
        default:
            break
        }
    }
}

private final class NAVParser: NSObject, XMLParserDelegate {
    struct Link { let title: String; let href: String }
    var links: [Link] = []
    private var inAnchor = false
    private var anchorText = ""
    private var pendingHref: String?

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "a", let href = attributeDict["href"] {
            inAnchor = true
            pendingHref = href
            anchorText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inAnchor { anchorText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "a", inAnchor {
            inAnchor = false
            let title = anchorText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let href = pendingHref, !title.isEmpty {
                links.append(Link(title: title, href: href))
            }
        }
    }
}

// MARK: - 章节 XHTML → 段落流（排版无关锚点的结构基础）

enum EpubHTMLParser {
    /// 统计：正文文本长度与插图数（图集型判断）
    static func statistics(data: Data) -> (textLength: Int, imageCount: Int) {
        let delegate = ContentParser(baseDir: "")
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return (delegate.totalTextLength, delegate.imageCount)
    }

    /// 解析为内容块；插图 href 归一化为 zip 条目名（baseDir = 该 XHTML 所在目录）
    static func parse(data: Data, baseDir: String) -> [ReaderBlock] {
        let delegate = ContentParser(baseDir: baseDir)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.blocks
    }

    private final class ContentParser: NSObject, XMLParserDelegate {
        private(set) var blocks: [ReaderBlock] = []
        private(set) var totalTextLength = 0
        private(set) var imageCount = 0

        private let baseDir: String
        private var buffer = ""
        private var currentHeading = 0
        private var skipDepth = 0   // script/style 忽略深度

        init(baseDir: String) {
            self.baseDir = baseDir
        }

        private static let blockTags: Set<String> = [
            "p", "div", "li", "blockquote", "section", "article", "tr"
        ]
        private static let headingTags: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let tag = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName
            switch tag {
            case "script", "style":
                skipDepth += 1
            case _ where Self.headingTags.contains(tag):
                flush()
                currentHeading = min(Int(tag.dropFirst()) ?? 1, 3)
            case "img", "image":
                flush()
                let src = attributeDict["src"]
                    ?? attributeDict["xlink:href"]
                    ?? attributeDict["href"]
                if let src, !src.isEmpty {
                    imageCount += 1
                    blocks.append(.image(
                        name: EpubBook.absolutePath(base: baseDir, href: src), data: nil
                    ))
                }
            case "br":
                buffer += "\n"
            case _ where Self.blockTags.contains(tag):
                flush()
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard skipDepth == 0 else { return }
            buffer += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            let tag = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName
            switch tag {
            case "script", "style":
                skipDepth = max(0, skipDepth - 1)
            case _ where Self.headingTags.contains(tag):
                flush()
                currentHeading = 0
            case _ where Self.blockTags.contains(tag):
                flush()
            default:
                break
            }
        }

        private func flush() {
            let text = buffer
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = ""
            guard !text.isEmpty else { return }
            totalTextLength += text.count
            blocks.append(.text(text, heading: currentHeading))
        }
    }
}
