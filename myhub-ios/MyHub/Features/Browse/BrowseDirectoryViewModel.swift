import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Photos

/// 目录浏览 ViewModel（浏览 + ~105 文件操作）
@MainActor
final class BrowseDirectoryViewModel: ObservableObject {
    enum State: Equatable {
        case loading            // 首载且无任何缓存
        case loaded             // 有内容（可能正在后台刷新）
        case empty
        case failed(String)     // 失败且无缓存可展示
    }

    /// 传输进度（上传/下载共用，字节级）
    struct TransferProgress: Equatable {
        var title: String
        var current: Int
        var total: Int
        var fileName: String
        var bytesSent: Int64 = 0
        var bytesTotal: Int64 = 0

        var fraction: Double? {
            bytesTotal > 0 ? min(Double(bytesSent) / Double(bytesTotal), 1) : nil
        }
    }

    /// 回收站不支持或移动失败时的降级错误（UI 引导真删确认）
    enum TrashError: Error, LocalizedError {
        /// movedToTrash：本次已成功移入回收站、无需再彻底删除的路径
        case unsupported(movedToTrash: Set<String>, reason: String?)
        var errorDescription: String? {
            if let reason { return "移入回收站失败：\(reason)" }
            return "该连接源不支持回收站"
        }
        /// 本次已移入回收站的路径（降级真删时需排除，避免对已移走的文件重复删除并误报失败）
        var movedToTrash: Set<String> {
            if case .unsupported(let paths, _) = self { return paths }
            return []
        }
        /// 失败原因摘要（UI 展示「无法使用回收站」弹窗时附带）
        var reason: String? {
            if case .unsupported(_, let reason) = self { return reason }
            return nil
        }
    }

    let connection: Connection
    let path: String

    @Published private(set) var entries: [FileEntry] = [] {
        didSet { displayedEntriesCache = nil }
    }
    @Published private(set) var state: State = .loading
    @Published private(set) var isRefreshing = false
    @Published var searchText = "" {
        didSet { displayedEntriesCache = nil }
    }
    @Published var transfer: TransferProgress?
    @Published var operationError: String?
    /// 操作结果轻提示（收藏成功 / 下载完成等）
    @Published var toast: String?

    /// 多选模式：nil = 非多选；值为选中路径集合
    @Published var selection: Set<String>?
    var isSelecting: Bool { selection != nil }

    /// 当前目录已收藏路径（星标状态）
    @Published private(set) var favoritePaths: Set<String> = []

    /// 当前目录被判定为图集型（漫画）的 epub 路径集合（目录层预判， 策略 5）
    @Published private(set) var comicEpubPaths: Set<String> = []
    private var comicEpubDetectTask: Task<Void, Never>?

    /// 排序与视图模式：读写均落到 UserDefaults。
    @Published var sortKey: BrowseSortKey {
        didSet {
            displayedEntriesCache = nil
            guard sortKey != oldValue else { return }
            persistSortPreference()
        }
    }
    @Published var sortAscending: Bool {
        didSet {
            displayedEntriesCache = nil
            guard sortAscending != oldValue else { return }
            persistSortPreference()
        }
    }
    @Published var viewMode: BrowseViewMode {
        didSet { AppSettings.Browse.viewMode = viewMode }
    }

    private let adapter: StorageAdapter?
    /// 单元格封面加载使用的适配器（state 为 failed 时为 nil）
    var storageAdapter: StorageAdapter? { adapter }

    private var loaded = false
    /// 刷新补刷标记：刷新进行中再次请求刷新时登记，本轮结束后立即再刷一次（避免操作后的刷新被丢弃）
    private var refreshPending = false
    private var toastTask: Task<Void, Never>?
    private var favoritesObserver: NSObjectProtocol?
    /// displayedEntries 排序结果缓存：文件多时 localizedStandardCompare 排序很慢
    private var displayedEntriesCache: [FileEntry]?

    /// 诊断：实例序号 / 短标识——父视图每重算一次 `BrowseDirectoryView` 就会
    private static var instanceSeq = 0
    private(set) var instanceTag = ""
    /// 诊断：`loadIfNeeded` / 公开 `refresh()` 的调用次数
    private var loadIfNeededCount = 0
    private var refreshCallCount = 0
    /// 诊断：真正执行的刷新轮次（含补刷循环）
    private var lifecycleRefreshCount = 0

    init(connection: Connection, path: String) {
        let normalizedPath = StoragePath.normalize(path)
        self.connection = connection
        self.path = normalizedPath
        self.adapter = try? AdapterFactory.makeAdapter(for: connection)
        // 排序：优先恢复本目录单独缓存的顺序，无记录回落全局默认
        let sortPreference = BrowseSortPreferences.preference(
            connectionID: connection.id ?? 0, path: normalizedPath
        )
        self.sortKey = sortPreference?.sortKey ?? AppSettings.Browse.sortKey
        self.sortAscending = sortPreference?.ascending ?? AppSettings.Browse.sortAscending
        self.viewMode = AppSettings.Browse.viewMode
        // 收藏双向同步：收藏页/其他入口变更后刷新星标
        favoritesObserver = NotificationCenter.default.addObserver(
            forName: FavoritesStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadFavorites() }
        }
        Self.instanceSeq += 1
        instanceTag = "#VM\(Self.instanceSeq)"
        AppLogger.shared.log("VM 构造 \(instanceTag) path=\(normalizedPath)", level: .debug, module: "browse")
    }

    deinit {
        if let favoritesObserver {
            NotificationCenter.default.removeObserver(favoritesObserver)
        }
    }

    /// 排序变更：写入本目录单独缓存的偏好
    private func persistSortPreference() {
        BrowseSortPreferences.save(
            BrowseSortPreferences.Preference(
                sortKey: sortKey, ascending: sortAscending, updatedAt: Date()
            ),
            connectionID: connectionID,
            path: path
        )
        AppSettings.Browse.sortKey = sortKey
        AppSettings.Browse.sortAscending = sortAscending
    }

 // MARK: - 展示数据（搜索过滤 + 排序，文件夹在前）

    var displayedEntries: [FileEntry] {
        if let cached = displayedEntriesCache { return cached }
        let start = CFAbsoluteTimeGetCurrent()
        var list = entries
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        let ascending = sortAscending
        let key = sortKey
        let sorted = list.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            let result: ComparisonResult
            switch key {
            case .name:
                result = a.name.naturalCompare(b.name)
            case .size:
                result = a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
            case .modTime:
                result = a.modTime.compare(b.modTime)
            }
            if result == .orderedSame {
                return a.name.naturalCompare(b.name) == .orderedAscending
            }
            return ascending ? (result == .orderedAscending) : (result == .orderedDescending)
        }
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        if elapsedMs > 30 {
            AppLogger.shared.log(
                "displayedEntries 排序耗时 \(String(format: "%.1f", elapsedMs))ms, 条目 \(sorted.count), key=\(key.rawValue)",
                level: .warn, module: "browse"
            )
        }
        displayedEntriesCache = sorted
        return sorted
    }

    func entry(for path: String) -> FileEntry? {
        entries.first { $0.path == path }
    }

 // MARK: - 加载

    /// 首次进入：先出缓存再后台刷新（目录结果本地缓存，二次进入加速）
    func loadIfNeeded() async {
        // 诊断：页面 `.task` 若被反复触发，这里会连续计数
        loadIfNeededCount += 1
        AppLogger.shared.log(
            "loadIfNeeded \(instanceTag) 第 \(loadIfNeededCount) 次（已加载=\(loaded)）",
            level: .debug, module: "browse"
        )
        guard !loaded else { return }
        loaded = true
        guard let adapter else {
            state = .failed("连接不可用，请检查连接源配置")
            return
        }
        if let cached = DirectoryCache.shared.load(connectionID: connectionID, path: path) {
            entries = cached.entries
            state = cached.entries.isEmpty ? .empty : .loaded
        }
        await refresh(using: adapter)
    }

    /// 下拉刷新
    func refresh() async {
        // 诊断：谁在高频调用刷新
        refreshCallCount += 1
        AppLogger.shared.log(
            "refresh() \(instanceTag) 第 \(refreshCallCount) 次", level: .debug, module: "browse"
        )
        guard let adapter else { return }
        await refresh(using: adapter, notifyFailure: true)
    }

    /// 目录刷新
    /// 进行中的后台刷新被静默吞掉，列表长时间不更新
    private func refresh(using adapter: StorageAdapter, notifyFailure: Bool = false) async {
        if isRefreshing {
            refreshPending = true
            AppLogger.shared.log(
                "刷新进行中→登记补刷 \(instanceTag)", level: .debug, module: "browse"
            )
            return
        }
        var round = 0
        repeat {
            round += 1
            lifecycleRefreshCount += 1
            AppLogger.shared.log(
                "执行刷新 \(instanceTag) 第 \(lifecycleRefreshCount) 轮（本轮第 \(round) 轮，补刷=\(refreshPending)）",
                level: .debug, module: "browse"
            )
            refreshPending = false
            isRefreshing = true
            await performRefresh(using: adapter, notifyFailure: notifyFailure)
            isRefreshing = false
        } while refreshPending
    }

    private func performRefresh(using adapter: StorageAdapter, notifyFailure: Bool) async {
        do {
            let list = try await adapter.list(path)
            entries = list
            state = list.isEmpty ? .empty : .loaded
            DirectoryCache.shared.save(connectionID: connectionID, path: path, entries: list)
            reloadFavorites()
            detectComicEpubs(adapter: adapter)
        } catch {
            AppLogger.shared.log(
                "目录刷新失败 path=\(path)：\(error.localizedDescription)",
                level: .warn, module: "browse"
            )
            // 有缓存/旧数据则保留，仅首载失败显示错误态
            if entries.isEmpty {
                state = .failed(error.localizedDescription)
            } else if notifyFailure {
                showToast("刷新失败：\(error.localizedDescription)")
            }
        }
    }

 // MARK: - epub 漫画预判

    /// 同步判定（目录显示 / 打开分发用）：优先用已算好的集合，未就绪时兜底查持久化缓存。
    func isComicEpub(_ entry: FileEntry) -> Bool {
        guard entry.ext == "epub", !entry.isDir else { return false }
        return comicEpubPaths.contains(entry.path)
            || EpubComicCache.lookup(connectionID: connectionID, entry: entry) == true
    }

    /// 列目录后异步预判 epub 是否漫画：命中缓存立即更新，未命中做轻量解包判定（串行，避免大文件密集 Range）。
    private func detectComicEpubs(adapter: StorageAdapter) {
        let epubs = entries.filter { !$0.isDir && $0.ext == "epub" }
        comicEpubDetectTask?.cancel()
        comicEpubDetectTask = Task { [weak self] in
            guard let self else { return }
            var detected = self.comicEpubPaths
            for entry in epubs {
                guard !Task.isCancelled else { return }
                let result: Bool?
                if let cached = EpubComicCache.lookup(connectionID: self.connectionID, entry: entry) {
                    result = cached
                } else {
                    result = await EpubBook.detectComicLike(adapter: adapter, entry: entry)
                    if let result {
                        EpubComicCache.store(result, connectionID: self.connectionID, entry: entry)
                    }
                }
                if result == true { detected.insert(entry.path) }
                else if result == false { detected.remove(entry.path) }
                if detected != self.comicEpubPaths {
                    self.comicEpubPaths = detected
                }
            }
        }
    }

    /// 操作后刷新：**不再预删磁盘缓存**——刷新成功会由 `save` 覆盖为新数据
    private func invalidateAndRefresh() async {
        await refresh()
    }

    /// 删除/移动成功后本地立即移除条目并同步目录缓存：不等网络刷新，弱网下界面依然正确
    private func applyLocalRemoval(_ removedPaths: Set<String>) {
        guard !removedPaths.isEmpty else { return }
        entries.removeAll { removedPaths.contains($0.path) }
        state = entries.isEmpty ? .empty : .loaded
        DirectoryCache.shared.save(connectionID: connectionID, path: path, entries: entries)
    }

 // MARK: - 多选模式（菜单「多选」/ 右上角「…」→「选择」进入）

    func toggleSelection(_ entry: FileEntry) {
        guard var set = selection else { return }
        if set.contains(entry.path) {
            set.remove(entry.path)
        } else {
            set.insert(entry.path)
        }
        selection = set
    }

    func selectAll() {
        selection = Set(displayedEntries.map(\.path))
    }

    func endSelection() {
        selection = nil
    }

 // MARK: - 新建文件夹 / 重命名

    func createFolder(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let adapter, !trimmed.isEmpty, !trimmed.contains("/") else { return }
        do {
            try await adapter.mkdir(StoragePath.joining(path, trimmed))
            await invalidateAndRefresh()
        } catch {
            operationError = "新建文件夹失败：\(error.localizedDescription)"
        }
    }

    func rename(_ entry: FileEntry, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let adapter, !trimmed.isEmpty, !trimmed.contains("/"), trimmed != entry.name else { return }
        do {
            let newPath = StoragePath.joining(StoragePath.parent(of: entry.path), trimmed)
            try await adapter.move(entry.path, newPath)
            // 重命名：同步更新阅读记录 filePath（目录重命名时内部文件前缀一并更新）
            ReadingHistoryStore.shared.updatePath(connectionID: connection.id ?? 0, from: entry.path, to: newPath)
            await invalidateAndRefresh()
        } catch {
            operationError = "重命名失败：\(error.localizedDescription)"
        }
    }

 // MARK: - 移动 / 复制（同源走适配器；跨源设备端流式中转，不落大临时文件）

    func move(paths: Set<String>, to destination: Connection, at destDir: String) async {
        await transfer(paths: paths, to: destination, at: destDir, isMove: true)
    }

    func copy(paths: Set<String>, to destination: Connection, at destDir: String) async {
        await transfer(paths: paths, to: destination, at: destDir, isMove: false)
    }

    /// 移动目标：开关开启时一并带上同目录下同名/语言后缀的关联文件（与删除共用同一开关）
    func moveTargets(for paths: Set<String>) -> Set<String> {
        companionTargets(for: paths)
    }

    private func transfer(paths: Set<String>, to destination: Connection, at destDir: String, isMove: Bool) async {
        guard let adapter, let destAdapter = try? AdapterFactory.makeAdapter(for: destination) else {
            operationError = "目标连接不可用"
            return
        }
        let sameConnection = destination.id == connection.id
        // 移动：与删除共用「同名文件」开关，关联文件（字幕/封面/元数据）一并移动
        let targets = isMove ? moveTargets(for: paths) : paths
        let companionCount = max(0, targets.count - paths.count)
        var failed: [String] = []
        var movedPaths: [String] = []
        /// 已移动项中的目录（循环内 entry 在手时记下，避免 await 后回查 entries 失准）
        var movedDirs: Set<String> = []
        for sourcePath in targets.sorted() {
            guard let entry = entry(for: sourcePath) else { continue }
            let destPath = StoragePath.joining(destDir, entry.name)
            do {
                if sameConnection {
                    if isMove {
                        try await adapter.move(sourcePath, destPath)
                        movedPaths.append(sourcePath)
                        if entry.isDir { movedDirs.insert(sourcePath) }
                    } else {
                        try await adapter.copy(sourcePath, destPath)
                    }
                } else {
                    try await streamingCopy(from: adapter, source: entry, to: destAdapter, destination: destPath)
                    if isMove {
                        try await adapter.delete(sourcePath)
                        movedPaths.append(sourcePath)
                        if entry.isDir { movedDirs.insert(sourcePath) }
                    }
                }
            } catch {
                failed.append(entry.name)
            }
        }
        // 移动成功：同步删除源连接下的阅读记录 + 本地列表立即移除
        // 目录需连带清理子路径下的记录（与删除同一套逻辑，否则目录内文件的进度会残留）
        if isMove, !movedPaths.isEmpty {
            removeReadingRecords(for: movedPaths, knownDirs: movedDirs)
            applyLocalRemoval(Set(movedPaths))
        }
        // 源目录刷新（不预删缓存：刷新成功会覆盖，失败保留旧缓存，避免弱网下目录空白）
        await refresh()
        if failed.isEmpty {
            if isMove {
                let companionHint = companionCount > 0 ? "（含 \(companionCount) 个同名/语言后缀文件）" : ""
                showToast("已移动 \(targets.count) 项\(companionHint)")
            } else {
                showToast("已复制 \(targets.count) 项")
            }
        } else {
            operationError = "以下项目失败：\(failed.joined(separator: "、"))"
        }
        endSelection()
    }

    /// 跨源流式中转：边读边写；目录递归（逐层 mkdir + 逐文件流式复制）
    private func streamingCopy(
        from source: StorageAdapter, source entry: FileEntry,
        to destination: StorageAdapter, destination destPath: String
    ) async throws {
        if entry.isDir {
            try await destination.mkdir(destPath)
            let children = try await source.list(entry.path)
            for child in children {
                try await streamingCopy(
                    from: source, source: child,
                    to: destination, destination: StoragePath.joining(destPath, child.name)
                )
            }
        } else {
            let stream = try await source.readStream(entry.path, range: nil)
            try await destination.writeStream(destPath, data: stream)
        }
    }

 // MARK: - 删除（回收站机制：挂载点下 .trash；不支持时降级由 UI 确认真删）

    /// 与条目同目录、可随它一起处理的关联文件（`movie.mp4` → `movie.srt` / `movie.zh.srt`）。
    private func sameStemSiblings(of entry: FileEntry) -> [FileEntry] {
        CompanionFiles.sameStemSiblings(of: entry, in: entries)
    }

    /// 连同关联文件的目标集合（删除、移动共用；开关关闭时返回原集合）
    private func companionTargets(for paths: Set<String>) -> Set<String> {
        guard AppSettings.Browse.deleteSameNameFiles else { return paths }
        var result = paths
        for path in paths {
            guard let entry = entry(for: path) else { continue }
            for sibling in sameStemSiblings(of: entry) {
                result.insert(sibling.path)
            }
        }
        return result
    }

    /// 实际删除目标
    func deleteTargets(for paths: Set<String>) -> Set<String> {
        companionTargets(for: paths)
    }

    func delete(paths: Set<String>) async throws {
        guard let adapter else { return }
        let targets = deleteTargets(for: paths)
        do {
            try await adapter.mkdir("/.trash")
        } catch {
            // 目录已存在或创建失败均继续尝试移动
        }
        let stamp = Self.trashStamp()
        var movedPaths: [String] = []
        /// 已移走项中的目录（循环内 entry 在手时记下，避免 await 后回查 entries 失准）
        var movedDirs: Set<String> = []
        var failureReason: String?
        do {
            for sourcePath in targets.sorted() {
                guard let entry = entry(for: sourcePath) else { continue }
                let trashName = "\(stamp)-\(entry.name)"
                let trashPath = "/.trash/\(trashName)"
                do {
                    // 占用类瞬时失败自动重试：刚播放完的文件服务端句柄可能尚未释放
                    try await Self.withOccupancyRetry { try await adapter.move(sourcePath, trashPath) }
                } catch {
                    failureReason = Self.failureHint(for: error)
                    throw error
                }
                movedPaths.append(sourcePath)
                if entry.isDir { movedDirs.insert(sourcePath) }
                // 记录原路径元数据（回收站还原用）
                await writeTrashMeta(adapter: adapter, trashPath: trashPath, entry: entry)
            }
        } catch {
            // 部分成功：已移入回收站的文件同样清理阅读记录并立即从列表移除
            finishTrashMove(movedPaths, knownDirs: movedDirs)
            throw TrashError.unsupported(movedToTrash: Set(movedPaths), reason: failureReason)
        }
        // 移入回收站即删除对应阅读记录（还原后无需还原记录）
        finishTrashMove(movedPaths, knownDirs: movedDirs)
        await invalidateAndRefresh()
        endSelection()
        // 结果提示由视图层吐司承担（方案 D：进行中 → 原地替换为结果），此处不再重复 showToast
    }

    /// 移入回收站收尾：清理阅读记录 + 本地列表立即移除并同步缓存（弱网下界面依然正确）。
    private func finishTrashMove(_ movedPaths: [String], knownDirs: Set<String> = []) {
        guard !movedPaths.isEmpty else { return }
        removeReadingRecords(for: movedPaths, knownDirs: knownDirs)
        applyLocalRemoval(Set(movedPaths))
    }

    /// 源文件被移走（删除 / 移动）后清理阅读记录：目录连带子路径下的记录，文件按路径精确清理
    private func removeReadingRecords(for paths: [String], knownDirs: Set<String> = []) {
        guard !paths.isEmpty else { return }
        let id = connectionID
        var filePaths: Set<String> = []
        for path in paths {
            if knownDirs.contains(path) || entry(for: path)?.isDir == true {
                ReadingHistoryStore.shared.removeTree(connectionID: id, path: path)
            } else {
                filePaths.insert(path)
            }
        }
        if !filePaths.isEmpty {
            ReadingHistoryStore.shared.remove(connectionID: id, filePaths: filePaths)
        }
    }

 // MARK: - 左滑删除

    /// 左滑删除的撤销句柄：记录回收站落点与被一并清理的阅读记录，供「撤销」原样还原
    struct SwipeTrashReceipt {
        /// 被移入回收站的条目（首项为主条目；开启「删除时移除同名文件」时会带上同名兄弟文件）
        struct Item {
            let entry: FileEntry
            let trashPath: String
        }
        let items: [Item]
        /// 删除前这些路径（含目录下子路径）的阅读记录快照
        let readingRecords: [ReadingProgress]
    }

    /// 左滑删除单个条目：移入挂载点 `.trash` 并返回撤销句柄。
    func deleteToTrash(_ entry: FileEntry) async throws -> SwipeTrashReceipt {
        guard let adapter else { throw StorageError.invalidPath("连接不可用") }
        // 同名文件需在 await 前取快照：期间 entries 可能被并发刷新替换
        let companions = AppSettings.Browse.deleteSameNameFiles ? sameStemSiblings(of: entry) : []
        do {
            try await adapter.mkdir("/.trash")
        } catch {
            // 目录已存在或创建失败均继续尝试移动
        }
        let stamp = Self.trashStamp()
        let trashPath = "/.trash/\(stamp)-\(entry.name)"
        // 占用类瞬时失败自动重试
        try await Self.withOccupancyRetry { try await adapter.move(entry.path, trashPath) }
        await writeTrashMeta(adapter: adapter, trashPath: trashPath, entry: entry)
        var items: [SwipeTrashReceipt.Item] = [.init(entry: entry, trashPath: trashPath)]

        // 同名文件：尽力移入回收站，失败不阻断主条目（仅在日志留痕）
        for companion in companions {
            let companionTrashPath = "/.trash/\(stamp)-\(companion.name)"
            do {
                try await Self.withOccupancyRetry {
                    try await adapter.move(companion.path, companionTrashPath)
                }
            } catch {
                AppLogger.shared.log(
                    "同名文件移入回收站失败 name=\(companion.name) error=\(error.localizedDescription)",
                    level: .warn, module: "browse"
                )
                continue
            }
            await writeTrashMeta(adapter: adapter, trashPath: companionTrashPath, entry: companion)
            items.append(.init(entry: companion, trashPath: companionTrashPath))
        }

        // 撤销需还原阅读记录，故在清理前先取快照（目录需连同子路径下的记录）
        let snapshot = items.flatMap { readingRecordsSnapshot(under: $0.entry) }
        // isDir 直接用手里的 entry：上面两个 await 期间 entries 可能已被并发刷新替换
        let knownDirs: Set<String> = entry.isDir ? [entry.path] : []
        finishTrashMove(items.map(\.entry.path), knownDirs: knownDirs)
        await invalidateAndRefresh()
        return SwipeTrashReceipt(items: items, readingRecords: snapshot)
    }

    /// 撤销左滑删除：把文件从回收站移回原路径（被占用则自动追加序号），并补回阅读记录。
    func undoDeleteToTrash(_ receipt: SwipeTrashReceipt) async {
        guard let adapter, let primary = receipt.items.first else { return }
        let originalPath = primary.entry.path
        var failure: String?
        // 主条目是否原样还原：只有它回到原路径，旧阅读记录才仍然有效
        var primaryRestoredToOriginal = false
        for item in receipt.items {
            var candidate = item.entry.path
            var counter = 1
            // 上限保护：部分 WebDAV / 反代对任意路径都返回 200（工程为此有 StorageError.invalidResponse）
            while counter <= 20, (try? await adapter.stat(candidate)) != nil {
                let stem = (item.entry.name as NSString).deletingPathExtension
                let ext = (item.entry.name as NSString).pathExtension
                let suffix = ext.isEmpty ? " (\(counter))" : " (\(counter)).\(ext)"
                candidate = StoragePath.joining(StoragePath.parent(of: item.entry.path), stem + suffix)
                counter += 1
            }
            do {
                try await Self.withOccupancyRetry { try await adapter.move(item.trashPath, candidate) }
            } catch {
                failure = failure ?? error.localizedDescription
                continue
            }
            try? await adapter.delete(item.trashPath + ".meta.json")
            if item.entry.path == originalPath, candidate == originalPath {
                primaryRestoredToOriginal = true
            }
        }
        if let failure {
            operationError = "撤销失败：\(failure)。文件仍在回收站中，可在「回收站」手动还原"
        }
        // 原路径未被占用才补回阅读记录（改名还原后旧记录已对不上文件）
        if primaryRestoredToOriginal, !receipt.readingRecords.isEmpty {
            ReadingHistoryStore.shared.restore(receipt.readingRecords)
        }
        await invalidateAndRefresh()
    }

    /// 某条目（文件或目录）关联的阅读记录快照：目录取其子路径下全部记录
    private func readingRecordsSnapshot(under entry: FileEntry) -> [ReadingProgress] {
        let id = connectionID
        let prefix = entry.path.hasSuffix("/") ? entry.path : entry.path + "/"
        return ReadingHistoryStore.shared.records.filter { record in
            record.connectionID == id
                && (record.filePath == entry.path || (entry.isDir && record.filePath.hasPrefix(prefix)))
        }
    }

    /// 彻底删除（回收站不可用时经用户确认的降级）
    func forceDelete(paths: Set<String>) async {
        guard let adapter else { return }
        let targets = deleteTargets(for: paths)
        var failed: [String] = []
        var deletedPaths: [String] = []
        // 删除前先记下哪些是目录：循环内的 await 期间 entries 可能被并发刷新替换
        let dirs = Set(targets.filter { entry(for: $0)?.isDir == true })
        for sourcePath in targets.sorted() {
            do {
                // 占用类瞬时失败自动重试
                try await Self.withOccupancyRetry { try await adapter.delete(sourcePath) }
                deletedPaths.append(sourcePath)
            } catch {
                failed.append("\(StoragePath.fileName(of: sourcePath))（\(Self.failureHint(for: error))）")
            }
        }
        // 彻底删除：同步清理阅读记录 + 本地列表立即移除。
        if !deletedPaths.isEmpty {
            finishTrashMove(deletedPaths, knownDirs: dirs)
        }
        await invalidateAndRefresh()
        endSelection()
        if !failed.isEmpty {
            // 附具体失败原因与可操作建议（文件刚播放完时服务端句柄可能仍被占用）
            operationError = "删除失败：\(failed.joined(separator: "、"))。文件可能仍被占用或网络异常，请稍后重试"
        }
    }

 // MARK: - 删除类操作容错

    /// 占用/瞬时类错误自动重试：文件刚播放完时服务端（NAS）可能仍持有读取句柄
    private static func withOccupancyRetry<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                attempt += 1
                guard attempt < 3, isRetryableOccupancyError(error) else { throw error }
                AppLogger.shared.log(
                    "删除类操作失败，退避后重试（第 \(attempt) 次）error=\(error.localizedDescription)",
                    level: .warn, module: "browse"
                )
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 600_000_000)
            }
        }
    }

    /// 可重试错误：服务端瞬时占用/网关错误（423/409/429/5xx、异常响应）与网络抖动/超时
    private static func isRetryableOccupancyError(_ error: Error) -> Bool {
        if let storage = error as? StorageError {
            switch storage {
            case .http(let status, _):
                return status == 409 || status == 423 || status == 429 || (500...599).contains(status)
            case .invalidResponse:
                return true
            case .underlying(let inner):
                return isRetryableOccupancyError(inner)
            default:
                return false
            }
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
             .notConnectedToInternet, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    /// 失败原因提示：把底层错误翻译为用户可行动的原因（占用/网络/权限/服务器）
    private static func failureHint(for error: Error) -> String {
        if let storage = error as? StorageError {
            switch storage {
            case .http(let status, _) where status == 423:
                return "文件被占用（HTTP 423）"
            case .http(let status, _) where status == 409:
                return "服务器状态冲突（HTTP 409）"
            case .http(let status, _) where status == 429:
                return "请求过于频繁（HTTP 429）"
            case .http(let status, _) where status == 405 || status == 501:
                return "服务器不支持该操作（HTTP \(status)）"
            case .http(let status, _) where (500...599).contains(status):
                return "服务器错误（HTTP \(status)）"
            case .http(let status, _):
                return "HTTP \(status)"
            case .authenticationFailed:
                return "认证失败或权限不足"
            case .notFound:
                return "文件不存在，可能已被删除或移动"
            case .invalidResponse(let message):
                return "服务器响应异常（\(message)）"
            case .underlying(let inner):
                return networkHint(for: inner) ?? inner.localizedDescription
            case .invalidPath, .invalidConfig, .unsupportedProtocol, .offline:
                return storage.localizedDescription
            }
        }
        if let urlError = error as? URLError {
            return networkHint(for: urlError) ?? urlError.localizedDescription
        }
        return error.localizedDescription
    }

    /// 网络类错误 → 简短提示（无匹配返回 nil 交由调用方回退原始描述）
    private static func networkHint(for error: Error) -> String? {
        guard let urlError = error as? URLError else { return nil }
        switch urlError.code {
        case .timedOut: return "网络超时"
        case .notConnectedToInternet: return "无网络连接"
        case .networkConnectionLost: return "网络连接中断"
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: return "无法连接服务器"
        default: return nil
        }
    }

    private struct TrashMeta: Codable {
        var originalPath: String
        var name: String
        var isDir: Bool
        var deletedAt: Date
    }

    private func writeTrashMeta(adapter: StorageAdapter, trashPath: String, entry: FileEntry) async {
        let meta = TrashMeta(originalPath: entry.path, name: entry.name, isDir: entry.isDir, deletedAt: Date())
        guard let data = try? JSONEncoder().encode(meta) else { return }
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(data)
            continuation.finish()
        }
        try? await adapter.writeStream(trashPath + ".meta.json", data: stream)
    }

    private static func trashStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

 // MARK: - 收藏：经 FavoritesStore 读写，收藏页与本页星标双向同步

    private func reloadFavorites() {
        favoritePaths = FavoritesStore.shared.paths(for: connectionID)
    }

    /// 切换收藏；返回当前是否已收藏
    @discardableResult
    func toggleFavorite(_ entry: FileEntry) -> Bool {
        let favorited = FavoritesStore.shared.toggle(connectionID: connectionID, entry: entry)
        showToast(favorited ? "已收藏" : "已取消收藏")
        return favorited
    }

    /// 批量收藏（多选操作栏）
    func favoriteSelected(_ paths: Set<String>) {
        let targets = paths.compactMap { entry(for: $0) }
        let added = FavoritesStore.shared.add(connectionID: connectionID, entries: targets)
        showToast(added > 0 ? "已收藏 \(added) 项" : "所选均已在收藏中")
        endSelection()
    }

 // MARK: - 上传（多文件队列 + 字节级进度）

    func upload(urls: [URL]) async {
        guard let adapter, !urls.isEmpty else { return }
        for (index, url) in urls.enumerated() {
            transfer = TransferProgress(
                title: "正在上传", current: index + 1, total: urls.count,
                fileName: url.lastPathComponent,
                bytesTotal: (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
            )
            do {
                let accessing = url.startAccessingSecurityScopedResource()
                let stream = Self.fileStream(url: url) { [weak self] sent in
                    Task { @MainActor in self?.transfer?.bytesSent = sent }
                }
                try await adapter.writeStream(StoragePath.joining(path, url.lastPathComponent), data: stream)
                if accessing { url.stopAccessingSecurityScopedResource() }
            } catch {
                operationError = "「\(url.lastPathComponent)」上传失败：\(error.localizedDescription)"
            }
        }
        transfer = nil
        await invalidateAndRefresh()
    }

    /// 相册导入项上传（图片走内存，视频走临时文件）
    func upload(imports: [PhotoImport]) async {
        guard let adapter, !imports.isEmpty else { return }
        for (index, item) in imports.enumerated() {
            transfer = TransferProgress(
                title: "正在上传", current: index + 1, total: imports.count,
                fileName: item.fileName, bytesTotal: item.byteCount
            )
            do {
                let stream = item.makeStream { [weak self] sent in
                    Task { @MainActor in self?.transfer?.bytesSent = sent }
                }
                try await adapter.writeStream(StoragePath.joining(path, item.fileName), data: stream)
            } catch {
                operationError = "「\(item.fileName)」上传失败：\(error.localizedDescription)"
            }
            item.cleanup()
        }
        transfer = nil
        await invalidateAndRefresh()
    }

    /// 本地文件 → 适配器写入流（256KB 分块 + 进度回调）
    private static func fileStream(
        url: URL, onBytes: ((Int64) -> Void)? = nil
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    var sent: Int64 = 0
                    while !Task.isCancelled {
                        guard let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
                        sent += Int64(chunk.count)
                        onBytes?(sent)
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

 // MARK: - 下载（本地沙盒 / 「文件」App / 相册）

    /// 本地下载目录：Documents/Downloads（「文件」App 可见——已开 UIFileSharingEnabled）
    static var downloadsDirectory: URL {
        let url = LocalAdapter.documentsRoot.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 下载到本地沙盒（仅文件）
    func downloadToLocal(paths: Set<String>) async {
        guard let adapter else { return }
        let files = paths.compactMap { entry(for: $0) }.filter { !$0.isDir }
        guard !files.isEmpty else { return }
        var failed: [String] = []
        for (index, entry) in files.enumerated() {
            transfer = TransferProgress(
                title: "正在下载", current: index + 1, total: files.count,
                fileName: entry.name, bytesTotal: entry.size
            )
            do {
                let destination = Self.uniqueURL(in: Self.downloadsDirectory, name: entry.name)
                try await download(adapter: adapter, entry: entry, to: destination)
            } catch {
                failed.append(entry.name)
            }
        }
        transfer = nil
        if failed.isEmpty {
            showToast("已下载 \(files.count) 个文件到本地 Downloads")
        } else {
            operationError = "下载失败：\(failed.joined(separator: "、"))"
        }
        endSelection()
    }

    /// 下载到临时文件（供「存储到文件 / 保存相册」使用）；调用方负责清理
    func downloadToTemp(_ entry: FileEntry) async throws -> URL {
        guard let adapter else { throw StorageError.invalidConfig("连接不可用") }
        transfer = TransferProgress(
            title: "正在准备", current: 1, total: 1, fileName: entry.name, bytesTotal: entry.size
        )
        defer { transfer = nil }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-\(UUID().uuidString)-\(entry.name)")
        try await download(adapter: adapter, entry: entry, to: temp)
        return temp
    }

    /// 保存到相册（图片 / 视频）
    func saveToPhotos(_ entry: FileEntry) async throws {
        let temp = try await downloadToTemp(entry)
        defer { try? FileManager.default.removeItem(at: temp) }
        let type = MediaType.detect(ext: entry.ext)
        try await PHPhotoLibrary.shared().performChanges {
            if type == .video {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: temp)
            } else {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: temp)
            }
        }
        showToast("已保存到相册")
    }

    /// 流式下载到本地文件（256KB 分块 + 进度）
    private func download(adapter: StorageAdapter, entry: FileEntry, to destination: URL) async throws {
        let stream = try await adapter.readStream(entry.path, range: nil)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        var sent: Int64 = 0
        do {
            for try await chunk in stream {
                try handle.write(contentsOf: chunk)
                sent += Int64(chunk.count)
                transfer?.bytesSent = sent
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func uniqueURL(in directory: URL, name: String) -> URL {
        var url = directory.appendingPathComponent(name)
        var counter = 1
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: url.path) {
            let suffix = ext.isEmpty ? " (\(counter))" : " (\(counter)).\(ext)"
            url = directory.appendingPathComponent(stem + suffix)
            counter += 1
        }
        return url
    }

 // MARK: - 轻提示

    private func showToast(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    private var connectionID: Int64 { connection.id ?? 0 }
}

// MARK: - 相册导入项

/// 相册选择结果（PhotosPicker loadTransferable）：图片走 Data，视频走临时文件
struct PhotoImport: Transferable {
    let fileName: String
    let data: Data?
    let fileURL: URL?

    var byteCount: Int64 {
        if let data { return Int64(data.count) }
        if let fileURL,
           let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            return Int64(size)
        }
        return 0
    }

    func makeStream(onBytes: ((Int64) -> Void)? = nil) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let data {
                        let chunkSize = 256 * 1024
                        var offset = 0
                        while offset < data.count, !Task.isCancelled {
                            let end = min(offset + chunkSize, data.count)
                            onBytes?(Int64(end))
                            continuation.yield(data[offset..<end])
                            offset = end
                        }
                    } else if let fileURL {
                        let handle = try FileHandle(forReadingFrom: fileURL)
                        defer { try? handle.close() }
                        var sent: Int64 = 0
                        while !Task.isCancelled {
                            guard let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
                            sent += Int64(chunk.count)
                            onBytes?(sent)
                            continuation.yield(chunk)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cleanup() {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            PhotoImport(
                fileName: "IMG_\(stamp()).\(Self.sniffImageExt(data))",
                data: data, fileURL: nil
            )
        }
        FileRepresentation(importedContentType: .movie) { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("upload-\(UUID().uuidString).mov")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PhotoImport(fileName: "VID_\(stamp()).mov", data: nil, fileURL: dest)
        }
    }

    /// 图片格式嗅探（magic bytes）
    private static func sniffImageExt(_ data: Data) -> String {
        if data.count >= 12 {
            if data[0] == 0xFF, data[1] == 0xD8 { return "jpg" }
            if data[0] == 0x89, data[1] == 0x50 { return "png" }
            if data[0] == 0x47, data[1] == 0x49 { return "gif" }
            let ftyp = data[4..<12]
            if String(decoding: ftyp, as: UTF8.self).hasPrefix("ftyp") { return "heic" }
        }
        return "jpg"
    }
}
