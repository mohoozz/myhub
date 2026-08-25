import Foundation
import SwiftUI

/// 小说阅读器状态机（TODO §5）：
/// - 加载：txt 建索引（编码检测 + 字节级行扫描）/ epub 解包 → **排版无关锚点一步定位**；
/// - 分页：`TextPaginator` 行边界分页，翻页/滚动双模式；
/// - 章节预加载（当前 ±1）；设置实时重排（锚点保持）；
/// - 进度：3s 节流 + 退出/切章强制上报（`NovelProgressStore`）。
@MainActor
final class NovelReaderViewModel: ObservableObject {

    enum State: Equatable {
        case indexing(Double)   // txt 索引构建中（进度 0~1）
        case loading            // epub 解包 / 章节加载
        case ready
        case failed(String)
    }

    let connection: Connection
    let entry: FileEntry
    let isEpub: Bool

    @Published private(set) var state: State = .loading
    @Published private(set) var bookTitle: String
    @Published private(set) var toc: [NovelTocEntry] = []
    @Published private(set) var chapter = 0
    @Published private(set) var page = 0
    @Published private(set) var blocks: [ReaderBlock] = []
    @Published private(set) var pagination: ChapterPagination?
    @Published private(set) var chapterLoading = false
    /// epub 图集型检测信号：为 true 时 View 层自动转交漫画阅读器（不再弹选择框）
    @Published var comicLikePrompt = false
    @Published var toast: String?
    /// 滚动模式：程序滚动目标页（ScrollViewReader 消费；滚动期间忽略可见页回写）
    @Published var scrollIntent: Int?

    /// 阅读设置（改动即持久化并重排，锚点保持）
    @Published var appearance: ReaderAppearance {
        didSet {
            guard appearance != oldValue else { return }
            AppSettings.Reader.fontSize = appearance.fontSize
            AppSettings.Reader.lineSpacing = appearance.lineSpacing
            AppSettings.Reader.theme = appearance.theme
            AppSettings.Reader.pageMode = appearance.pageMode
            AppSettings.Reader.useSerifFont = appearance.useSerifFont
            repaginatePreservingAnchor()
        }
    }

    var themeSpec: ReaderThemeSpec { ReaderThemeSpec.spec(for: appearance.theme) }

    // txt
    private var txtIndex: TxtNovelIndexer.IndexData?
    private var txtChapter: TxtChapterLoader.ChapterText?   // 当前章（行字节范围映射）
    // epub
    private var epubBook: EpubBook?
    /// 章节磁盘缓存身份（IOS-605）：txt 用章节索引指纹，epub 用打开时 entry 指纹 / 离线反查身份
    private var cacheIdentity: SegmentCache.FileIdentity?

    private struct LoadedChapter {
        let blocks: [ReaderBlock]
        let txtChapter: TxtChapterLoader.ChapterText?
    }

    private let adapter: StorageAdapter?
    private var chapterCache: [Int: LoadedChapter] = [:]
    private var preloadTask: Task<Void, Never>?
    private var reportTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var scrollIntentTask: Task<Void, Never>?
    private var coverKey: String?
    private var pageSize: CGSize = .zero
    private var lastAnchorCharOffset = 0   // 重排前锚点（设置/旋转变化恢复用）
    private var systemBrightness: CGFloat = -1
    private var loadTask: Task<Void, Never>?

    init(connection: Connection, entry: FileEntry) {
        self.connection = connection
        self.entry = entry
        self.isEpub = entry.ext == "epub"
        self.bookTitle = (entry.name as NSString).deletingPathExtension
        self.adapter = try? AdapterFactory.makeAdapter(for: connection)
        self.appearance = ReaderAppearance.current()
    }

    deinit {
        loadTask?.cancel()
        preloadTask?.cancel()
        reportTask?.cancel()
        toastTask?.cancel()
        scrollIntentTask?.cancel()
    }

    // MARK: - 加载与锚点一步定位

    func load() {
        guard loadTask == nil else { return }
        loadTask = Task { await performLoad() }
    }

    private func performLoad() async {
        guard let adapter else {
            state = .failed("连接不可用，请检查连接源配置")
            return
        }
        // 历史进度锚点 + 文件指纹校验（文件被替换则提示并归零，防跳转错乱）
        let saved = NovelProgressStore.loadAnchor(
            connectionID: connectionID, path: entry.path, isEpub: isEpub,
            fileSize: entry.size, modTime: entry.modTime
        )
        var anchor = saved
        if let saved, !saved.fingerprintMatches(fileSize: entry.size, modTime: entry.modTime) {
            anchor = nil
            showToast("文件已更新，进度已重置")
        }
        do {
            if isEpub {
                try await loadEpub(adapter: adapter, anchor: anchor)
            } else {
                try await loadTxt(adapter: adapter, anchor: anchor)
            }
            state = .ready
            applyReaderBrightness()
        } catch is CancellationError {
            // 退出时取消，不报错
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func loadTxt(adapter: StorageAdapter, anchor: NovelAnchor?) async throws {
        state = .indexing(0)
        let index = try await TxtNovelIndexer.index(
            adapter: adapter, connectionID: connectionID, entry: entry
        ) { [weak self] fraction in
            Task { @MainActor in self?.state = .indexing(fraction) }
        }
        try Task.checkCancellation()
        txtIndex = index
        // 章节磁盘缓存键与索引同源（索引指纹）：在线与 entry 一致，离线回退缓存索引时键自洽
        cacheIdentity = SegmentCache.FileIdentity(
            connectionID: connectionID,
            path: entry.path,
            size: index.fileSize,
            modTime: index.modTime.timeIntervalSince1970
        )
        toc = index.chapters.enumerated().map { NovelTocEntry(id: $0, title: $1.title) }

        // 一步定位：全局字节偏移 → 二分反查章 → 章内字节 → 行表映射章内字符
        let offset = max(0, min(anchor?.offset ?? 0, index.fileSize - 1))
        let targetChapter = index.chapterIndex(forOffset: offset)
        let chapterStart = index.chapters[targetChapter].startOffset
        let loaded = try await loadChapter(targetChapter)
        chapter = targetChapter
        txtChapter = loaded.txtChapter
        let offsetInChapter = max(0, offset - chapterStart)
        lastAnchorCharOffset = txtByteOffsetToCharOffset(offsetInChapter)
        blocks = loaded.blocks
    }

    private func loadEpub(adapter: StorageAdapter, anchor: NovelAnchor?) async throws {
        state = .loading
        let book: EpubBook
        do {
            book = try await EpubBook(adapter: adapter, entry: entry)
            let identity = SegmentCache.FileIdentity(
                connectionID: connectionID,
                path: entry.path,
                size: entry.size,
                modTime: entry.modTime.timeIntervalSince1970
            )
            cacheIdentity = identity
            // 元数据落盘（IOS-605：离线打开重建用）
            let meta = book.cacheMeta
            Task.detached(priority: .utility) {
                await NovelChapterCache.storeMeta(meta, file: identity)
            }
        } catch {
            // 离线回退：元数据 + 章节内容已缓存时可离线阅读
            guard let identity = await NovelChapterCache.identity(
                connectionID: connectionID, path: entry.path
            ), let meta = await NovelChapterCache.meta(file: identity) else { throw error }
            book = EpubBook(offline: meta)
            cacheIdentity = identity
            showToast("离线模式：仅已缓存章节可读")
        }
        try Task.checkCancellation()
        epubBook = book
        bookTitle = book.title
        toc = book.toc.map { NovelTocEntry(id: $0.spineIndex, title: $0.title) }
        if book.isComicLike {
            // 图集型：交由 View 层自动转交漫画阅读器（不再弹选择框）
            comicLikePrompt = true
            return
        }
        // 封面异步提取缓存（「正在阅读」封面）
        Task.detached { [weak self, connectionID = self.connectionID, path = self.entry.path] in
            let key = await book.cacheCoverThumbnail(connectionID: connectionID, path: path)
            await MainActor.run {
                self?.coverKey = key
                if let key {
                    NovelProgressStore.updateCover(connectionID: connectionID, path: path, cover: key)
                }
            }
        }

        // 一步定位：spine 序号 → 段落序号/段内偏移 → 组装文本字符位置
        let targetSpine = max(0, min(anchor?.spineIndex ?? 0, book.spine.count - 1))
        let loaded = try await loadChapter(targetSpine)
        chapter = targetSpine
        blocks = loaded.blocks
        txtChapter = nil
        // 段落锚点依赖分页产物的块位置映射，延迟到首次分页完成时换算（见 repaginate 回调）
        pendingEpubParagraph = anchor.map { ($0.paragraphIndex, $0.characterOffset) }
    }

    private var pendingEpubParagraph: (paragraph: Int, offset: Int)?

    // MARK: - 分页（View 报告可用尺寸后触发）

    func paginateIfNeeded(size: CGSize) {
        guard size.width > 20, size.height > 20, size != pageSize, !blocks.isEmpty else { return }
        let preserved = pageSize == .zero ? lastAnchorCharOffset : currentCharOffset()
        pageSize = size
        repaginate(anchorCharOffset: preserved)
    }

    private func repaginatePreservingAnchor() {
        repaginate(anchorCharOffset: currentCharOffset())
    }

    private func repaginate(anchorCharOffset: Int) {
        guard pageSize != .zero, !blocks.isEmpty else { return }
        let appearance = self.appearance
        let blocks = self.blocks
        let textColor = UIColor(themeSpec.text)
        let size = pageSize
        let chapterSnapshot = chapter
        // 排版放后台，避免大章阻塞主线程
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = TextPaginator.paginate(
                blocks: blocks, appearance: appearance, pageSize: size, textColor: textColor
            )
            await MainActor.run {
                guard let self, self.chapter == chapterSnapshot, self.blocks == blocks else { return }
                self.pagination = result
                var offset = anchorCharOffset
                // epub 首次定位：段落锚点换算为组装文本字符位置（需分页产物的块位置映射）
                if let pending = self.pendingEpubParagraph {
                    offset = result.charOffset(
                        forParagraph: pending.paragraph,
                        offsetInParagraph: pending.offset,
                        blocks: self.blocks
                    )
                    self.pendingEpubParagraph = nil
                }
                let maxOffset = max(result.attributedText.length - 1, 0)
                self.page = result.pageIndex(forCharOffset: min(offset, maxOffset))
                if self.appearance.pageMode == .scrolling {
                    self.armScrollIntent(self.page)
                }
            }
        }
    }

    /// 设置程序滚动目标并在滚动窗口期后自动清除（期间忽略可见页回写）
    private func armScrollIntent(_ target: Int?) {
        scrollIntent = target
        scrollIntentTask?.cancel()
        guard target != nil else { return }
        scrollIntentTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !Task.isCancelled { scrollIntent = nil }
        }
    }

    // MARK: - 翻页 / 章节导航

    var pageCount: Int { pagination?.pages.count ?? 0 }

    func goToPage(_ target: Int) {
        guard let pagination else { return }
        if target < 0 {
            if chapter > 0 { goToChapter(chapter - 1, toLastPage: true) }
            return
        }
        if target >= pagination.pages.count {
            if chapter + 1 < toc.count { goToChapter(chapter + 1) }
            return
        }
        page = target
        reportThrottled()
        checkFinished()
    }

    func goToChapter(_ target: Int, toLastPage: Bool = false) {
        guard toc.indices.contains(target), target != chapter || pagination == nil else { return }
        report(force: true)
        chapter = target
        page = 0
        pagination = nil
        chapterLoading = true
        Task {
            do {
                let loaded = try await loadChapter(target)
                try Task.checkCancellation()
                txtChapter = loaded.txtChapter
                blocks = loaded.blocks
                chapterLoading = false
                repaginate(anchorCharOffset: 0)
                if toLastPage {
                    // 等分页完成后跳最后一页（上限 2s 防异常死等）
                    Task {
                        for _ in 0..<40 {
                            if self.pagination != nil || Task.isCancelled { break }
                            try? await Task.sleep(nanoseconds: 50_000_000)
                        }
                        if let count = self.pagination?.pages.count {
                            self.page = max(0, count - 1)
                        }
                    }
                }
            } catch is CancellationError {
            } catch {
                chapterLoading = false
                showToast("章节加载失败：\(error.localizedDescription)")
            }
        }
    }

    /// 滚动模式上报可见页（程序滚动期间不回写）
    func scrollVisiblePage(_ index: Int) {
        guard appearance.pageMode == .scrolling, scrollIntent == nil,
              index != page, index >= 0, index < pageCount else { return }
        page = index
        reportThrottled()
        checkFinished()
    }

    /// 滚动模式点击分区翻页：先改页码，View 层 ScrollViewReader 消费 scrollIntent 滚动
    func requestScroll(to target: Int) {
        guard appearance.pageMode == .scrolling, pagination != nil else { return }
        if target < 0 || target >= pageCount {
            goToPage(target)   // 越界 → 切章
            return
        }
        page = target
        armScrollIntent(target)
        reportThrottled()
        checkFinished()
    }

    // MARK: - 章节加载（缓存 ±1 预加载）

    private func loadChapter(_ target: Int) async throws -> LoadedChapter {
        if let cached = chapterCache[target] { return cached }
        let loaded: LoadedChapter
        if isEpub {
            guard let epubBook else { throw StorageError.invalidConfig("epub 未解包") }
            // IOS-605 章节磁盘缓存：命中免解析免网络（离线可读），未命中解析后落盘
            var cachedBlocks: [ReaderBlock]?
            if let identity = cacheIdentity {
                cachedBlocks = await NovelChapterCache.blocks(file: identity, spine: target)
            }
            if let cachedBlocks {
                loaded = LoadedChapter(blocks: cachedBlocks, txtChapter: nil)
            } else {
                let blocks = try await epubBook.blocks(forSpine: target)
                if let identity = cacheIdentity {
                    Task.detached(priority: .utility) {
                        await NovelChapterCache.storeBlocks(blocks, file: identity, spine: target)
                    }
                }
                loaded = LoadedChapter(blocks: blocks, txtChapter: nil)
            }
        } else {
            guard let txtIndex else { throw StorageError.invalidConfig("索引未建立") }
            // IOS-605 章节磁盘缓存：命中免网络（离线可读），未命中经适配器读取后落盘
            let chapterText: TxtChapterLoader.ChapterText
            if let identity = cacheIdentity,
               let cached = await NovelChapterCache.chapterText(file: identity, chapter: target) {
                chapterText = cached
            } else {
                guard let adapter else { throw StorageError.invalidConfig("连接不可用") }
                let loadedText = try await TxtChapterLoader.load(
                    adapter: adapter, path: entry.path, index: txtIndex, chapter: target
                )
                if let identity = cacheIdentity {
                    Task.detached(priority: .utility) {
                        await NovelChapterCache.storeChapterText(loadedText, file: identity, chapter: target)
                    }
                }
                chapterText = loadedText
            }
            // 原始行直接成段（保留缩进与空行间距）；章首行命中标题则放大加粗
            let title = txtIndex.chapters[target].title
            let blocks: [ReaderBlock] = chapterText.lines.enumerated().map { lineIndex, line in
                let isTitle = lineIndex == 0
                    && line.text.trimmingCharacters(in: .whitespaces) == title
                return .text(line.text, heading: isTitle ? 2 : 0)
            }
            loaded = LoadedChapter(
                blocks: blocks.isEmpty ? [.text("（本章无内容）", heading: 0)] : blocks,
                txtChapter: chapterText
            )
        }
        chapterCache[target] = loaded
        schedulePreload(around: target)
        return loaded
    }

    /// 章节预加载：当前 ±1（LRU 上限 3 章）
    private func schedulePreload(around target: Int) {
        preloadTask?.cancel()
        preloadTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let neighbors = [target - 1, target + 1].filter { $0 >= 0 }
            for neighbor in neighbors {
                if Task.isCancelled { return }
                let count = await MainActor.run { self.toc.count }
                guard neighbor < count else { continue }
                _ = try? await self.loadChapter(neighbor)
            }
            await MainActor.run {
                // LRU：只保留当前 ±1
                let keep: Set<Int> = [target - 1, target, target + 1]
                self.chapterCache = self.chapterCache.filter { keep.contains($0.key) }
            }
        }
    }

    // MARK: - 进度上报

    /// 当前页首在章组装文本中的字符位置
    private func currentCharOffset() -> Int {
        guard let pagination, pagination.pages.indices.contains(page) else { return 0 }
        return pagination.pages[page].lowerBound
    }

    private func makeAnchor() -> NovelAnchor {
        let charOffset = currentCharOffset()
        if isEpub {
            let anchor = pagination?.paragraphAnchor(forCharOffset: charOffset, blocks: blocks)
                ?? (paragraph: 0, offsetInParagraph: 0)
            return NovelAnchor(
                kind: .epub,
                spineIndex: chapter,
                paragraphIndex: anchor.paragraph,
                characterOffset: anchor.offsetInParagraph,
                fileSize: entry.size,
                modTime: entry.modTime.timeIntervalSince1970
            )
        }
        // txt：组装文本字符位置 → 行表映射章内字节偏移 → + 章起始 → 全局字节偏移
        let offsetInChapter = txtCharOffsetToByteOffset(charOffset)
        let chapterStart = txtIndex?.chapters[chapter].startOffset ?? 0
        return NovelAnchor(
            kind: .txt,
            offset: chapterStart + offsetInChapter,
            fileSize: entry.size,
            modTime: entry.modTime.timeIntervalSince1970
        )
    }

    /// txt 锚点换算：组装文本字符位置 → 章内字节偏移（行字节范围映射，与排版无关）
    private func txtCharOffsetToByteOffset(_ charOffset: Int) -> Int64 {
        guard let chapterText = txtChapter, !chapterText.lines.isEmpty else { return 0 }
        var consumed = 0
        var lineIndex = 0
        var inLine = 0
        for (index, line) in chapterText.lines.enumerated() {
            if consumed + line.text.count > charOffset {
                lineIndex = index
                inLine = charOffset - consumed
                break
            }
            consumed += line.text.count + 1   // 段 + 段间分隔 \n
            lineIndex = index
            inLine = line.text.count
        }
        let line = chapterText.lines[lineIndex]
        let inLineBytes = String(line.text.prefix(inLine))
            .data(using: chapterText.encoding)?.count ?? 0
        return line.byteRange.lowerBound + Int64(inLineBytes)
    }

    /// txt 锚点换算：章内字节偏移 → 组装文本字符位置（行二分 + 行内前缀解码，码元边界回退）
    private func txtByteOffsetToCharOffset(_ byteOffset: Int64) -> Int {
        guard let chapterText = txtChapter, !chapterText.lines.isEmpty else { return 0 }
        var lineIndex = 0
        for (index, line) in chapterText.lines.enumerated()
        where line.byteRange.lowerBound <= byteOffset {
            lineIndex = index
        }
        let line = chapterText.lines[lineIndex]
        let inLineByte = max(0, Int(byteOffset - line.byteRange.lowerBound))
        // 行内字节 → 行内字符：原始字节前缀解码，截在多字节字符中间时回退码元边界
        let rawStart = max(0, Int(line.byteRange.lowerBound - chapterText.baseOffset))
        let raw = chapterText.rawData.dropFirst(rawStart).prefix(inLineByte)
        var inLineChars = 0
        var probe = raw.count
        while probe >= 0 {
            if let decoded = String(data: raw.prefix(probe), encoding: chapterText.encoding) {
                inLineChars = decoded.count
                break
            }
            probe -= 1
        }
        // 组装文本字符位置 = Σ(前序行文本长度 + 1) + 行内字符
        var charOffset = inLineChars
        for prior in 0..<lineIndex {
            charOffset += chapterText.lines[prior].text.count + 1
        }
        return charOffset
    }

    private var currentPercent: Double {
        if isEpub {
            let spineCount = max(toc.count, 1)
            let inChapter = pageCount > 0 ? Double(page) / Double(pageCount) : 0
            return (Double(chapter) + inChapter) / Double(spineCount)
        }
        guard let txtIndex, txtIndex.fileSize > 0 else { return 0 }
        return Double(makeAnchor().offset) / Double(txtIndex.fileSize)
    }

    /// 翻页/滚动触发：3s 节流上报
    func reportThrottled() {
        guard reportTask == nil else { return }
        reportTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            reportTask = nil
            if !Task.isCancelled { reportNow() }
        }
    }

    /// 立即上报（切章 / 退出 / 进后台）
    func report(force: Bool) {
        reportTask?.cancel()
        reportTask = nil
        if force { reportNow() }
    }

    private func reportNow() {
        guard state == .ready, pagination != nil else { return }
        NovelProgressStore.save(
            connectionID: connectionID,
            path: entry.path,
            title: bookTitle,
            anchor: makeAnchor(),
            percent: currentPercent,
            finished: isAtEnd,
            cover: coverKey
        )
    }

    private var isAtEnd: Bool {
        chapter >= toc.count - 1 && page >= pageCount - 1 && pageCount > 0
    }

    private func checkFinished() {
        if isAtEnd { report(force: true) }
    }

    /// 退出阅读器：强制上报 + 恢复进入前亮度 + 取消加载
    func teardown() {
        report(force: true)
        loadTask?.cancel()
        preloadTask?.cancel()
        if systemBrightness >= 0 {
            UIScreen.main.brightness = systemBrightness
        }
    }

    // MARK: - 亮度

    func setBrightness(_ value: Double) {
        AppSettings.Reader.brightness = value
        if value >= 0 {
            UIScreen.main.brightness = CGFloat(value)
        } else if systemBrightness >= 0 {
            UIScreen.main.brightness = systemBrightness   // 跟随系统：恢复进入前亮度
        }
    }

    private func applyReaderBrightness() {
        systemBrightness = UIScreen.main.brightness
        let stored = AppSettings.Reader.brightness
        if stored >= 0 {
            UIScreen.main.brightness = CGFloat(stored)
        }
    }

    // MARK: - 工具

    var currentChapterTitle: String {
        toc.indices.contains(chapter) ? toc[chapter].title : ""
    }

    /// 分页结果中某一页的富文本（保留 NSParagraphStyle 行距/段距，供 UILabel 渲染）
    func pageContent(_ target: Int) -> NSAttributedString {
        guard let pagination, pagination.pages.indices.contains(target) else { return NSAttributedString() }
        let range = pagination.pages[target]
        return pagination.attributedText.attributedSubstring(
            from: NSRange(location: range.lowerBound, length: range.count)
        )
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    private var connectionID: Int64 { connection.id ?? 0 }
}
