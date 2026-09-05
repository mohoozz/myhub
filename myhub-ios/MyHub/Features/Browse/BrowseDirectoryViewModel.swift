import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Photos

/// 目录浏览 ViewModel（IOS-102 浏览 + IOS-103~105 文件操作）：
/// - stale-while-revalidate：先展示目录缓存（秒开），再后台拉新；
/// - 排序 / 搜索 / 视图模式偏好持久化（AppSettings.Browse）；
/// - 多选模式与文件操作：新建文件夹 / 重命名 / 移动 / 复制（跨源流式中转）/ 删除入回收站 / 收藏；
/// - 传输：上传（文件/相册，字节级进度）、下载到本地沙盒 / 相册 / 「文件」App。
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

    /// 回收站不支持时的降级错误（UI 引导真删确认）
    enum TrashError: Error, LocalizedError {
        case unsupported
        var errorDescription: String? { "该连接源不支持回收站" }
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
    @Published private(set) var childCounts: [String: Int] = [:]
    @Published var transfer: TransferProgress?
    @Published var operationError: String?
    /// 操作结果轻提示（收藏成功 / 下载完成等）
    @Published var toast: String?

    /// 多选模式：nil = 非多选；值为选中路径集合
    @Published var selection: Set<String>?
    var isSelecting: Bool { selection != nil }

    /// 当前目录已收藏路径（星标状态）
    @Published private(set) var favoritePaths: Set<String> = []

    /// 当前目录被判定为图集型（漫画）的 epub 路径集合（目录层预判，IOS-207 策略 5）
    @Published private(set) var comicEpubPaths: Set<String> = []
    private var comicEpubDetectTask: Task<Void, Never>?

    /// 排序与视图模式：读写均落到 UserDefaults（排序与路径显示偏好缓存）
    @Published var sortKey: BrowseSortKey {
        didSet { displayedEntriesCache = nil; AppSettings.Browse.sortKey = sortKey }
    }
    @Published var sortAscending: Bool {
        didSet { displayedEntriesCache = nil; AppSettings.Browse.sortAscending = sortAscending }
    }
    @Published var viewMode: BrowseViewMode {
        didSet { AppSettings.Browse.viewMode = viewMode }
    }

    private let adapter: StorageAdapter?
    /// 单元格封面加载使用的适配器（state 为 failed 时为 nil）
    var storageAdapter: StorageAdapter? { adapter }

    private var loaded = false
    private var childCountInFlight: Set<String> = []
    private var childCountAttempted: Set<String> = []
    private var toastTask: Task<Void, Never>?
    private var favoritesObserver: NSObjectProtocol?
    /// displayedEntries 排序结果缓存：文件多时 localizedStandardCompare 排序很慢，
    /// 若每次 body 求值都重排会阻塞主线程导致滑动卡死，这里在数据变化时重算一次并复用。
    private var displayedEntriesCache: [FileEntry]?

    init(connection: Connection, path: String) {
        self.connection = connection
        self.path = StoragePath.normalize(path)
        self.adapter = try? AdapterFactory.makeAdapter(for: connection)
        self.sortKey = AppSettings.Browse.sortKey
        self.sortAscending = AppSettings.Browse.sortAscending
        self.viewMode = AppSettings.Browse.viewMode
        // 收藏双向同步：收藏页/其他入口变更后刷新星标
        favoritesObserver = NotificationCenter.default.addObserver(
            forName: FavoritesStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadFavorites() }
        }
    }

    deinit {
        if let favoritesObserver {
            NotificationCenter.default.removeObserver(favoritesObserver)
        }
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
        guard let adapter else { return }
        await refresh(using: adapter)
    }

    private func refresh(using adapter: StorageAdapter) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let list = try await adapter.list(path)
            entries = list
            state = list.isEmpty ? .empty : .loaded
            DirectoryCache.shared.save(connectionID: connectionID, path: path, entries: list)
            reloadFavorites()
            detectComicEpubs(adapter: adapter)
        } catch {
            // 有缓存/旧数据则静默保留，仅首载失败显示错误态
            if entries.isEmpty {
                state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - epub 漫画预判（IOS-207 策略 5）

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

    /// 操作后失效缓存并刷新
    private func invalidateAndRefresh() async {
        DirectoryCache.shared.invalidate(connectionID: connectionID, path: path)
        await refresh()
    }

    // MARK: - 文件夹子项数（懒加载，限并发）

    func loadChildCountIfNeeded(for entry: FileEntry) {
        guard entry.isDir, let adapter,
              !childCountAttempted.contains(entry.path),
              !childCountInFlight.contains(entry.path),
              childCountInFlight.count < 3 else { return }
        childCountAttempted.insert(entry.path)
        childCountInFlight.insert(entry.path)
        Task {
            let start = CFAbsoluteTimeGetCurrent()
            let count = try? await adapter.list(entry.path).count
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            childCountInFlight.remove(entry.path)
            if let count {
                childCounts[entry.path] = count   // 会话内缓存，不重复请求
            }
            if elapsedMs > 50 {
                AppLogger.shared.log(
                    "loadChildCount \(entry.path) 耗时 \(String(format: "%.1f", elapsedMs))ms, count=\(count ?? -1)",
                    level: .warn, module: "browse"
                )
            }
        }
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
            // 重命名：同步更新阅读记录 filePath（目录重命名时内部文件前缀一并更新，TODO §7.309）
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

    private func transfer(paths: Set<String>, to destination: Connection, at destDir: String, isMove: Bool) async {
        guard let adapter, let destAdapter = try? AdapterFactory.makeAdapter(for: destination) else {
            operationError = "目标连接不可用"
            return
        }
        let sameConnection = destination.id == connection.id
        var failed: [String] = []
        var movedPaths: [String] = []
        for sourcePath in paths.sorted() {
            guard let entry = entry(for: sourcePath) else { continue }
            let destPath = StoragePath.joining(destDir, entry.name)
            do {
                if sameConnection {
                    if isMove {
                        try await adapter.move(sourcePath, destPath)
                        movedPaths.append(sourcePath)
                    } else {
                        try await adapter.copy(sourcePath, destPath)
                    }
                } else {
                    try await streamingCopy(from: adapter, source: entry, to: destAdapter, destination: destPath)
                    if isMove {
                        try await adapter.delete(sourcePath)
                        movedPaths.append(sourcePath)
                    }
                }
            } catch {
                failed.append(entry.name)
            }
        }
        // 移动成功：同步删除源连接下的阅读记录（TODO §7.309，路径已变更，记录不再指向原文件）
        if isMove, !movedPaths.isEmpty {
            ReadingHistoryStore.shared.remove(connectionID: connection.id ?? 0, filePaths: Set(movedPaths))
        }
        if sameConnection {
            await invalidateAndRefresh()
        } else {
            // 跨源：源目录（移动时）与目标目录缓存都失效
            DirectoryCache.shared.invalidate(connectionID: connectionID, path: path)
            DirectoryCache.shared.invalidate(connectionID: destination.id ?? 0, path: StoragePath.normalize(destDir))
            await refresh()
        }
        if failed.isEmpty {
            showToast(isMove ? "已移动 \(paths.count) 项" : "已复制 \(paths.count) 项")
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

    func delete(paths: Set<String>) async throws {
        guard let adapter else { return }
        do {
            try await adapter.mkdir("/.trash")
        } catch {
            // 目录已存在或创建失败均继续尝试移动
        }
        let stamp = Self.trashStamp()
        var movedPaths: [String] = []
        do {
            for sourcePath in paths.sorted() {
                guard let entry = entry(for: sourcePath) else { continue }
                let trashName = "\(stamp)-\(entry.name)"
                let trashPath = "/.trash/\(trashName)"
                try await adapter.move(sourcePath, trashPath)
                movedPaths.append(sourcePath)
                // 记录原路径元数据（§3.3 回收站还原用）
                await writeTrashMeta(adapter: adapter, trashPath: trashPath, entry: entry)
            }
        } catch {
            // 已移入回收站的文件同样清理阅读记录（回收站还原不还原记录，见 TODO §7.309 决策）
            if !movedPaths.isEmpty {
                ReadingHistoryStore.shared.remove(connectionID: connection.id ?? 0, filePaths: Set(movedPaths))
            }
            throw TrashError.unsupported
        }
        // 移入回收站即删除对应阅读记录（还原后无需还原记录，TODO §7.309）
        if !movedPaths.isEmpty {
            ReadingHistoryStore.shared.remove(connectionID: connection.id ?? 0, filePaths: Set(movedPaths))
        }
        await invalidateAndRefresh()
        endSelection()
        showToast("已移入回收站")
    }

    /// 彻底删除（回收站不可用时经用户确认的降级）
    func forceDelete(paths: Set<String>) async {
        guard let adapter else { return }
        var failed: [String] = []
        var deletedPaths: [String] = []
        for sourcePath in paths.sorted() {
            do {
                try await adapter.delete(sourcePath)
                deletedPaths.append(sourcePath)
            } catch {
                failed.append(StoragePath.fileName(of: sourcePath))
            }
        }
        // 彻底删除：同步清理阅读记录（TODO §7.309）
        if !deletedPaths.isEmpty {
            ReadingHistoryStore.shared.remove(connectionID: connection.id ?? 0, filePaths: Set(deletedPaths))
        }
        await invalidateAndRefresh()
        endSelection()
        if failed.isEmpty {
            showToast("已删除")
        } else {
            operationError = "删除失败：\(failed.joined(separator: "、"))"
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

    // MARK: - 收藏（IOS-107）：经 FavoritesStore 读写，收藏页与本页星标双向同步

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
