import Foundation
import SwiftUI

/// 滚动模式连续页流中的一页（跨章节全局唯一标识，用于 ScrollView 无缝拼接相邻章节）
struct ScrollPage: Identifiable, Equatable, Hashable {
    let chapter: Int
    let page: Int
    var id: String { "\(chapter)-\(page)" }
}

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
    /// 滚动模式：程序滚动目标页 id（ScrollViewReader 消费；滚动期间忽略可见页回写）
    @Published var scrollIntent: String?
    /// 滚动模式：滚动意图版本号。每次 armScrollIntent 递增，供 View 的 onChange 消费，
    /// 以解决「连续两次目标 id 相同时 @Published 值不变、onChange 不触发」的问题。
    @Published private(set) var scrollIntentRevision: Int = 0
    /// 滚动模式：连续页流（相邻章节页拼接，跨章无缝滚动）
    @Published private(set) var scrollStream: [ScrollPage] = []

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
    /// 滚动模式：下一章预分页缓存（滚到底自动翻章时直接切换，避免「章节加载中」闪屏）
    private var paginationCache: [Int: ChapterPagination] = [:]
    /// 滚动模式：正在分页中的章节，用于并发去重（scrollVisiblePage 与 scrollReachTop/End 可能同时触发同章预分页）
    private var paginatingInFlight: Set<Int> = []
    private var preloadTask: Task<Void, Never>?
    private var reportTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var scrollIntentTask: Task<Void, Never>?
    private var coverKey: String?
    private var pageSize: CGSize = .zero
    private var lastAnchorCharOffset = 0   // 重排前锚点（设置/旋转变化恢复用）
    private var systemBrightness: CGFloat = -1
    private var loadTask: Task<Void, Never>?
    private var paginationTask: Task<Void, Never>?          // 当前分页任务：设置连续变化时取消旧任务，防堆积发热
    private var repaginateDebounceTask: Task<Void, Never>?  // 设置连续变化防抖（合并为最后一次重排）
    private var paginationGeneration = 0                    // 分页代数：丢弃过期分页结果

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
        paginationTask?.cancel()
        repaginateDebounceTask?.cancel()
    }

    // MARK: - 加载与锚点一步定位

    func load() {
        guard loadTask == nil else { return }
        AppLogger.shared.log(
            "打开小说: name=\(entry.name) ext=\(entry.ext) isEpub=\(isEpub) size=\(entry.size) path=\(entry.path) conn=\(connectionID)",
            module: "novel-reader"
        )
        loadTask = Task { await performLoad() }
    }

    private func performLoad() async {
        guard let adapter else {
            state = .failed("连接不可用，请检查连接源配置")
            return
        }
        // 历史进度锚点 + 文件指纹校验（文件被替换时降级为按内容大致恢复，不再直接归零）
        let saved = NovelProgressStore.loadAnchor(
            connectionID: connectionID, path: entry.path, isEpub: isEpub,
            fileSize: entry.size, modTime: entry.modTime
        )
        var anchor = saved
        if let saved, !saved.fingerprintMatches(fileSize: entry.size, modTime: entry.modTime) {
            if saved.sizeMatches(entry.size) {
                // 仅 mtime 差异（服务端精度/时区漂移）：锚点依然可用，不重置
                AppLogger.shared.log(
                    "指纹差异仅 modTime（size 一致），继续使用锚点",
                    level: .warn, module: "novel-reader"
                )
            } else if saved.hasStructure {
                // 文件被替换/编辑：结构锚点 + 内容片段仍可重定位，降级为“大致位置”而非清零
                AppLogger.shared.log(
                    "文件指纹变化（size \(saved.fileSize) → \(entry.size)），按内容片段恢复位置",
                    level: .warn, module: "novel-reader"
                )
                showToast("文件已更新，已按大致位置恢复")
            } else {
                anchor = nil
                showToast("文件已更新，进度已重置")
            }
        }
        // 清理上一次加载遗留的待定位信息（重试/换书时避免误用）
        pendingTxtLocator = nil
        gatedVisibleChapter = nil
        gatedVisibleCharOffset = nil
        do {
            if isEpub {
                try await loadEpub(adapter: adapter, anchor: anchor)
            } else {
                try await loadTxt(adapter: adapter, anchor: anchor)
            }
            state = .ready
            AppLogger.shared.log(
                "加载完成 state=ready chapter=\(chapter) toc=\(toc.count) comicLike=\(comicLikePrompt)",
                module: "novel-reader"
            )
            applyReaderBrightness()
        } catch is CancellationError {
            // 退出时取消，不报错
            AppLogger.shared.log("加载取消（退出/切换）", module: "novel-reader")
        } catch {
            AppLogger.shared.log(
                "加载失败: error=\(error) desc=\(error.localizedDescription)",
                level: .error, module: "novel-reader"
            )
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
        AppLogger.shared.log(
            "txt 索引完成: 章节数=\(index.chapters.count) fileSize=\(index.fileSize)",
            module: "novel-reader"
        )
        // 章节磁盘缓存键与索引同源（索引指纹）：在线与 entry 一致，离线回退缓存索引时键自洽
        cacheIdentity = SegmentCache.FileIdentity(
            connectionID: connectionID,
            path: entry.path,
            size: index.fileSize,
            modTime: index.modTime.timeIntervalSince1970
        )
        toc = index.chapters.enumerated().map { NovelTocEntry(id: $0, title: $1.title) }

        // 一步定位：结构锚点（章号 + 标题双重校验）→ 旧字节锚点二分反查 → 百分比兜底
        let targetChapter = resolveTxtChapter(anchor, index: index)
        // 越界前置日志：chapters[targetChapter] 若 targetChapter 越界会 fatalError 闪退，崩前留痕
        AppLogger.shared.log(
            "txt 定位: 锚点章=\(anchor?.chapterIndex ?? -1) 标题=\"\(anchor?.chapterTitle ?? "无")\" legacy=\(anchor?.isLegacyByteOffset ?? false) targetChapter=\(targetChapter) chapters.count=\(index.chapters.count)",
            module: "novel-reader"
        )
        let loaded = try await loadChapter(targetChapter)
        chapter = targetChapter
        txtChapter = loaded.txtChapter
        blocks = loaded.blocks
        // 章内字符位置：结构锚点直接取用；旧字节锚点用行表做一次性迁移（不重编码）
        var hint = anchor?.chapterCharOffset ?? 0
        if let anchor, anchor.isLegacyByteOffset {
            let chapterStart = index.chapters[targetChapter].startOffset
            hint = txtByteOffsetToCharOffset(max(0, anchor.offset - chapterStart))
            AppLogger.shared.log(
                "txt 旧字节锚点迁移 offset=\(anchor.offset) → 章内字符=\(hint)",
                module: "novel-reader"
            )
        }
        lastAnchorCharOffset = max(0, hint)
        // 片段/段号级精确落位依赖分页产物的文本与块位置映射，延后到首次分页完成（见 repaginate 回调）
        if let anchor, !anchor.isLegacyByteOffset {
            pendingTxtLocator = PendingTxtLocator(
                chapterCharOffset: anchor.chapterCharOffset,
                paragraphIndex: anchor.paragraphIndex,
                offsetInParagraph: anchor.characterOffset,
                fragment: anchor.textAfter
            )
        }
    }

    /// txt 锚点 → 目标章序号
    /// 1) 章号 + 标题双重校验（分章规则变化时章号语义会变，标题不一致则以标题为准）；
    /// 2) 标题全局查找；3) 旧字节锚点二分反查（编码无关）；4) 百分比兜底
    private func resolveTxtChapter(_ anchor: NovelAnchor?, index: TxtNovelIndexer.IndexData) -> Int {
        let count = index.chapters.count
        guard count > 0 else { return 0 }
        guard let anchor else { return 0 }
        if let ci = anchor.chapterIndex, index.chapters.indices.contains(ci) {
            let title = anchor.chapterTitle ?? ""
            if title.isEmpty || index.chapters[ci].title == title {
                return ci
            }
            if let hit = index.chapters.firstIndex(where: { $0.title == title }) {
                AppLogger.shared.log(
                    "txt 章号校验失败（章号=\(ci) 标题=\"\(title)\"）→ 按标题重定位到 \(hit)",
                    level: .warn, module: "novel-reader"
                )
                return hit
            }
        } else if let title = anchor.chapterTitle, !title.isEmpty,
                  let hit = index.chapters.firstIndex(where: { $0.title == title }) {
            return hit
        }
        if anchor.isLegacyByteOffset {
            return index.chapterIndex(forOffset: max(0, min(anchor.offset, index.fileSize - 1)))
        }
        if let percent = anchor.percent {
            return max(0, min(Int(percent * Double(count)), count - 1))
        }
        return 0
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
        AppLogger.shared.log(
            "epub 解包完成: spine=\(book.spine.count) toc=\(book.toc.count) isComicLike=\(book.isComicLike)",
            module: "novel-reader"
        )
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

        // 一步定位：spine（章号 + 标题校验）→ 段落序号/段内偏移 → 组装文本字符位置
        var targetSpine = max(0, min(anchor?.chapterIndex ?? anchor?.spineIndex ?? 0, book.spine.count - 1))
        if let anchor, let ci = anchor.chapterIndex, book.toc.indices.contains(ci),
           let title = anchor.chapterTitle, !title.isEmpty, book.toc[ci].title != title,
           let hit = book.toc.firstIndex(where: { $0.title == title }) {
            AppLogger.shared.log(
                "epub 章号校验失败（章号=\(ci) 标题=\"\(title)\"）→ 按标题重定位 spine=\(book.toc[hit].spineIndex)",
                level: .warn, module: "novel-reader"
            )
            targetSpine = max(0, min(book.toc[hit].spineIndex, book.spine.count - 1))
        } else if let percent = anchor?.percent, anchor?.chapterIndex == nil, book.spine.count > 0 {
            targetSpine = max(0, min(Int(percent * Double(book.spine.count)), book.spine.count - 1))
        }
        AppLogger.shared.log(
            "epub 定位 targetSpine=\(targetSpine) spine.count=\(book.spine.count) 标题=\"\(anchor?.chapterTitle ?? "无")\"",
            module: "novel-reader"
        )
        let loaded = try await loadChapter(targetSpine)
        chapter = targetSpine
        blocks = loaded.blocks
        txtChapter = nil
        // 段落/片段锚点依赖分页产物的块位置映射，延迟到首次分页完成时换算（见 repaginate 回调）
        if let anchor {
            pendingTxtLocator = PendingTxtLocator(
                chapterCharOffset: anchor.chapterCharOffset,
                paragraphIndex: anchor.paragraphIndex,
                offsetInParagraph: anchor.characterOffset,
                fragment: anchor.textAfter
            )
        }
    }

    /// 待落位的锚点（txt / epub 通用）：分页产物就绪后按「片段搜索 → 段号换算 → hint」依次尝试
    private struct PendingTxtLocator {
        let chapterCharOffset: Int?
        let paragraphIndex: Int
        let offsetInParagraph: Int
        let fragment: String?
    }

    private var pendingTxtLocator: PendingTxtLocator?

    /// 重排闸门期间用户实际看到的内容（章 + 章内字符位置）。
    /// 页号会随排版失效，字符坐标与排版无关，重排完成后可按它精确恢复位置。
    private var gatedVisibleChapter: Int?
    private var gatedVisibleCharOffset: Int?

    /// 滚动模式：视口顶部的连续字符位置（行映射换算，取代「页首」的页块粒度上报基准）。
    /// 由 View 的滚动回调持续更新；仅在同章且落在本章文本范围内时被上报采用。
    private var scrollTopCharOffset: (chapter: Int, offset: Int)?

    /// 排版失效闸门截止时间：重排窗口内忽略滚动可见页回写。
    /// 用时间戳而非布尔量，避免分页任务被取消/降代后闸门永久卡死（滚动回写彻底失效）。
    private var paginationGateUntil: Date?
    private var isPaginationGated: Bool {
        guard let until = paginationGateUntil else { return false }
        return Date() < until
    }

    /// 使分页产物失效（尺寸/字号变化）：清缓存 + 开闸门 + 递增代数丢弃在途结果。
    /// 注意不清 gatedVisible*：连续拖动字号时若每次都清，闸门期间用户滚到的位置会被丢掉；
    /// 跨书污染由 performLoad 显式清理 + 消费时的 toc 越界校验双重兜底。
    private func invalidatePagination() {
        paginationGateUntil = Date().addingTimeInterval(1.5)
        paginationCache.removeAll()
        paginationGeneration += 1
        scrollTopCharOffset = nil   // 旧排版的连续位置随之失效（重排后由可见页回调重建）
    }

    // MARK: - 分页（View 报告可用尺寸后触发）

    func paginateIfNeeded(size: CGSize) {
        guard size.width > 20, size.height > 20, size != pageSize, !blocks.isEmpty else { return }
        let preserved = pageSize == .zero ? lastAnchorCharOffset : currentCharOffset()
        pageSize = size
        invalidatePagination()   // 尺寸变化：预分页结果失效，重排窗口内忽略滚动回写
        repaginate(anchorCharOffset: preserved)
    }

    /// 设置（字号/行距等）变化触发的重排：防抖合并。滑块连续拖动时每个 step 都触发
    /// `didSet`，若逐次立即分页会堆积大量整章 CoreText 排版任务 → CPU 打满发热、卡死。
    /// 这里把连续变化合并为最后一次（150ms 窗口内重置计时），只在停顿后分页一次。
    private func repaginatePreservingAnchor() {
        invalidatePagination()   // 字号/行距等变化：预分页结果失效，重排窗口内忽略滚动回写
        let target = currentCharOffset()
        repaginateDebounceTask?.cancel()
        repaginateDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            self.repaginate(anchorCharOffset: target)
        }
    }

    private func repaginate(anchorCharOffset: Int) {
        guard pageSize != .zero, !blocks.isEmpty else {
            paginationGateUntil = nil   // 无排版可做：立即解闸，避免滚动回写被误锁
            return
        }
        let appearance = self.appearance
        let blocks = self.blocks
        let textColor = UIColor(themeSpec.text)
        let size = pageSize
        let chapterSnapshot = chapter
        // 取消上一次未完成的分页任务：并发堆积的分页任务是发热/卡死根源。
        // 用代数校验丢弃过期结果，避免旧字号的分页覆盖最新设置。
        paginationTask?.cancel()
        paginationGeneration += 1
        let generation = paginationGeneration
        AppLogger.shared.log(
            "repaginate 开始 chapter=\(chapterSnapshot) blocks=\(blocks.count) size=\(Int(size.width))x\(Int(size.height)) gen=\(generation) anchor=\(anchorCharOffset)",
            module: "novel-reader"
        )
        // 排版放后台，避免大章阻塞主线程
        paginationTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            let result = TextPaginator.paginate(
                blocks: blocks, appearance: appearance, pageSize: size, textColor: textColor
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !Task.isCancelled,
                      generation == self.paginationGeneration,
                      self.chapter == chapterSnapshot else { return }
                self.pagination = result
                self.paginationCache[chapterSnapshot] = result
                self.paginationGateUntil = nil   // 新分页就绪，恢复滚动可见页回写
                AppLogger.shared.log(
                    "repaginate 完成 chapter=\(chapterSnapshot) 页数=\(result.pages.count) 文本长度=\(result.attributedText.length)",
                    module: "novel-reader"
                )
                var offset = anchorCharOffset
                // 首次定位：片段内容搜索 → 段号换算 → 章内字符 hint（见 resolvePendingLocator）
                if let pending = self.pendingTxtLocator {
                    offset = self.resolvePendingLocator(pending, pagination: result)
                    self.pendingTxtLocator = nil
                }
                let maxOffset = max(result.attributedText.length - 1, 0)
                self.page = result.pageIndex(forCharOffset: min(offset, maxOffset))
                // 重排窗口内用户仍在滚动：按记住的字符坐标恢复可见位置（内容优先于重排前的页号）
                if let gatedChapter = self.gatedVisibleChapter, self.toc.indices.contains(gatedChapter),
                   let gatedOffset = self.gatedVisibleCharOffset {
                    self.gatedVisibleChapter = nil
                    self.gatedVisibleCharOffset = nil
                    if gatedChapter == self.chapter {
                        self.page = result.pageIndex(forCharOffset: min(gatedOffset, maxOffset))
                    } else if self.activateChapter(gatedChapter), let pag = self.pagination {
                        self.page = pag.pageIndex(
                            forCharOffset: min(gatedOffset, max(pag.attributedText.length - 1, 0))
                        )
                    }
                }
                if self.appearance.pageMode == .scrolling {
                    self.rebuildScrollStream(anchorPage: self.page)
                }
            }
        }
    }

    /// 待落位锚点 → 章内字符位置：
    /// 片段搜索（抗编码变化/重排/分章微调/轻微编辑）→ 段号+段内偏移 → 章内偏移 hint
    private func resolvePendingLocator(_ pending: PendingTxtLocator, pagination: ChapterPagination) -> Int {
        let hint = pending.chapterCharOffset ?? pagination.charOffset(
            forParagraph: pending.paragraphIndex,
            offsetInParagraph: pending.offsetInParagraph,
            blocks: blocks
        )
        if let fragment = pending.fragment, !fragment.isEmpty {
            if let found = pagination.charOffset(forLocatorFragment: fragment, hint: hint) {
                AppLogger.shared.log(
                    "txt 片段重定位命中 hint=\(hint) found=\(found) 片段长度=\(fragment.count)",
                    module: "novel-reader"
                )
                return found
            }
            AppLogger.shared.log(
                "txt 片段重定位未命中，退化到段号/hint=\(hint) 片段=\"\(fragment.prefix(12))\"",
                level: .warn, module: "novel-reader"
            )
        }
        return max(0, hint)
    }

    /// 设置程序滚动目标并在滚动窗口期后自动清除（期间忽略可见页回写）
    private func armScrollIntent(_ target: String?) {
        scrollIntent = target
        scrollIntentRevision += 1
        // 程序滚动期间可见页回调被抑制：清空旧连续位置，避免落位前的上报沿用上一处位置
        scrollTopCharOffset = nil
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
        AppLogger.shared.log(
            "goToChapter target=\(target) toLastPage=\(toLastPage) 当前chapter=\(chapter) toc=\(toc.count)",
            module: "novel-reader"
        )
        guard toc.indices.contains(target), target != chapter || pagination == nil else { return }
        report(force: true)
        // 命中预分页缓存直接切换上下文并重建滚动流，不闪「章节加载中」加载画面
        if let cachedPagination = paginationCache[target],
           let cached = chapterCache[target] {
            chapter = target
            page = toLastPage ? max(0, cachedPagination.pages.count - 1) : 0
            txtChapter = cached.txtChapter
            blocks = cached.blocks
            pagination = cachedPagination
            chapterLoading = false
            if appearance.pageMode == .scrolling {
                rebuildScrollStream(anchorPage: page)
            }
            reportThrottled()
            checkFinished()
            return
        }
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
                // toLastPage 用超大锚点定位到末页（repaginate 内 min(offset, maxOffset) 收敛）
                repaginate(anchorCharOffset: toLastPage ? Int.max : 0)
            } catch is CancellationError {
            } catch {
                chapterLoading = false
                showToast("章节加载失败：\(error.localizedDescription)")
            }
        }
    }

    /// 滚动模式上报可见页（多章节连续页流；程序滚动期间不回写）
    func scrollVisiblePage(_ p: ScrollPage) {
        guard appearance.pageMode == .scrolling else { return }
        guard scrollIntent == nil else { return }
        // 重排窗口（字号/尺寸变化已清空预分页缓存）内不回写 page（旧页号在新排版下无意义），
        // 但把可见内容换算成排版无关的字符坐标记住，重排完成后据此恢复，避免这段滚动被丢弃
        guard !isPaginationGated else {
            rememberVisibleContent(p)
            return
        }
        if p.chapter != chapter {
            // 上下文未就绪必须整帧丢弃：否则 page 会带着新章页码留在旧章 → 锚点错位
            guard activateChapter(p.chapter) else {
                AppLogger.shared.log(
                    "scrollVisiblePage 丢弃回写：章上下文未就绪 target=\(p.chapter) 当前=\(chapter) page=\(p.page)",
                    level: .warn, module: "novel-reader"
                )
                return
            }
        }
        if p.page != page {
            page = p.page
        }
        // 滚动到流边界附近：预分页并增量拼入更远的章节，实现双向无缝
        if let last = scrollStream.last, p.chapter == last.chapter, p.page >= last.page - 1 {
            prepaginate(last.chapter + 1)
        }
        if let first = scrollStream.first, p.chapter == first.chapter, p.page <= 0 {
            prepaginate(first.chapter - 1)
        }
        reportThrottled()
        checkFinished()
    }

    /// 滚动模式：滚动到底（兜底）预分页下一章；正常扩展由 scrollVisiblePage 驱动
    func scrollReachEnd(_ reachEnd: Bool) {
        guard appearance.pageMode == .scrolling else { return }
        guard reachEnd, scrollIntent == nil, !chapterLoading else { return }
        if let last = scrollStream.last, last.chapter + 1 < toc.count {
            prepaginate(last.chapter + 1)
        }
    }

    /// 滚动模式：滚动到顶（兜底）预分页上一章；正常扩展由 scrollVisiblePage 驱动
    func scrollReachTop(_ reachTop: Bool) {
        guard appearance.pageMode == .scrolling else { return }
        guard reachTop, scrollIntent == nil, !chapterLoading else { return }
        if let first = scrollStream.first, first.chapter - 1 >= 0 {
            prepaginate(first.chapter - 1)
        }
    }

    /// 滚动模式：预分页下一章（后台分页后缓存，翻章时直接切换实现无缝续读）
    private func prepaginate(_ target: Int) {
        guard appearance.pageMode == .scrolling else { return }
        guard toc.indices.contains(target), paginationCache[target] == nil,
              !paginatingInFlight.contains(target), pageSize != .zero else { return }
        paginatingInFlight.insert(target)
        let appearance = self.appearance
        let textColor = UIColor(themeSpec.text)
        let size = pageSize
        let targetChapter = target
        Task { [weak self] in
            guard let self else { return }
            defer { self.paginatingInFlight.remove(targetChapter) }
            guard let loaded = try? await self.loadChapter(targetChapter) else { return }
            let blocks = loaded.blocks
            // 分页放后台，避免大章阻塞主线程
            let result = await Task.detached(priority: .userInitiated) {
                TextPaginator.paginate(
                    blocks: blocks, appearance: appearance, pageSize: size, textColor: textColor
                )
            }.value
            // 设置/尺寸在分页期间变化则丢弃过期结果
            guard self.appearance == appearance, self.pageSize == size else { return }
            self.paginationCache[targetChapter] = result
            // LRU：保留当前 ±2、刚分页完成的章、滚动流正在渲染的章节。
            // targetChapter 必须显式保留：它尚未拼入滚动流，只按“当前章 ±2”过滤会被自己立刻淘汰，
            // 导致 insertChapterIntoStream 取不到分页、滚动流无法延伸（并诱发 chapter/page 错位）
            var keep: Set<Int> = [
                targetChapter,
                self.chapter - 2, self.chapter - 1, self.chapter, self.chapter + 1, self.chapter + 2,
            ]
            keep.formUnion(self.scrollStream.map(\.chapter))
            self.paginationCache = self.paginationCache.filter { keep.contains($0.key) }
            guard self.paginationCache[targetChapter] != nil else {
                AppLogger.shared.log(
                    "prepaginate 结果被 LRU 淘汰 target=\(targetChapter) chapter=\(self.chapter)",
                    level: .warn, module: "novel-reader"
                )
                return
            }
            // 增量拼入滚动流（向下追加 / 向上插入并补偿滚动位置）
            self.insertChapterIntoStream(targetChapter)
        }
    }

    /// 滚动模式点击分区翻页：先改页码，View 层 ScrollViewReader 消费 scrollIntent 滚动
    func requestScroll(to target: Int) {
        guard appearance.pageMode == .scrolling, pagination != nil else { return }
        if target < 0 || target >= pageCount {
            goToPage(target)   // 越界 → 切章
            return
        }
        page = target
        armScrollIntent(ScrollPage(chapter: chapter, page: target).id)
        reportThrottled()
        checkFinished()
    }

    // MARK: - 滚动模式连续页流（多章节无缝拼接）

    /// 取某页对应的分页产物（当前章走 pagination，其余走预分页缓存）
    private func paginationFor(_ p: ScrollPage) -> ChapterPagination? {
        if p.chapter == chapter, let pagination { return pagination }
        return paginationCache[p.chapter]
    }

    /// 重排窗口内记录可见内容（章 + 章内字符位置）。
    /// 旧页号在新排版下失效，但字符坐标与排版无关，重排完成后可直接定位；否则闸门期间
    /// 的滚动会被整个丢弃 → 恢复出的位置比用户实际停留处偏前。
    /// - Parameter charOffset: 行映射换算的连续位置（nil 时退回当前页页首）
    private func rememberVisibleContent(_ p: ScrollPage, charOffset: Int? = nil) {
        guard let pag = paginationFor(p), pag.pages.indices.contains(p.page) else { return }
        gatedVisibleChapter = p.chapter
        gatedVisibleCharOffset = charOffset ?? pag.pages[p.page].lowerBound
    }

    /// 滚动模式：「视口顶部所在页 + 页内纵向偏移」→ 连续字符位置（行映射，行级精度）。
    /// 与 `scrollVisiblePage`（页粒度：当前页 / 预分页扩展）分工，这里只更新上报基准：
    /// 页内滚动不跨页也能推进进度，页块离散化带来的累计误差不再按页放大。
    /// - Parameters:
    ///   - offsetY: 视口顶部相对页块顶部的纵向偏移（点）；页块顶部在视口下方时传 0
    ///   - pageHeight: 页块渲染高度（无行映射时的插值分母）
    func scrollVisibleTop(page: ScrollPage, offsetY: CGFloat, pageHeight: CGFloat) {
        guard appearance.pageMode == .scrolling else { return }
        guard scrollIntent == nil else { return }
        guard let pag = paginationFor(page), pag.pages.indices.contains(page.page) else { return }
        let offset = pag.charOffset(inPage: page.page, offsetY: offsetY, pageHeight: pageHeight)
        guard !isPaginationGated else {
            // 重排窗口：页号已失效但字符坐标有效，记下供重排完成后恢复
            rememberVisibleContent(page, charOffset: offset)
            return
        }
        scrollTopCharOffset = (chapter: page.chapter, offset: offset)
    }

    /// 取滚动流中某页的富文本内容
    func scrollPageContent(_ p: ScrollPage) -> NSAttributedString {
        if p.chapter == chapter, let pagination, pagination.pages.indices.contains(p.page) {
            return pagination.pageContent(p.page)
        }
        guard let pag = paginationCache[p.chapter], pag.pages.indices.contains(p.page) else {
            return NSAttributedString()
        }
        return pag.pageContent(p.page)
    }

    /// 重建滚动页流：把当前章及已缓存相邻章节拼成连续列表，并定位到锚点页
    private func rebuildScrollStream(anchorPage: Int) {
        guard appearance.pageMode == .scrolling else { return }
        var stream: [ScrollPage] = []
        var c = chapter
        while c >= 0 {
            let pag = (c == chapter) ? pagination : paginationCache[c]
            guard let pag else { break }
            stream.insert(contentsOf: (0..<pag.pages.count).map { ScrollPage(chapter: c, page: $0) }, at: 0)
            c -= 1
        }
        c = chapter + 1
        while c < toc.count, let pag = paginationCache[c] {
            stream.append(contentsOf: (0..<pag.pages.count).map { ScrollPage(chapter: c, page: $0) })
            c += 1
        }
        scrollStream = stream
        armScrollIntent(ScrollPage(chapter: chapter, page: anchorPage).id)
        prepaginate(chapter - 1)
        prepaginate(chapter + 1)
    }

    /// 把某章（已分页缓存）增量拼入滚动流：向下追加 / 向上插入并补偿滚动位置
    private func insertChapterIntoStream(_ chapterIndex: Int) {
        guard appearance.pageMode == .scrolling,
              let pag = paginationCache[chapterIndex] else { return }
        let pages = (0..<pag.pages.count).map { ScrollPage(chapter: chapterIndex, page: $0) }
        let existing = Set(scrollStream.map(\.id))
        let newPages = pages.filter { !existing.contains($0.id) }
        guard !newPages.isEmpty else { return }
        if let first = scrollStream.first, chapterIndex < first.chapter {
            scrollStream.insert(contentsOf: newPages, at: 0)
            if scrollIntent == nil {
                armScrollIntent(first.id)
            }
        } else if let last = scrollStream.last, chapterIndex > last.chapter {
            scrollStream.append(contentsOf: newPages)
        } else {
            // 中间补章（stream 应保持连续，此分支为防御）：按位置插入保持有序，
            // 避免全量 sort 触发 LazyVStack 大面积重建与视觉跳动。
            if let insertAt = scrollStream.firstIndex(where: { $0.chapter > chapterIndex }) {
                scrollStream.insert(contentsOf: newPages, at: insertAt)
            } else {
                scrollStream.append(contentsOf: newPages)
            }
        }
    }

    /// 滚动跨章时切换当前章上下文（更新进度基准，不动滚动流）。
    /// 返回 false = 上下文未就绪（缓存缺失/越界），调用方必须丢弃本次回写：
    /// 否则 chapter 与 page 分属两章，currentCharOffset / 行表用错章 → 写库锚点错位（漂移主因）。
    @discardableResult
    private func activateChapter(_ target: Int) -> Bool {
        guard toc.indices.contains(target) else { return false }
        guard target != chapter else { return true }
        guard let cached = chapterCache[target], let pag = paginationCache[target] else {
            AppLogger.shared.log(
                "activateChapter 上下文未就绪 target=\(target) chapterCache=\(chapterCache[target] != nil) paginationCache=\(paginationCache[target] != nil)，已触发预分页",
                level: .warn, module: "novel-reader"
            )
            prepaginate(target)   // 补齐后下一帧可见页回调即可正常切换
            return false
        }
        report(force: true)
        chapter = target
        txtChapter = cached.txtChapter
        blocks = cached.blocks
        pagination = pag
        // page 立即收敛到新章范围，防止切换瞬间的强制上报读到越界页
        page = min(page, max(pag.pages.count - 1, 0))
        chapterLoading = false
        prepaginate(target - 1)
        prepaginate(target + 1)
        return true
    }

    // MARK: - 章节加载（缓存 ±1 预加载）

    private func loadChapter(_ target: Int) async throws -> LoadedChapter {
        if let cached = chapterCache[target] { return cached }
        AppLogger.shared.log(
            "loadChapter target=\(target) isEpub=\(isEpub) toc=\(toc.count)",
            module: "novel-reader"
        )
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
            // 越界前置日志：chapters[target] 若 target 越界会 fatalError 闪退，崩前留痕
            AppLogger.shared.log(
                "loadChapter txt 取标题: target=\(target) chapters.count=\(txtIndex.chapters.count) lines=\(chapterText.lines.count)",
                module: "novel-reader"
            )
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
                // LRU：保留当前 ±1；滚动模式下额外保留连续页流正在渲染的章节。
                // chapterCache 必须与 paginationCache 的保留范围对齐，否则跨章回滚时
                // activateChapter 因 blocks/txtChapter 缺失而失败，导致 chapter 与 page 错位。
                var keep: Set<Int> = [target - 1, target, target + 1]
                keep.formUnion(self.scrollStream.map(\.chapter))
                self.chapterCache = self.chapterCache.filter { keep.contains($0.key) }
            }
        }
    }

    // MARK: - 进度上报

    /// 当前阅读位置（章内字符位置）：滚动模式优先取行映射换算的视口顶部连续位置，
    /// 无有效连续位置时退回当前页页首（页块粒度）。
    private func currentCharOffset() -> Int {
        guard let pagination, pagination.pages.indices.contains(page) else { return 0 }
        if appearance.pageMode == .scrolling, let top = scrollTopCharOffset,
           top.chapter == chapter, top.offset >= 0,
           top.offset < max(pagination.attributedText.length, 1) {
            return top.offset
        }
        return pagination.pages[page].lowerBound
    }

    private func makeAnchor() -> NovelAnchor {
        let charOffset = currentCharOffset()
        // 结构锚点：段号 + 段内偏移（与排版无关）；片段用于下次按内容重定位
        let para = pagination?.paragraphAnchor(forCharOffset: charOffset, blocks: blocks)
            ?? (paragraph: 0, offsetInParagraph: 0)
        let snippet = pagination?.locatorSnippet(from: charOffset)
        // 越界前置日志：chapters[chapter] 若 chapter 越界会 fatalError 闪退，崩前留痕
        if let txtIndex, !txtIndex.chapters.indices.contains(chapter) {
            AppLogger.shared.log(
                "makeAnchor 章节越界 chapter=\(chapter) chapters.count=\(txtIndex.chapters.count)",
                level: .warn, module: "novel-reader"
            )
        }
        if isEpub {
            return NovelAnchor.epub(
                spineIndex: chapter, chapterTitle: currentChapterTitle,
                paragraphIndex: para.paragraph, offsetInParagraph: para.offsetInParagraph,
                chapterCharOffset: charOffset, textAfter: snippet, percent: currentPercent,
                fileSize: entry.size, modTime: entry.modTime
            )
        }
        return NovelAnchor.txt(
            chapterIndex: chapter, chapterTitle: currentChapterTitle,
            paragraphIndex: para.paragraph, offsetInParagraph: para.offsetInParagraph,
            chapterCharOffset: charOffset, textAfter: snippet, percent: currentPercent,
            fileSize: entry.size, modTime: entry.modTime
        )
    }

    /// 旧版字节锚点迁移：章内字节偏移 → 组装文本字符位置（行表定位，**不做行内重编码**）
    /// 编码不可逆（无法表示的字符、有损回退的替换符）正是历史漂移根因，这里只用到行字节边界，
    /// 精度落在行首（一行 ≈ 40 字，不足一屏），一次性迁移后即升级为结构锚点。
    private func txtByteOffsetToCharOffset(_ byteOffset: Int64) -> Int {
        guard let chapterText = txtChapter, !chapterText.lines.isEmpty else { return 0 }
        var lineIndex = 0
        for (index, line) in chapterText.lines.enumerated()
        where line.byteRange.lowerBound <= byteOffset {
            lineIndex = index
        }
        var charOffset = 0
        for prior in 0..<lineIndex {
            charOffset += chapterText.lines[prior].text.utf16.count + 1
        }
        return charOffset
    }

    private var currentPercent: Double {
        let total = max(toc.count, 1)
        let inChapter = pageCount > 0 ? Double(page) / Double(pageCount) : 0
        return min(1, max(0, (Double(chapter) + inChapter) / Double(total)))
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
        paginationTask?.cancel()
        repaginateDebounceTask?.cancel()
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
    /// 使用 ChapterPagination 构建时预切片的缓存，避免 UI 每帧重建时反复深拷贝整章文本
    func pageContent(_ target: Int) -> NSAttributedString {
        guard let pagination else { return NSAttributedString() }
        return pagination.pageContent(target)
    }

    /// 供 View 层展示一次性提示（如底栏拖动跳章后的 toast）
    func flashToast(_ message: String) {
        showToast(message)
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
