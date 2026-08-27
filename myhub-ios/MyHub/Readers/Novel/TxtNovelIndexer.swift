import Foundation
import GRDB

/// txt 小说章节索引器（IOS-205 / 编码检测 IOS-706）：
/// - **编码检测**：复用 `TextEncodingDetector`（BOM + 无 BOM 启发式，覆盖 UTF-8 / GBK / Big5 / UTF-16 LE/BE）；
/// - **字节级行扫描**：直接在字节流按 \n 切行（各编码下 \n 均为单码元且不出现于多字节字符内部），
///   章节标题的**全局字节偏移精确无漂移**（不依赖字符串重编码累加）；
/// - **章节正则**：识别「第 x 章/节/回/卷…」「Chapter n」「楔子/序章/尾声/番外」等标题行；
/// - **索引缓存**：`NovelIndex` 表（可重建缓存），文件指纹（fileSize + modTime）校验；
///   旧缓存**编码复核自愈**——抽样解码异常（替换符占比高）则自动重建；
/// - **二分反查**：全局字节偏移 → 所在章节（排版无关锚点一步定位的核心）。
enum TxtNovelIndexer {

    struct IndexData {
        let encoding: String.Encoding
        let encodingName: String
        let chapters: [ChapterInfo]   // 各章标题 + 起始全局字节偏移
        let fileSize: Int64
        let modTime: Date

        /// 二分反查：全局字节偏移 → 章下标（最后一个 startOffset <= offset 的章）
        func chapterIndex(forOffset offset: Int64) -> Int {
            var low = 0, high = chapters.count - 1, result = 0
            while low <= high {
                let mid = (low + high) / 2
                if chapters[mid].startOffset <= offset {
                    result = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            return result
        }

        /// 章字节区间 [start, end)
        func byteRange(ofChapter index: Int) -> Range<Int64> {
            let start = chapters[index].startOffset
            let end = index + 1 < chapters.count ? chapters[index + 1].startOffset : fileSize
            return start..<max(end, start)
        }
    }

    // MARK: - 入口（带缓存 + 指纹校验 + 编码复核自愈）

    static func index(
        adapter: StorageAdapter,
        connectionID: Int64,
        entry: FileEntry,
        progress: ((Double) -> Void)? = nil
    ) async throws -> IndexData {
        if let cached = loadCachedIndex(connectionID: connectionID, path: entry.path),
           cached.fileSize == entry.size,
           abs(cached.modTime.timeIntervalSince1970 - entry.modTime.timeIntervalSince1970) < 2 {
            // 编码复核自愈：抽样解码首章，替换符过多说明缓存编码错误 → 重建
            if await verifyEncoding(cached, adapter: adapter, path: entry.path),
               await verifyFirstChapterConsistency(cached, adapter: adapter, path: entry.path) {
                AppLogger.shared.log(
                    "TXT索引缓存命中 name=\(entry.name) path=\(entry.path) chapters=\(cached.chapters.count) first=\"\(cached.chapters.first?.title ?? "无")\" second=\"\(cached.chapters.count > 1 ? cached.chapters[1].title : "无")\"",
                    module: "novel-index"
                )
                return cached
            }
            AppLogger.shared.log("TXT索引缓存复核未通过，触发重建 name=\(entry.name)", level: .warn, module: "novel-index")
        }
        AppLogger.shared.log("TXT索引重建开始 name=\(entry.name)", module: "novel-index")
        let fresh = try await rebuild(adapter: adapter, entry: entry, progress: progress)
        saveCachedIndex(fresh, connectionID: connectionID, path: entry.path)
        return fresh
    }

    // MARK: - 重建索引

    private static func rebuild(
        adapter: StorageAdapter,
        entry: FileEntry,
        progress: ((Double) -> Void)?
    ) async throws -> IndexData {
        // 1. 头部采样检测编码
        let headRange = 0..<min(entry.size, 64 * 1024)
        let head = try await readAll(adapter: adapter, path: entry.path, range: headRange)
        let detected = TextEncodingDetector.decode(head)
        let encoding = detected.encoding

        AppLogger.shared.log(
            "TXT索引重建 name=\(entry.name) size=\(entry.size) encoding=\(detected.encodingName)",
            module: "novel-index"
        )

        // 2. 字节级行扫描（分块流式，跨块行拼接），正则识别章节标题
        let isUTF16 = encoding == .utf16LittleEndian || encoding == .utf16BigEndian
        var chapters: [ChapterInfo] = []
        var pending = Data()
        var pendingGlobalStart: Int64 = 0
        var offset: Int64 = 0
        let chunkSize: Int64 = 512 * 1024
        var scannedLines = 0

        while offset < entry.size {
            try Task.checkCancellation()
            let end = min(offset + chunkSize, entry.size)
            let chunk = try await readAll(adapter: adapter, path: entry.path, range: offset..<end)

            var buffer = pending
            let bufferGlobalStart = pendingGlobalStart
            buffer.append(chunk)

            var cursor = buffer.startIndex
            let newline = Self.newlineScanner(isUTF16: isUTF16, littleEndian: encoding == .utf16LittleEndian)
            while let hit = newline(buffer, cursor) {
                let lineData = Data(buffer[cursor..<hit.lineEnd])
                let global = bufferGlobalStart + Int64(cursor - buffer.startIndex)
                let matched = matchChapterTitle(lineData: lineData, encoding: encoding)

                // 排查分章漏检：前 15 行打日志（含不可见字符转义，定位 BOM/编码/格式）
                if scannedLines < 15 {
                    let decoded = String(data: lineData, encoding: encoding) ?? "<decode-fail>"
                    AppLogger.shared.log(
                        "TXT行[\(scannedLines)] offset=\(global) hit=\(matched != nil) text=\(Self.visible(decoded))",
                        module: "novel-index"
                    )
                }
                scannedLines += 1

                if let chapter = matched {
                    // 同偏移去重（个别书重复标题行）
                    if chapters.last?.startOffset != global {
                        chapters.append(ChapterInfo(title: chapter, startOffset: global))
                        if chapters.count <= 12 {
                            AppLogger.shared.log(
                                "TXT章节[\(chapters.count - 1)] offset=\(global) title=\(chapter)",
                                module: "novel-index"
                            )
                        }
                    }
                }
                cursor = hit.nextStart
            }
            pending = Data(buffer[cursor...])
            pendingGlobalStart = bufferGlobalStart + Int64(cursor - buffer.startIndex)
            offset = end
            progress?(Double(offset) / Double(max(entry.size, 1)) * 0.9)
        }
        // 文件末尾无换行的最后一行
        if !pending.isEmpty,
           let chapter = matchChapterTitle(lineData: pending, encoding: encoding) {
            if chapters.last?.startOffset != pendingGlobalStart {
                chapters.append(ChapterInfo(title: chapter, startOffset: pendingGlobalStart))
            }
        }

        // 3. 无章节命中（短篇/无标题）：整本单章
        if chapters.isEmpty {
            chapters = [ChapterInfo(title: "正文", startOffset: 0)]
        }
        progress?(1)

        AppLogger.shared.log(
            "TXT索引完成 name=\(entry.name) chapters=\(chapters.count) first=\"\(chapters.first?.title ?? "无")\" second=\"\(chapters.count > 1 ? chapters[1].title : "无")\" last=\"\(chapters.last?.title ?? "无")\"",
            module: "novel-index"
        )
        return IndexData(
            encoding: encoding,
            encodingName: detected.encodingName,
            chapters: chapters,
            fileSize: entry.size,
            modTime: entry.modTime
        )
    }

    // MARK: - 章节标题正则

    private static let chapterPatterns: [NSRegularExpression] = {
        let patterns = [
            #"^第[0-9０-９零〇一二三四五六七八九十百千万两壹贰叁肆伍陆柒捌玖拾佰仟]+[章节回卷集部篇][^\n]{0,38}$"#,
            #"^(楔子|序章|序言|前言|引子|终章|尾声|后记|番外篇?)([^\n]{0,30})?$"#,
            #"^(Chapter|CHAPTER|chapter)\s+[0-9０-９IVXLCivxlc]+[^\n]{0,38}$"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// 将不可见字符转义，便于在日志中排查 BOM / 零宽字符导致的漏检
    private static func visible(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xFEFF: out += "\\u{FEFF}"          // BOM
            case 0x200B: out += "\\u{200B}"          // 零宽空格
            case 0x200C: out += "\\u{200C}"          // 零宽不连字
            case 0x200D: out += "\\u{200D}"          // 零宽连字
            case 0x00A0: out += "\\u{00A0}"          // 不换行空格
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            default: out += String(scalar)
            }
        }
        return out
    }

    /// 行字节 → 解码 → trim → 正则匹配；标题行长度受限且不以句号收尾（过滤正文）
    private static func matchChapterTitle(lineData: Data, encoding: String.Encoding) -> String? {
        guard lineData.count <= 140, !lineData.isEmpty else { return nil }
        guard var text = String(data: lineData, encoding: encoding) else { return nil }
        // 去掉文件头 BOM：UTF-8/UTF-16 BOM 解码后为 \u{FEFF}，会挡住正则 ^第 导致第一章漏检
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 42 else { return nil }
        if text.hasSuffix("。") || text.hasSuffix("，") || text.hasSuffix("；") { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for pattern in chapterPatterns where pattern.firstMatch(in: text, range: range) != nil {
            return text
        }
        return nil
    }

    // MARK: - 换行扫描（字节级）

    private struct NewlineHit {
        let lineEnd: Data.Index      // 行内容结束（不含 \r）
        let nextStart: Data.Index    // 下一行起始
    }

    /// UTF-8 / GBK / Big5：\n 单字节且不出现在多字节序列内；UTF-16：按 2 字节单位扫 0x0A
    private static func newlineScanner(
        isUTF16: Bool, littleEndian: Bool
    ) -> (Data, Data.Index) -> NewlineHit? {
        if isUTF16 {
            return { buffer, from in
                var index = from
                // 保证按码元对齐扫描
                if (index - buffer.startIndex) % 2 != 0 { index += 1 }
                while index + 1 < buffer.endIndex {
                    let first = buffer[index]
                    let second = buffer[index + 1]
                    let isLF = littleEndian ? (first == 0x0A && second == 0x00) : (first == 0x00 && second == 0x0A)
                    if isLF {
                        var lineEnd = index
                        // 去掉行尾 \r（0x0D 0x00 / 0x00 0x0D）
                        if lineEnd - 2 >= buffer.startIndex {
                            let b0 = buffer[lineEnd - 2], b1 = buffer[lineEnd - 1]
                            let isCR = littleEndian ? (b0 == 0x0D && b1 == 0x00) : (b0 == 0x00 && b1 == 0x0D)
                            if isCR { lineEnd -= 2 }
                        }
                        return NewlineHit(lineEnd: lineEnd, nextStart: index + 2)
                    }
                    index += 2
                }
                return nil
            }
        }
        return { buffer, from in
            var index = from
            while index < buffer.endIndex {
                if buffer[index] == 0x0A {
                    var lineEnd = index
                    if lineEnd > buffer.startIndex, buffer[lineEnd - 1] == 0x0D { lineEnd -= 1 }
                    return NewlineHit(lineEnd: lineEnd, nextStart: index + 1)
                }
                index += 1
            }
            return nil
        }
    }

    // MARK: - 索引缓存（NovelIndex 表，可重建）

    private static func loadCachedIndex(connectionID: Int64, path: String) -> IndexData? {
        guard let db = AppDatabase.shared.dbQueue else { return nil }
        guard let record = try? db.read({ database in
            try NovelIndex
                .filter(Column("connectionID") == connectionID && Column("filePath") == path)
                .fetchOne(database)
        }), let chaptersData = record.chaptersJSON.data(using: .utf8),
              let chapters = try? JSONDecoder().decode([ChapterInfo].self, from: chaptersData),
              let encoding = Self.encoding(fromName: record.encoding) else { return nil }
        return IndexData(
            encoding: encoding,
            encodingName: record.encoding,
            chapters: chapters,
            fileSize: record.fileSize,
            modTime: record.modTime
        )
    }

    private static func saveCachedIndex(_ data: IndexData, connectionID: Int64, path: String) {
        guard let db = AppDatabase.shared.dbQueue,
              let chaptersData = try? JSONEncoder().encode(data.chapters),
              let chaptersJSON = String(data: chaptersData, encoding: .utf8) else { return }
        try? db.write { database in
            if var existing = try NovelIndex
                .filter(Column("connectionID") == connectionID && Column("filePath") == path)
                .fetchOne(database) {
                existing.encoding = data.encodingName
                existing.chaptersJSON = chaptersJSON
                existing.fileSize = data.fileSize
                existing.modTime = data.modTime
                try existing.update(database)
            } else {
                var record = NovelIndex(
                    id: nil,
                    connectionID: connectionID,
                    filePath: path,
                    encoding: data.encodingName,
                    chaptersJSON: chaptersJSON,
                    fileSize: data.fileSize,
                    modTime: data.modTime
                )
                try record.insert(database)
            }
        }
    }

    /// 编码复核自愈：抽首章前 4KB 解码，失败或替换符 >1% 判定缓存编码失效
    private static func verifyEncoding(_ data: IndexData, adapter: StorageAdapter, path: String) async -> Bool {
        guard let first = data.chapters.first else { return false }
        let end = min(first.startOffset + 4096, data.fileSize)
        guard end > first.startOffset,
              let sample = try? await readAll(
                adapter: adapter, path: path, range: first.startOffset..<end
              ) else {
            // 读取异常（如网络抖动）不判死，信任缓存避免反复重建；下次打开再复核
            return true
        }
        guard !sample.isEmpty else { return true }
        guard let text = String(data: sample, encoding: data.encoding) else { return false }
        let scalars = text.unicodeScalars
        guard !scalars.isEmpty else { return true }
        let replaced = scalars.filter { $0.value == 0xFFFD }.count
        return Double(replaced) / Double(scalars.count) <= 0.01
    }

    /// 首章一致性自愈：从文件头扫描第一个章节标题行，与缓存首章 startOffset 比对。
    /// 旧缓存若漏检第一章（如 BOM 未 strip），偏移不一致 → 返回 false 触发重建。
    private static func verifyFirstChapterConsistency(
        _ data: IndexData, adapter: StorageAdapter, path: String
    ) async -> Bool {
        guard let first = data.chapters.first else { return true }
        let headRange = 0..<min(data.fileSize, 8 * 1024)
        guard headRange.upperBound > 0,
              let head = try? await readAll(adapter: adapter, path: path, range: headRange),
              !head.isEmpty else { return true }

        let encoding = data.encoding
        let isUTF16 = encoding == .utf16LittleEndian || encoding == .utf16BigEndian
        let newline = newlineScanner(isUTF16: isUTF16, littleEndian: encoding == .utf16LittleEndian)

        var cursor = head.startIndex
        while let hit = newline(head, cursor) {
            let lineData = Data(head[cursor..<hit.lineEnd])
            if matchChapterTitle(lineData: lineData, encoding: encoding) != nil {
                let global = Int64(cursor - head.startIndex)
                if global != first.startOffset {
                    AppLogger.shared.log(
                        "TXT索引首章不一致：文件首标题 offset=\(global) vs 缓存首章 offset=\(first.startOffset) title=\"\(first.title)\"，触发重建 path=\(path)",
                        level: .warn, module: "novel-index"
                    )
                    return false
                }
                return true
            }
            cursor = hit.nextStart
        }
        return true
    }

    // MARK: - 工具

    private static func readAll(
        adapter: StorageAdapter, path: String, range: Range<Int64>
    ) async throws -> Data {
        let stream = try await adapter.readStream(path, range: range)
        var data = Data()
        data.reserveCapacity(Int(min(range.upperBound - range.lowerBound, 512 * 1024)))
        for try await chunk in stream {
            data.append(chunk)
            try Task.checkCancellation()
        }
        return data
    }

    /// 编码名 → String.Encoding（索引缓存持久化用）
    static func encoding(fromName name: String) -> String.Encoding? {
        switch name {
        case let n where n.hasPrefix("UTF-8"): return .utf8
        case let n where n.hasPrefix("UTF-16 LE"): return .utf16LittleEndian
        case let n where n.hasPrefix("UTF-16 BE"): return .utf16BigEndian
        case "GBK": return TextEncodingDetector.gb18030
        case "Big5": return TextEncodingDetector.big5
        default: return nil
        }
    }
}

// MARK: - 码元对齐（Range 读取切块边界不对齐多字节字符时回退/跳过）

enum CodeUnitAligner {
    /// 从头部的角度：块首落在字符中间时应跳过的字节数（0~3）
    static func headSkip(_ data: Data, encoding: String.Encoding) -> Int {
        guard !data.isEmpty else { return 0 }
        if encoding == .utf8 {
            var skip = 0
            while skip < min(3, data.count), (data[skip] & 0xC0) == 0x80 { skip += 1 }
            // 跳过后落在 lead byte 或 ASCII 上才有效；若连 4 个 continuation 则数据异常，不跳过
            if skip < data.count, (data[skip] & 0xC0) != 0x80 { return skip }
            return 0
        }
        if encoding == .utf16LittleEndian || encoding == .utf16BigEndian {
            return 0   // 调用方保证偶数对齐
        }
        // GBK / Big5 / GB18030：逐个候选跳过，选能让前 32 字节成功解码的最小值
        for skip in 0..<min(4, data.count) {
            let probe = data.dropFirst(skip).prefix(32)
            if String(data: probe, encoding: encoding) != nil { return skip }
        }
        return 0
    }

    /// 从尾部的角度：块尾截断多字节字符时应回退的字节数（0~3）
    static func tailDrop(_ data: Data, encoding: String.Encoding) -> Int {
        guard !data.isEmpty else { return 0 }
        if String(data: data, encoding: encoding) != nil { return 0 }
        for drop in 1...min(3, data.count - 1) {
            if String(data: data.dropLast(drop), encoding: encoding) != nil { return drop }
        }
        return 0
    }
}

// MARK: - txt 章节文本加载（按章 Range 流式读取 + 码元对齐解码 + 行字节范围映射）

enum TxtChapterLoader {
    /// 一行文本及其字节范围（byteRange 以章 startOffset 为基准，锚点精确换算的结构基础）
    struct Line {
        let text: String                 // 行原始内容（不 trim，保留缩进/空行）
        let byteRange: Range<Int64>
    }

    struct ChapterText {
        let encoding: String.Encoding
        let rawData: Data                // 对齐后的章原始字节（起点 = 章 startOffset + baseOffset）
        let baseOffset: Int64            // rawData 起点相对章 startOffset 的偏移（headSkip）
        let lines: [Line]
    }

    static func load(
        adapter: StorageAdapter,
        path: String,
        index: TxtNovelIndexer.IndexData,
        chapter: Int
    ) async throws -> ChapterText {
        let range = index.byteRange(ofChapter: chapter)
        guard range.upperBound > range.lowerBound else {
            return ChapterText(encoding: index.encoding, rawData: Data(), baseOffset: 0, lines: [])
        }
        var data = Data()
        let stream = try await adapter.readStream(path, range: range)
        for try await chunk in stream {
            data.append(chunk)
            try Task.checkCancellation()
        }
        // 码元对齐：块首跳过残缺字符、块尾回退截断字符
        let skip = CodeUnitAligner.headSkip(data, encoding: index.encoding)
        if skip > 0 { data = data.dropFirst(skip) }
        let drop = CodeUnitAligner.tailDrop(data, encoding: index.encoding)
        if drop > 0 { data = data.dropLast(drop) }

        let lines = splitLines(data, encoding: index.encoding, baseOffset: Int64(skip))
        return ChapterText(
            encoding: index.encoding, rawData: data, baseOffset: Int64(skip), lines: lines
        )
    }

    /// 字节级按 \n 切行（与索引器同一原则：\n 在各编码下均为单码元且不出现于多字节字符内部），
    /// 行文本解码失败的有损兜底，行字节范围保持精确。
    static func splitLines(_ data: Data, encoding: String.Encoding, baseOffset: Int64) -> [Line] {
        let isUTF16 = encoding == .utf16LittleEndian || encoding == .utf16BigEndian
        let littleEndian = encoding == .utf16LittleEndian
        let step = isUTF16 ? 2 : 1
        var lines: [Line] = []
        var lineStart = data.startIndex
        var index = data.startIndex

        func isNewline(at position: Data.Index) -> Bool {
            if isUTF16 {
                guard position + 1 < data.endIndex else { return false }
                let first = data[position], second = data[position + 1]
                return littleEndian ? (first == 0x0A && second == 0x00) : (first == 0x00 && second == 0x0A)
            }
            return data[position] == 0x0A
        }

        func makeLine(end: Data.Index) -> Line {
            var lineEnd = end
            // 去掉行尾 \r
            if isUTF16 {
                if lineEnd - 2 >= lineStart {
                    let b0 = data[lineEnd - 2], b1 = data[lineEnd - 1]
                    let isCR = littleEndian ? (b0 == 0x0D && b1 == 0x00) : (b0 == 0x00 && b1 == 0x0D)
                    if isCR { lineEnd -= 2 }
                }
            } else if lineEnd > lineStart, data[lineEnd - 1] == 0x0D {
                lineEnd -= 1
            }
            let bytes = Data(data[lineStart..<lineEnd])
            let text = String(data: bytes, encoding: encoding)
                ?? String(decoding: bytes, as: UTF8.self)
            let start = baseOffset + Int64(lineStart - data.startIndex)
            let finish = baseOffset + Int64(lineEnd - data.startIndex)
            return Line(text: text, byteRange: start..<finish)
        }

        while index < data.endIndex {
            if isNewline(at: index) {
                lines.append(makeLine(end: index))
                index += step
                lineStart = index
            } else {
                index += step
            }
        }
        if lineStart < data.endIndex {
            lines.append(makeLine(end: data.endIndex))
        }
        return lines
    }
}
