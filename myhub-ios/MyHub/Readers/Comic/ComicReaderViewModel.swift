import Foundation
import SwiftUI

/// 漫画阅读模式（IOS-207）：单页 / 双页（可切换方向）/ 条漫（纵向连续滚动）。
/// 默认条漫，用户切换后经 `AppSettings.Reader.comicMode` 持久化。
enum ComicReadMode: String, CaseIterable {
    case single, double, webtoon

    var displayName: String {
        switch self {
        case .single: return "单页"
        case .double: return "双页"
        case .webtoon: return "条漫"
        }
    }

    var symbol: String {
        switch self {
        case .single: return "rectangle.portrait"
        case .double: return "rectangle.split.2x1"
        case .webtoon: return "scroll"
        }
    }
}

/// 漫画阅读器状态机（TODO §6）：
/// - 加载：打开归档列页（远程 rar 先下载临时文件，带进度）；**历史页码直接恢复，不从第一页开始**；
/// - 页面：内存 LRU 缓存 + ±3 预加载（正向翻页前向优先，反向后向优先，最多并发 3）；
/// - 进度：3s 节流 + 翻页/退出强制上报（`ComicProgressStore`，文件指纹校验）；
/// - 翻完推荐下一本（同目录同类型，按浏览排序偏好）。
@MainActor
final class ComicReaderViewModel: ObservableObject {

    enum State: Equatable {
        case opening(Double?)   // 打开归档中；远程 rar 下载进度 0~1，nil = 解析归档
        case ready
        case failed(String)
    }

    let connection: Connection
    let entry: FileEntry

    @Published private(set) var state: State = .opening(nil)
    @Published private(set) var pageCount = 0
    /// 当前页（单页/条漫）或当前双页组首页（双页模式）
    @Published private(set) var page = 0
    /// 条漫恢复定位中（true 时禁止可见页回写覆盖恢复页；onAppear 前 LazyVStack 顶部布局可能提前触发回写）
    @Published private(set) var isRestoring = false
    /// 已解码页面（内存缓存，LRU 上限约 12 页）
    @Published private(set) var images: [Int: UIImage] = [:]
    /// 每页宽高比（高/宽，随解码记录并持久化；条漫占位用真实高度，恢复定位精确）
    @Published private(set) var pageRatios: [Int: CGFloat] = [:]
    /// 当前页内阅读偏移（0=页顶；条漫可见页回写持续更新，恢复定位精确到页内位置）
    /// 非 @Published：视图不直接渲染，仅恢复/保存时读取，避免滚动期高频刷新
    private(set) var pageOffset: Float = 0
    @Published var toast: String?

    /// 未知宽高比页的估计值：已知页中位数（同卷漫画页尺寸通常一致，远优于固定 420 占位）
    var fallbackRatio: CGFloat? {
        guard !pageRatios.isEmpty else { return nil }
        let sorted = pageRatios.values.sorted()
        return sorted[sorted.count / 2]
    }

    /// 阅读模式（持久化；默认条漫，用户切换后记忆）
    @Published var mode: ComicReadMode {
        didSet { AppSettings.Reader.comicMode = mode }
    }
    /// 双页阅读方向（持久化；auto 时按设备形态解析）
    @Published var direction: ComicReadingDirection {
        didSet { AppSettings.Reader.comicDirection = direction }
    }

    /// 翻完推荐下一本（IOS-208）
    @Published private(set) var nextCandidate: FileEntry?

    /// 缩略图（IOS-210 控制层重设计·缩略图面板）：小尺寸解码缓存，LRU 上限 48 张
    @Published private(set) var thumbnails: [Int: UIImage] = [:]

    private let adapter: StorageAdapter?
    private var source: ComicPageSource?
    /// 页磁盘缓存身份（在线：entry 指纹；离线：缓存反查身份，IOS-605）
    private var cacheIdentity: SegmentCache.FileIdentity?
    private var loadTask: Task<Void, Never>?
    private var pageTasks: [Int: Task<UIImage?, Never>] = [:]
    private var thumbTasks: [Int: Task<UIImage?, Never>] = [:]
    /// 缩略图 LRU 顺序（插入序，超限逐出最早）
    private var thumbnailOrder: [Int] = []
    private var reportTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var nextTask: Task<Void, Never>?
    private var ratioSaveTask: Task<Void, Never>?
    private var coverKey: String?
    /// 上次翻页方向（预加载前向/后向优先）
    private var lastForward = true
    /// 进入阅读器前的系统亮度（-1 = 未记录；退出时恢复，与小说阅读器一致）
    private var systemBrightness: CGFloat = -1

    init(connection: Connection, entry: FileEntry) {
        self.connection = connection
        self.entry = entry
        self.adapter = try? AdapterFactory.makeAdapter(for: connection)
        self.direction = AppSettings.Reader.comicDirection
        self.mode = AppSettings.Reader.comicMode
    }

    deinit {
        loadTask?.cancel()
        pageTasks.values.forEach { $0.cancel() }
        thumbTasks.values.forEach { $0.cancel() }
        reportTask?.cancel()
        toastTask?.cancel()
        nextTask?.cancel()
        // 兜底释放归档资源（远程 rar 临时文件）：正常路径由 teardown() 释放，
        // 若视图未触发 onDisappear 便释放，避免临时文件残留占盘
        source?.close()
        source = nil
    }

    // MARK: - 加载（直接恢复历史页码）

    func load() {
        guard loadTask == nil else { return }
        AppLogger.shared.log(
            "打开漫画: name=\(entry.name) ext=\(entry.ext) size=\(entry.size) path=\(entry.path) conn=\(connectionID)",
            module: "comic-reader"
        )
        loadTask = Task { await performLoad() }
    }

    private func performLoad() async {
        guard let adapter else {
            AppLogger.shared.log("打开失败: adapter=nil（连接不可用）", level: .error, module: "comic-reader")
            state = .failed("连接不可用，请检查连接源配置")
            return
        }
        let identity = ComicPageCache.identity(connectionID: connectionID, entry: entry)
        cacheIdentity = identity

        // 缓存秒开：页名列表已缓存（同指纹，说明之前打开过）→ 立即进入可读状态，
        // 归档在后台补齐，缓存未命中的页回退到归档按需解压，避免每次都重新打开归档。
        if let names = await ComicPageCache.pageList(file: identity), !names.isEmpty {
            AppLogger.shared.log(
                "缓存秒开: pageCount=\(names.count) path=\(entry.path)",
                module: "comic-reader"
            )
            let cached = CachedFirstComicSource(identity: identity, pageNames: names)
            Task { await fillArchiveFallback(for: cached, adapter: adapter) }
            await finishOpen(source: cached, fileSize: entry.size, modTime: entry.modTime)
            return
        }

        // 内网 WebDAV 大文件 Range 读取偶发返回错误响应（非 206）→ ArchiveDecoder.open
        // 偶发 malformed/decompressFailed。失败自动重试一次，避免「打开即失败」需用户手动重试。
        var opened: ComicPageSource?
        var lastError: Error?
        for attempt in 1...2 {
            do {
                opened = try await ArchiveDecoder.open(
                    entry: entry, adapter: adapter, connectionID: connectionID
                ) { [weak self] fraction in
                    Task { @MainActor in self?.state = .opening(fraction) }
                }
                try Task.checkCancellation()
                break
            } catch is CancellationError {
                AppLogger.shared.log("打开取消（退出/切换）", module: "comic-reader")
                return
            } catch {
                lastError = error
                if attempt < 2 {
                    AppLogger.shared.log(
                        "归档打开失败(第\(attempt)次): \(error.localizedDescription)，600ms 后重试",
                        level: .warn, module: "comic-reader"
                    )
                    try? await Task.sleep(nanoseconds: 600_000_000)
                }
            }
        }
        if let opened {
            AppLogger.shared.log(
                "归档打开成功: pageCount=\(opened.pageCount) 首页名=\(opened.pageNames.first ?? "-")",
                module: "comic-reader"
            )
            // 页名列表落盘（下次打开秒开 + 离线打开的结构基础）
            Task.detached(priority: .utility) {
                await ComicPageCache.storePageList(opened.pageNames, file: identity)
            }
            await finishOpen(source: opened, fileSize: entry.size, modTime: entry.modTime)
        } else if let lastError {
            AppLogger.shared.log(
                "归档打开失败: error=\(lastError) desc=\(lastError.localizedDescription)，尝试离线回退",
                level: .warn, module: "comic-reader"
            )
            // IOS-605 离线回退：页名列表 + 解压页已缓存时可离线阅读（远程 rar 整包亦在缓存分区）
            if let offline = await ComicPageCache.offlineSource(
                connectionID: connectionID, path: entry.path
            ) {
                AppLogger.shared.log("离线回退成功: pageCount=\(offline.pageCount)", module: "comic-reader")
                cacheIdentity = offline.identity
                await finishOpen(
                    source: offline,
                    fileSize: offline.identity.size,
                    modTime: Date(timeIntervalSince1970: offline.identity.modTime)
                )
                showToast("离线模式：仅已缓存页面可读")
            } else {
                AppLogger.shared.log(
                    "离线回退失败，最终标记 failed: \(lastError.localizedDescription)",
                    level: .error, module: "comic-reader"
                )
                state = .failed(lastError.localizedDescription)
            }
        }
    }

    /// 缓存秒开后后台补齐归档源：缓存未命中的页回退到归档按需解压，保证完整性。
    private func fillArchiveFallback(for cached: CachedFirstComicSource, adapter: StorageAdapter) async {
        do {
            // 复用已缓存页名，跳过 comicPageNames 遍历 194 个 spine XHTML 的 N+1 Range 请求
            let opened = try await ArchiveDecoder.open(
                entry: entry, adapter: adapter, connectionID: connectionID,
                knownPageNames: cached.pageNames
            )
            try Task.checkCancellation()
            if opened.pageNames == cached.pageNames {
                cached.setFallback(opened)
                AppLogger.shared.log("缓存秒开后归档补齐成功", module: "comic-reader")
            } else {
                opened.close()
                cached.markFallbackFailed()
                AppLogger.shared.log(
                    "缓存秒开后归档页名不一致，丢弃补齐源", level: .warn, module: "comic-reader"
                )
            }
        } catch {
            cached.markFallbackFailed()
            AppLogger.shared.log(
                "缓存秒开后归档补齐失败: \(error.localizedDescription)",
                level: .warn, module: "comic-reader"
            )
        }
    }

    /// 打开完成：进度恢复（首次构建即定位上次页码）+ 封面提取 + 首屏与预加载
    private func finishOpen(source: ComicPageSource, fileSize: Int64, modTime: Date) async {
        self.source = source
        pageCount = source.pageCount

        // 加载已持久化的页宽高比：条漫占位高度=真实高度，恢复定位不被解码膨胀顶偏
        if let identity = cacheIdentity,
           let stored = await ComicPageCache.pageRatios(file: identity) {
            pageRatios = stored.mapValues { CGFloat($0) }
            AppLogger.shared.log(
                "页宽高比已恢复: \(stored.count)/\(source.pageCount)页", module: "comic-reader"
            )
        }

        // 进度恢复：指纹不匹配 → 提示并归零
        let saved = ComicProgressStore.loadAnchor(
            connectionID: connectionID, path: entry.path,
            fileSize: fileSize, modTime: modTime
        )
        if saved.stale { showToast("文件已更新，进度已重置") }
        let restored = min(max(saved.anchor?.page ?? 0, 0), max(source.pageCount - 1, 0))
        page = restored
        // 页内偏移仅条漫模式有意义（翻页模式读整页，恢复即页顶）
        pageOffset = mode == .webtoon ? (saved.anchor?.pageOffset ?? 0) : 0
        // 条漫恢复定位期间禁止可见页回写（LazyVStack 顶部布局可能早于 onAppear 触发回写覆盖 page）
        isRestoring = true
        state = .ready
        AppLogger.shared.log(
            "finishOpen: pageCount=\(source.pageCount) 恢复页码=\(restored) stale=\(saved.stale)",
            module: "comic-reader"
        )

        // 封面缩略图缓存（「正在阅读」封面，异步不阻塞）
        let coverConnectionID = connectionID
        let coverPath = entry.path
        Task.detached(priority: .utility) { [weak self] in
            guard let self, let data = try? await source.pageData(at: 0) else { return }
            let key = ComicProgressStore.cacheCover(
                data: data, connectionID: coverConnectionID, path: coverPath
            )
            await MainActor.run {
                self.coverKey = key
                if let key {
                    ComicProgressStore.updateCover(
                        connectionID: coverConnectionID, path: coverPath, cover: key
                    )
                }
            }
        }

        // 首屏页立即加载 + 预加载窗口
        await loadPage(restored)
        for p in preloadTargets(around: restored) { schedulePage(p) }
    }

    // MARK: - 页面加载（内存 LRU + in-flight 去重，最多并发 3）

    /// 归档解压并发限流：超过上限时挂起于 continuation（替代原 60ms 轮询等待）
    private static let maxConcurrentDecodes = 3
    private var inflightDecodes = 0
    private var decodeWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireDecodeSlot() async {
        if inflightDecodes < Self.maxConcurrentDecodes {
            inflightDecodes += 1
            return
        }
        await withCheckedContinuation { decodeWaiters.append($0) }
    }

    /// 归还名额：有等待者则直接转交（名额不回落，避免唤醒间隙被新任务抢占）
    private func releaseDecodeSlot() {
        if decodeWaiters.isEmpty {
            inflightDecodes -= 1
        } else {
            decodeWaiters.removeFirst().resume()
        }
    }

    private func loadPage(_ index: Int) async {
        guard source != nil, index >= 0, index < pageCount, images[index] == nil else { return }
        if let task = pageTasks[index] {
            _ = await task.value
            return
        }
        // detached：解压 + 下采样在后台线程，不阻塞 UI
        let task = Task.detached(priority: .userInitiated) { [weak self] () -> UIImage? in
            guard let self else { return nil }
            let source = await MainActor.run { self.source }
            guard let source else { return nil }
            // 先查磁盘缓存：命中直接解码返回，不占并发名额、不参与排队。
            // 条漫模式滚动定位会批量触发 loadPage（渲染 index 0~N），若命中页也排队，
            // 全部 task 会卡在并发名额之外、无人执行到缓存读取 → 必须让缓存读取先于 acquireDecodeSlot。
            let identity = await MainActor.run { self.cacheIdentity }
            let pageName = source.pageNames.indices.contains(index) ? source.pageNames[index] : nil
            if let identity, let pageName,
               let cached = await ComicPageCache.page(file: identity, name: pageName) {
                AppLogger.shared.log("单页缓存命中: 第\(index + 1)页 \(pageName)", module: "comic-reader")
                return ImageDownsampler.downsample(data: cached, maxPixel: 2200)
            }
            // 未命中需归档解压（重资源）：并发上限 3，挂起排队（continuation 唤醒，无轮询）
            await self.acquireDecodeSlot()
            if Task.isCancelled {
                await self.releaseDecodeSlot()
                return nil
            }
            AppLogger.shared.log(
                "单页缓存未命中: 第\(index + 1)页 \(pageName ?? "-")，走归档解压",
                module: "comic-reader"
            )
            // 内网 WebDAV 大文件 Range 读取偶发失败（错误响应/连接重置）：
            // 失败自动重试一次，避免单次网络抖动让该页永久停在「加载中」。
            var data: Data?
            let t0 = CFAbsoluteTimeGetCurrent()
            for attempt in 0..<2 {
                if let d = try? await source.pageData(at: index) {
                    data = d
                    break
                }
                if attempt == 0 { try? await Task.sleep(nanoseconds: 300_000_000) }
            }
            // 重活（网络 + 解压）结束即归还名额；后续下采样不再占用解压并发
            await self.releaseDecodeSlot()
            let cost = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            guard let data else {
                AppLogger.shared.log(
                    String(format: "pageData 失败: 第%d页 耗时=%.0fms", index + 1, cost),
                    level: .warn, module: "comic-reader"
                )
                return nil
            }
            AppLogger.shared.log(
                String(format: "pageData 完成: 第%d页 size=%d 耗时=%.0fms", index + 1, data.count, cost),
                module: "comic-reader"
            )
            if let identity, let pageName {
                await ComicPageCache.storePage(data, file: identity, name: pageName)
            }
            return ImageDownsampler.downsample(data: data, maxPixel: 2200)
        }
        pageTasks[index] = task
        if let image = await task.value {
            images[index] = image
            evictIfNeeded(around: index)
            // 记录宽高比（高/宽）：条漫占位用真实高度，下次恢复定位精确
            let ratio = image.size.height / max(image.size.width, 1)
            if pageRatios[index] != ratio {
                pageRatios[index] = ratio
                scheduleRatioPersist()
            }
        } else if !task.isCancelled {
            // 解码返回 nil：页数据拉取失败 / 图片解码失败 —— 表现为该页一直停在占位「加载中」
            let name = source?.pageNames.indices.contains(index) == true ? source?.pageNames[index] ?? "-" : "-"
            AppLogger.shared.log(
                "页面解码失败(返回nil): index=\(index) name=\(name)",
                level: .warn, module: "comic-reader"
            )
        }
        pageTasks[index] = nil
    }

    private func schedulePage(_ index: Int) {
        guard index >= 0, index < pageCount, images[index] == nil, pageTasks[index] == nil else { return }
        Task { await loadPage(index) }
    }

    /// 预加载 ±3：正向翻页前向优先，反向后向优先
    private func preloadTargets(around index: Int) -> [Int] {
        var targets: [Int] = []
        for step in 1...3 {
            let forward = index + step
            let backward = index - step
            targets.append(lastForward ? forward : backward)
            targets.append(lastForward ? backward : forward)
        }
        // 双页模式多带一页（成对显示）
        if mode == .double { targets.append(index + 4); targets.append(index - 4) }
        return targets.filter { $0 >= 0 && $0 < pageCount }
    }

    /// 内存 LRU：仅保留当前 ±6，防大图集撑爆内存
    private func evictIfNeeded(around index: Int) {
        guard images.count > 12 else { return }
        let keep = Set((index - 6)...(index + 6))
        images = images.filter { keep.contains($0.key) }
    }

    // MARK: - 翻页 / 跳转

    /// 切回条漫前标记恢复定位中（防止 LazyVStack 顶部布局提前回写覆盖当前页）
    func beginWebtoonRestore() { isRestoring = true }

    /// 条漫恢复定位完成，交还可见页回写
    func endWebtoonRestore() { isRestoring = false }

    /// 宽高比防抖落盘（解码高峰合并写入）
    private func scheduleRatioPersist() {
        guard ratioSaveTask == nil else { return }
        ratioSaveTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            ratioSaveTask = nil
            if !Task.isCancelled { persistRatios() }
        }
    }

    private func persistRatios() {
        guard let identity = cacheIdentity, !pageRatios.isEmpty else { return }
        let snapshot = pageRatios.mapValues { Float($0) }
        Task.detached(priority: .utility) {
            await ComicPageCache.storePageRatios(snapshot, file: identity)
        }
    }

    func goToPage(_ target: Int) {
        guard state == .ready, pageCount > 0 else { return }
        let clamped = min(max(target, 0), pageCount - 1)
        if clamped != page { lastForward = clamped > page }
        page = clamped
        Task { await loadPage(clamped) }
        for p in preloadTargets(around: clamped) { schedulePage(p) }
        reportThrottled()
        checkFinished()
    }

    /// 条漫可见页回写：持续记录页内偏移，页码变化时走 goToPage（预加载 + 节流上报）
    func updateWebtoonVisible(page visiblePage: Int, offset: Float) {
        guard state == .ready else { return }
        pageOffset = offset
        if visiblePage != page { goToPage(visiblePage) }
    }

    /// 翻页/单页模式读整页：页内偏移归零（切回条漫时定位到页顶，而非残留条漫偏移）
    func resetPageOffset() { pageOffset = 0 }

    func nextPage() { goToPage(page + (mode == .double ? 2 : 1)) }
    func previousPage() { goToPage(page - (mode == .double ? 2 : 1)) }

    /// 条漫模式：页面滚入可见区时按需加载（`loadPage` 自带 in-flight 去重，重复触发无害）。
    func ensureLoaded(_ index: Int) {
        guard state == .ready else { return }
        Task { await loadPage(index) }
    }

    // MARK: - 进度上报

    var currentPercent: Double {
        pageCount > 0 ? Double(page + 1) / Double(pageCount) : 0
    }

    private var isAtEnd: Bool {
        pageCount > 0 && page >= pageCount - 1
    }

    /// 翻页触发：3s 节流上报
    func reportThrottled() {
        guard reportTask == nil else { return }
        reportTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            reportTask = nil
            if !Task.isCancelled { reportNow() }
        }
    }

    /// 立即上报（退出 / 翻完）
    func report(force: Bool) {
        reportTask?.cancel()
        reportTask = nil
        if force { reportNow() }
    }

    private func reportNow() {
        guard state == .ready, pageCount > 0 else { return }
        ComicProgressStore.save(
            connectionID: connectionID,
            path: entry.path,
            title: (entry.name as NSString).deletingPathExtension,
            anchor: ComicProgressStore.ComicAnchor(
                page: page, fileSize: entry.size,
                modTime: entry.modTime.timeIntervalSince1970,
                pageOffset: pageOffset
            ),
            pageCount: pageCount,
            finished: isAtEnd,
            cover: coverKey
        )
    }

    private func checkFinished() {
        guard isAtEnd else { return }
        report(force: true)
        scheduleNextTip()
    }

    /// 退出阅读器：强制上报 + 释放归档
    func teardown() {
        report(force: true)
        ratioSaveTask?.cancel()
        ratioSaveTask = nil
        persistRatios()
        loadTask?.cancel()
        pageTasks.values.forEach { $0.cancel() }
        thumbTasks.values.forEach { $0.cancel() }
        thumbTasks.removeAll()
        thumbnails = [:]
        thumbnailOrder = []
        nextTask?.cancel()
        restoreSystemBrightness()
        source?.close()
        source = nil
    }

    // MARK: - 翻完推荐下一本（IOS-208）

    /// 翻完只弹提示、不自动打开；点击提示条由 View 层经 Presenter 接管（换 entry 重建阅读器）
    private func scheduleNextTip() {
        guard nextCandidate == nil, nextTask == nil else { return }
        nextTask = Task {
            guard let found = await Self.findNextComic(after: entry, connection: connection) else { return }
            await MainActor.run { self.nextCandidate = found }
        }
    }

    func cancelNext() {
        nextTask?.cancel()
        nextTask = nil
        nextCandidate = nil
    }

    /// 同目录按浏览排序偏好找下一本漫画
    private static func findNextComic(
        after entry: FileEntry, connection: Connection
    ) async -> FileEntry? {
        guard let adapter = try? AdapterFactory.makeAdapter(for: connection) else { return nil }
        let parent = StoragePath.parent(of: entry.path)
        guard let siblings = try? await adapter.list(parent) else { return nil }
        let comics = siblings.filter { !$0.isDir && MediaType.detect(ext: $0.ext) == .comic }
        // 用该目录单独缓存的排序（TODO 370）与浏览界面显示顺序一致，无记录回落全局默认
        let preference = BrowseSortPreferences.preference(
            connectionID: connection.id ?? 0, path: parent
        )
        let ascending = preference?.ascending ?? AppSettings.Browse.sortAscending
        let sorted: [FileEntry]
        switch preference?.sortKey ?? AppSettings.Browse.sortKey {
        case .name:
            sorted = comics.sorted {
                ascending
                    ? $0.name.naturalCompare($1.name) == .orderedAscending
                    : $0.name.naturalCompare($1.name) == .orderedDescending
            }
        case .size:
            sorted = comics.sorted { ascending ? $0.size < $1.size : $0.size > $1.size }
        case .modTime:
            sorted = comics.sorted { ascending ? $0.modTime < $1.modTime : $0.modTime > $1.modTime }
        }
        guard let index = sorted.firstIndex(where: { $0.path == entry.path }),
              index + 1 < sorted.count else { return nil }
        return sorted[index + 1]
    }

    // MARK: - 亮度（IOS-210 控制层重设计：复用全局阅读亮度偏好，与小说阅读器同档）

    /// 进入阅读器：记录系统亮度并按用户偏好施加（偏好 <0 表示跟随系统，不改动）
    func applyReaderBrightness() {
        systemBrightness = UIScreen.main.brightness
        let stored = AppSettings.Reader.brightness
        if stored >= 0 { UIScreen.main.brightness = CGFloat(stored) }
    }

    func setBrightness(_ value: Double) {
        AppSettings.Reader.brightness = value
        if value >= 0 {
            UIScreen.main.brightness = CGFloat(value)
        } else if systemBrightness >= 0 {
            UIScreen.main.brightness = systemBrightness   // 跟随系统：恢复进入前亮度
        }
    }

    /// 退出阅读器：恢复进入前的系统亮度
    private func restoreSystemBrightness() {
        if systemBrightness >= 0 { UIScreen.main.brightness = systemBrightness }
    }

    // MARK: - 缩略图（IOS-210 控制层重设计：☰ 缩略图面板）

    /// 单页缩略图（小尺寸解码，独立于阅读大图缓存）：已解码页直接缩略 → 磁盘缓存解码 →
    /// 归档按需解压（复用解压并发名额，防抢占阅读预加载）。
    func thumbnail(for index: Int) async -> UIImage? {
        guard state == .ready, index >= 0, index < pageCount else { return nil }
        if let cached = thumbnails[index] { return cached }
        if let running = thumbTasks[index] { return await running.value }
        let task = Task.detached(priority: .utility) { [weak self] () -> UIImage? in
            guard let self else { return nil }
            // 已解码大图命中：直接缩略，省一次解压
            if let decoded = await MainActor.run({ self.images[index] }) {
                return decoded.preparingThumbnail(of: Self.thumbnailSize)
            }
            let identity = await MainActor.run { self.cacheIdentity }
            let source = await MainActor.run { self.source }
            let pageName = source?.pageNames.indices.contains(index) == true
                ? source?.pageNames[index] : nil
            // 页磁盘缓存命中：解码缩略，不占归档解压名额
            if let identity, let pageName,
               let data = await ComicPageCache.page(file: identity, name: pageName) {
                return ImageDownsampler.downsample(data: data, maxPixel: Self.thumbnailSize.width)
            }
            guard let source else { return nil }
            await self.acquireDecodeSlot()
            let data = try? await source.pageData(at: index)
            await self.releaseDecodeSlot()
            guard let data else { return nil }
            if let identity, let pageName {
                await ComicPageCache.storePage(data, file: identity, name: pageName)
            }
            return ImageDownsampler.downsample(data: data, maxPixel: Self.thumbnailSize.width)
        }
        thumbTasks[index] = task
        let image = await task.value
        thumbTasks[index] = nil
        if let image { storeThumbnail(image, at: index) }
        return image
    }

    /// 缩略图目标边长（4 列网格 @3x 约 300px，取 256 兼顾清晰与内存）
    private static let thumbnailSize = CGSize(width: 256, height: 256)

    /// 写入缩略图缓存 + LRU 逐出（上限 48 张，长漫画集不撑内存）
    private func storeThumbnail(_ image: UIImage, at index: Int) {
        if thumbnails[index] == nil { thumbnailOrder.append(index) }
        thumbnails[index] = image
        while thumbnailOrder.count > 48 {
            let oldest = thumbnailOrder.removeFirst()
            if oldest != index { thumbnails[oldest] = nil }
        }
    }

    // MARK: - 「下一本」快捷（IOS-210 控制层重设计：⤓ 下一本 chip）

    /// 立即查找同目录下一本漫画（不等待翻完）；结果仍走 NextMediaTip 提示条，点击才打开
    func requestNextComic() {
        guard nextCandidate == nil, nextTask == nil else { return }
        nextTask = Task {
            let found = await Self.findNextComic(after: entry, connection: connection)
            await MainActor.run {
                self.nextTask = nil
                if let found {
                    self.nextCandidate = found
                } else {
                    self.showToast("同目录没有下一本漫画了")
                }
            }
        }
    }

    // MARK: - 工具

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
