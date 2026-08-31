import Foundation
import SwiftUI

/// 漫画阅读模式（IOS-207）：单页 / 双页（横屏·平板自动，可切换方向）/ 条漫（纵向连续滚动）
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
    /// 已解码页面（内存缓存，LRU 上限约 12 页）
    @Published private(set) var images: [Int: UIImage] = [:]
    @Published var toast: String?

    /// 阅读模式（横屏 / iPad 自动启用双页）
    @Published var mode: ComicReadMode
    /// 双页阅读方向（持久化；auto 时按设备形态解析）
    @Published var direction: ComicReadingDirection {
        didSet { AppSettings.Reader.comicDirection = direction }
    }

    /// 翻完推荐下一本（IOS-208）
    @Published private(set) var nextCandidate: FileEntry?
    @Published var nextCountdown = 0

    private let adapter: StorageAdapter?
    private var source: ComicPageSource?
    /// 页磁盘缓存身份（在线：entry 指纹；离线：缓存反查身份，IOS-605）
    private var cacheIdentity: SegmentCache.FileIdentity?
    private var loadTask: Task<Void, Never>?
    private var pageTasks: [Int: Task<UIImage?, Never>] = [:]
    private var reportTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var nextTask: Task<Void, Never>?
    private var coverKey: String?
    /// 上次翻页方向（预加载前向/后向优先）
    private var lastForward = true

    init(connection: Connection, entry: FileEntry, sizeClass: UserInterfaceSizeClass? = nil) {
        self.connection = connection
        self.entry = entry
        self.adapter = try? AdapterFactory.makeAdapter(for: connection)
        self.direction = AppSettings.Reader.comicDirection
        let landscape = UIScreen.main.bounds.width > UIScreen.main.bounds.height
        self.mode = (landscape || sizeClass == .regular) ? .double : .single
    }

    deinit {
        loadTask?.cancel()
        pageTasks.values.forEach { $0.cancel() }
        reportTask?.cancel()
        toastTask?.cancel()
        nextTask?.cancel()
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
        do {
            let opened = try await ArchiveDecoder.open(
                entry: entry, adapter: adapter, connectionID: connectionID
            ) { [weak self] fraction in
                Task { @MainActor in self?.state = .opening(fraction) }
            }
            try Task.checkCancellation()
            AppLogger.shared.log(
                "归档打开成功: pageCount=\(opened.pageCount) 首页名=\(opened.pageNames.first ?? "-")",
                module: "comic-reader"
            )
            let identity = ComicPageCache.identity(connectionID: connectionID, entry: entry)
            cacheIdentity = identity
            // 页名列表落盘（离线打开的结构基础）
            Task.detached(priority: .utility) {
                await ComicPageCache.storePageList(opened.pageNames, file: identity)
            }
            await finishOpen(source: opened, fileSize: entry.size, modTime: entry.modTime)
        } catch is CancellationError {
            AppLogger.shared.log("打开取消（退出/切换）", module: "comic-reader")
        } catch {
            AppLogger.shared.log(
                "归档打开失败: error=\(error) desc=\(error.localizedDescription)，尝试离线回退",
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
                    "离线回退失败，最终标记 failed: \(error.localizedDescription)",
                    level: .error, module: "comic-reader"
                )
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// 打开完成：进度恢复（首次构建即定位上次页码）+ 封面提取 + 首屏与预加载
    private func finishOpen(source: ComicPageSource, fileSize: Int64, modTime: Date) async {
        self.source = source
        pageCount = source.pageCount

        // 进度恢复：指纹不匹配 → 提示并归零
        let saved = ComicProgressStore.loadAnchor(
            connectionID: connectionID, path: entry.path,
            fileSize: fileSize, modTime: modTime
        )
        if saved.stale { showToast("文件已更新，进度已重置") }
        let restored = min(max(saved.anchor?.page ?? 0, 0), max(source.pageCount - 1, 0))
        page = restored
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
            // 并发上限 3：排队等待
            while true {
                if Task.isCancelled { return nil }
                let running = await MainActor.run {
                    self.pageTasks.values.filter { !$0.isCancelled }.count
                }
                if running <= 3 { break }
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
            // IOS-605 解压页磁盘缓存：命中免解压免网络（离线可读），未命中解出后落盘
            let identity = await MainActor.run { self.cacheIdentity }
            let pageName = source.pageNames.indices.contains(index) ? source.pageNames[index] : nil
            if let identity, let pageName,
               let cached = await ComicPageCache.page(file: identity, name: pageName) {
                return ImageDownsampler.downsample(data: cached, maxPixel: 2200)
            }
            guard let data = try? await source.pageData(at: index) else { return nil }
            if let identity, let pageName {
                await ComicPageCache.storePage(data, file: identity, name: pageName)
            }
            return ImageDownsampler.downsample(data: data, maxPixel: 2200)
        }
        pageTasks[index] = task
        if let image = await task.value {
            images[index] = image
            evictIfNeeded(around: index)
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

    var pageName: String {
        source?.pageNames.indices.contains(page) == true ? source?.pageNames[page] ?? "" : ""
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

    func nextPage() { goToPage(page + (mode == .double ? 2 : 1)) }
    func previousPage() { goToPage(page - (mode == .double ? 2 : 1)) }

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
                modTime: entry.modTime.timeIntervalSince1970
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
        loadTask?.cancel()
        pageTasks.values.forEach { $0.cancel() }
        nextTask?.cancel()
        source?.close()
        source = nil
    }

    // MARK: - 翻完推荐下一本（IOS-208）

    private func scheduleNextTip() {
        guard nextCandidate == nil, nextTask == nil else { return }
        nextTask = Task {
            guard let found = await Self.findNextComic(after: entry, connection: connection) else { return }
            await MainActor.run {
                self.nextCandidate = found
                self.nextCountdown = 5
            }
            // 5s 倒计时自动打开
            for remaining in stride(from: 4, through: 0, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                await MainActor.run { self.nextCountdown = remaining }
            }
            if !Task.isCancelled { openNext() }
        }
    }

    func cancelNext() {
        nextTask?.cancel()
        nextTask = nil
        nextCandidate = nil
        nextCountdown = 0
    }

    private func openNext() {
        // 由 View 层经 Presenter 接管（需要换 entry 重建阅读器）
        guard let candidate = nextCandidate else { return }
        cancelNext()
        NotificationCenter.default.post(
            name: .comicOpenNext, object: nil,
            userInfo: ["connection": connection, "entry": candidate]
        )
    }

    /// 同目录按浏览排序偏好找下一本漫画
    private static func findNextComic(
        after entry: FileEntry, connection: Connection
    ) async -> FileEntry? {
        guard let adapter = try? AdapterFactory.makeAdapter(for: connection) else { return nil }
        let parent = StoragePath.parent(of: entry.path)
        guard let siblings = try? await adapter.list(parent) else { return nil }
        let comics = siblings.filter { !$0.isDir && MediaType.detect(ext: $0.ext) == .comic }
        let ascending = AppSettings.Browse.sortAscending
        let sorted: [FileEntry]
        switch AppSettings.Browse.sortKey {
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

/// 漫画「打开下一本」通知（ComicReaderView → ComicReaderPresenter 换项重建）
extension Notification.Name {
    static let comicOpenNext = Notification.Name("comicOpenNext")
}
