import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

/// 浏览导航位置（连接源内某目录）
struct BrowseLocation: Hashable, Codable {
    var connectionID: Int64
    var path: String
}

/// 目录浏览页（IOS-102 浏览 + IOS-103~105 文件操作）：
/// - 面包屑 + 搜索 + 视图切换 + 排序 + 上传（文件/相册）+ 下拉刷新 + 空/加载/错误状态；
/// - 长按（iOS，底部抽屉菜单）/ 指针右键（iPad/PC，锚点菜单）弹操作菜单；多选经菜单「多选」或右上角「…」→「选择」进入，底部操作栏：移动/复制/重命名/下载/收藏/删除；
/// - NavigationStack 系统交互式 pop 返回上一级。
struct BrowseDirectoryView: View {
    let connection: Connection
    let path: String
    @Binding var navPath: NavigationPath
    /// 「定位到原路径」目标文件全路径：命中单元格呼吸灯高亮（由 BrowseHomeView 约 10s 后清除）
    let highlightPath: String?
    /// 可用连接源（移动/复制跨源目标选择）
    var connections: [Connection] = []

    @StateObject private var viewModel: BrowseDirectoryViewModel
    @EnvironmentObject private var player: PlayerPresenter
    @EnvironmentObject private var novelReader: NovelReaderPresenter
    @EnvironmentObject private var comicReader: ComicReaderPresenter
    @EnvironmentObject private var txtReader: TxtReaderPresenter
    /// 阅读进度记录（用于文件项进度环，参考 Flutter 浏览界面）
    @ObservedObject private var readingHistory = ReadingHistoryStore.shared
    /// 播放引擎状态（区分播放中/暂停，仅播放中才高亮）
    @ObservedObject private var playerCore = PlayerCore.shared

    @State private var sheet: SheetRoute?
    @State private var imagePreview: ImagePreviewContext?
    @State private var unsupportedEntry: FileEntry?
    @State private var renaming: FileEntry?
    @State private var renameText = ""
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var showImporter = false
    @State private var showPhotosPicker = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var deletingPaths: Set<String>?
    @State private var forceDeletePaths: Set<String>?

    init(
        connection: Connection,
        path: String,
        navPath: Binding<NavigationPath>,
        highlightPath: String?,
        connections: [Connection] = []
    ) {
        self.connection = connection
        self.path = StoragePath.normalize(path)
        self._navPath = navPath
        self.highlightPath = highlightPath
        self.connections = connections
        _viewModel = StateObject(
            wrappedValue: BrowseDirectoryViewModel(connection: connection, path: path)
        )
    }

    private var connectionID: Int64 { connection.id ?? 0 }

    /// 当前连接源下 `filePath -> percent(0~1)` 进度映射（无记录的文件取不到即为 nil）
    private var progressByPath: [String: Double] {
        var map: [String: Double] = [:]
        for record in readingHistory.records where record.connectionID == connectionID {
            map[record.filePath] = record.percent
        }
        return map
    }

    /// 该文件项是否正在（mini）播放器播放：来源连接匹配 + 路径匹配 + 引擎处于播放态
    private func isPlaying(_ entry: FileEntry) -> Bool {
        guard let current = player.current else { return false }
        return current.connectionID == connection.id
            && current.path == entry.path
            && playerCore.isPlaying
    }

    private enum SheetRoute: Identifiable {
        case move(Set<String>)
        case copy(Set<String>)
        case editText(FileEntry)
        case viewText(FileEntry)
        case share(URL)

        var id: String {
            switch self {
            case .move: return "move"
            case .copy: return "copy"
            case .editText(let entry): return "edit-\(entry.path)"
            case .viewText(let entry): return "view-\(entry.path)"
            case .share(let url): return "share-\(url.absoluteString)"
            }
        }
    }

    private struct ImagePreviewContext: Identifiable {
        let id = UUID()
        var images: [FileEntry]
        var index: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbBar(
                connectionName: connection.name,
                path: viewModel.path,
                onSelect: navigateToCrumb
            )
            Divider().overlay(AppColors.separator)

            content
        }
        .background(AppColors.pageBackground)
        // 普通浏览态隐藏导航栏标题：当前目录/路径已由正文顶部面包屑承载，避免与面包屑重复、令导航栏更清爽；
        // 仅多选态保留「已选 N 项」作为操作状态反馈。
        .navigationTitle(viewModel.isSelecting ? "已选 \(viewModel.selection?.count ?? 0) 项" : "")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $viewModel.searchText, prompt: "搜索当前目录")
        .toolbar { toolbar }
        .overlay(alignment: .bottom) { bottomOverlay }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task { await viewModel.upload(urls: urls) }
            }
        }
        .photosPicker(isPresented: $showPhotosPicker, selection: $photoSelection, matching: .any(of: [.images, .videos]))
        .onChange(of: photoSelection) { items in
            guard !items.isEmpty else { return }
            photoSelection = []
            Task {
                var imports: [PhotoImport] = []
                for item in items {
                    if let imported = try? await item.loadTransferable(type: PhotoImport.self) {
                        imports.append(imported)
                    }
                }
                await viewModel.upload(imports: imports)
            }
        }
        .sheet(item: $sheet) { route in
            switch route {
            case .move(let paths):
                DestinationPickerView(
                    title: "移动到", connections: availableConnections, initialConnectionID: connectionID
                ) { destination, dir in
                    Task { await viewModel.move(paths: paths, to: destination, at: dir) }
                }
            case .copy(let paths):
                DestinationPickerView(
                    title: "复制到", connections: availableConnections, initialConnectionID: connectionID
                ) { destination, dir in
                    Task { await viewModel.copy(paths: paths, to: destination, at: dir) }
                }
            case .editText(let entry):
                if let adapter = viewModel.storageAdapter {
                    TextFileEditorView(entry: entry, adapter: adapter) {
                        Task { await viewModel.refresh() }
                    }
                }
            case .viewText(let entry):
                if let adapter = viewModel.storageAdapter {
                    TextFileViewer(entry: entry, adapter: adapter)
                }
            case .share(let url):
                ActivityView(url: url)
                    .onDisappear { try? FileManager.default.removeItem(at: url) }
            }
        }
        .fullScreenCover(item: $imagePreview) { context in
            if let adapter = viewModel.storageAdapter {
                ImagePreviewView(images: context.images, initialIndex: context.index, adapter: adapter)
            }
        }
        .confirmationDialog(
            unsupportedEntry?.name ?? "",
            isPresented: Binding(get: { unsupportedEntry != nil }, set: { if !$0 { unsupportedEntry = nil } }),
            titleVisibility: .visible
        ) {
            Button("纯文本查看") {
                if let entry = unsupportedEntry { sheet = .viewText(entry) }
                unsupportedEntry = nil
            }
            Button("下载到本地") {
                if let entry = unsupportedEntry {
                    Task { await viewModel.downloadToLocal(paths: [entry.path]) }
                }
                unsupportedEntry = nil
            }
            Button("取消", role: .cancel) { unsupportedEntry = nil }
        }
        .confirmationDialog(
            "删除确认",
            isPresented: Binding(get: { deletingPaths != nil }, set: { if !$0 { deletingPaths = nil } }),
            titleVisibility: .visible
        ) {
            Button("移入回收站", role: .destructive) {
                if let paths = deletingPaths {
                    Task {
                        do {
                            try await viewModel.delete(paths: paths)
                        } catch {
                            forceDeletePaths = paths   // 回收站不可用 → 降级真删确认
                        }
                    }
                }
                deletingPaths = nil
            }
            Button("取消", role: .cancel) { deletingPaths = nil }
        } message: {
            Text("将删除 \(deletingPaths?.count ?? 0) 个项目（保留 \(AppSettings.Trash.retentionDays) 天，可在回收站还原）")
        }
        .confirmationDialog(
            "无法使用回收站",
            isPresented: Binding(get: { forceDeletePaths != nil }, set: { if !$0 { forceDeletePaths = nil } }),
            titleVisibility: .visible
        ) {
            Button("彻底删除", role: .destructive) {
                if let paths = forceDeletePaths {
                    Task { await viewModel.forceDelete(paths: paths) }
                }
                forceDeletePaths = nil
            }
            Button("取消", role: .cancel) { forceDeletePaths = nil }
        } message: {
            Text("该连接源不支持回收站，将直接彻底删除 \(forceDeletePaths?.count ?? 0) 个项目，不可恢复。")
        }
        .alert("重命名", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("名称", text: $renameText)
            Button("确定") {
                if let entry = renaming {
                    Task { await viewModel.rename(entry, to: renameText) }
                }
                renaming = nil
            }
            Button("取消", role: .cancel) { renaming = nil }
        }
        .alert("新建文件夹", isPresented: $showNewFolder) {
            TextField("文件夹名称", text: $newFolderName)
            Button("创建") {
                Task { await viewModel.createFolder(named: newFolderName) }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("提示", isPresented: Binding(
            get: { viewModel.operationError != nil },
            set: { if !$0 { viewModel.operationError = nil } }
        )) {
            Button("知道了", role: .cancel) { viewModel.operationError = nil }
        } message: {
            Text(viewModel.operationError ?? "")
        }
        .task {
            await viewModel.loadIfNeeded()
            readingHistory.reload()   // 首次进入时预载阅读进度（后续经 .playbackProgressDidChange 自动刷新）
        }
    }

    private var availableConnections: [Connection] {
        connections.isEmpty ? [connection] : connections
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        ScrollView {
            switch viewModel.state {
            case .loading:
                loadingState
            case .failed(let message):
                errorState(message)
            case .empty:
                emptyState
            case .loaded:
                if let adapter = viewModel.storageAdapter {
                    fileCollection(adapter: adapter)
                }
            }
        }
        .refreshable { await viewModel.refresh() }
    }

    private func fileCollection(adapter: StorageAdapter) -> some View {
        let items = viewModel.displayedEntries
        return Group {
            if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("没有匹配「\(viewModel.searchText)」的内容")
                        .foregroundStyle(AppColors.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else if viewModel.viewMode == .grid {
                gridView(items, adapter: adapter)
            } else {
                listView(items, adapter: adapter)
            }
        }
        .animation(.appQuick, value: viewModel.viewMode)
        .padding(.bottom, viewModel.isSelecting ? 64 : 0)   // 给多选操作栏留位
    }

    private func gridView(_ items: [FileEntry], adapter: StorageAdapter) -> some View {
        let progressMap = progressByPath
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 12)],
            spacing: 12
        ) {
            ForEach(items, id: \.path) { entry in
                FileGridCell(
                    entry: entry,
                    connection: connection,
                    adapter: adapter,
                    siblings: viewModel.entries,
                    childCount: viewModel.childCounts[entry.path],
                    highlighted: entry.path == highlightPath,
                    isSelecting: viewModel.isSelecting,
                    isSelected: viewModel.selection?.contains(entry.path) ?? false,
                    progress: entry.isDir ? nil : progressMap[entry.path],
                    isPlaying: isPlaying(entry),
                    menuItems: contextMenuItems(for: entry),
                    onTap: { tap(entry) }
                )
                .onAppear { viewModel.loadChildCountIfNeeded(for: entry) }
            }
        }
        .padding(12)
    }

    private func listView(_ items: [FileEntry], adapter: StorageAdapter) -> some View {
        let progressMap = progressByPath
        return LazyVStack(spacing: 0) {
            ForEach(items, id: \.path) { entry in
                FileListRow(
                    entry: entry,
                    connection: connection,
                    adapter: adapter,
                    siblings: viewModel.entries,
                    childCount: viewModel.childCounts[entry.path],
                    highlighted: entry.path == highlightPath,
                    isSelecting: viewModel.isSelecting,
                    isSelected: viewModel.selection?.contains(entry.path) ?? false,
                    progress: entry.isDir ? nil : progressMap[entry.path],
                    isPlaying: isPlaying(entry),
                    menuItems: contextMenuItems(for: entry),
                    onTap: { tap(entry) }
                )
                .onAppear { viewModel.loadChildCountIfNeeded(for: entry) }
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - 状态视图

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在加载…")
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("加载失败")
                .font(.headline)
                .foregroundStyle(AppColors.textPrimary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("重试") {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("空文件夹")
                .foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    // MARK: - 底部覆盖层（多选操作栏 / 传输横幅 / 轻提示）

    @ViewBuilder
    private var bottomOverlay: some View {
        VStack(spacing: 8) {
            if let transfer = viewModel.transfer {
                transferBanner(transfer)
            }
            if let toast = viewModel.toast {
                Text(toast)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.75))
                    .clipShape(Capsule())
                    .transition(.opacity)
            }
            if viewModel.isSelecting {
                selectionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 10)
        .animation(.appQuick, value: viewModel.isSelecting)
        .animation(.appQuick, value: viewModel.toast)
    }

    private func transferBanner(_ progress: BrowseDirectoryViewModel.TransferProgress) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("\(progress.title) \(progress.current)/\(progress.total)：\(progress.fileName)")
                    .font(.caption)
                    .lineLimit(1)
            }
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .tint(AppColors.primary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(AppColors.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
        .padding(.horizontal, 24)
    }

    /// 多选操作栏：移动/复制/重命名/下载/收藏/删除（等分布局，不超出手机屏幕）
    private var selectionBar: some View {
        let count = viewModel.selection?.count ?? 0
        return HStack(spacing: 0) {
            selectionButton("移动", symbol: "arrow.right.doc.on.clipboard", enabled: count > 0) {
                if let paths = viewModel.selection { sheet = .move(paths) }
            }
            selectionButton("复制", symbol: "doc.on.doc", enabled: count > 0) {
                if let paths = viewModel.selection { sheet = .copy(paths) }
            }
            selectionButton("重命名", symbol: "pencil", enabled: count == 1) {
                if let path = viewModel.selection?.first, let entry = viewModel.entry(for: path) {
                    renameText = entry.name
                    renaming = entry
                }
            }
            selectionButton("下载", symbol: "arrow.down.circle", enabled: count > 0) {
                if let paths = viewModel.selection {
                    Task { await viewModel.downloadToLocal(paths: paths) }
                }
            }
            selectionButton("收藏", symbol: "star", enabled: count > 0) {
                if let paths = viewModel.selection { viewModel.favoriteSelected(paths) }
            }
            selectionButton("删除", symbol: "trash", enabled: count > 0, destructive: true) {
                deletingPaths = viewModel.selection
            }
        }
        .padding(.vertical, 8)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppColors.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 12)
    }

    private func selectionButton(
        _ title: String, symbol: String, enabled: Bool,
        destructive: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.body)
                Text(title)
                    .font(.caption2)
            }
            .foregroundStyle(enabled ? (destructive ? Color.red : AppColors.primary) : AppColors.textSecondary.opacity(0.5))
            .frame(maxWidth: .infinity)
        }
        .disabled(!enabled)
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if viewModel.isSelecting {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("全选") { viewModel.selectAll() }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { viewModel.endSelection() }
                    .fontWeight(.semibold)
            }
        } else {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                PopupMenuButton(items: addItems, symbol: "plus")

                Button {
                    viewModel.viewMode = viewModel.viewMode == .grid ? .list : .grid
                } label: {
                    Image(systemName: viewModel.viewMode == .grid
                          ? BrowseViewMode.list.symbol : BrowseViewMode.grid.symbol)
                }

                PopupMenuButton(items: overflowItems)
            }
        }
    }

    /// ＋菜单：上传文件 / 从相册上传 / 新建文件夹
    private var addItems: [PopupMenuItem] {
        [
            PopupMenuItem(title: "上传文件", systemImage: "doc.badge.plus") {
                showImporter = true
            },
            PopupMenuItem(title: "从相册上传", systemImage: "photo.on.rectangle") {
                showPhotosPicker = true
            },
            PopupMenuItem(title: "新建文件夹", systemImage: "folder.badge.plus") {
                newFolderName = ""
                showNewFolder = true
            },
        ]
    }

    /// 右上角 … 菜单（圆角 + 弹出动画，IOS-704）：排序 / 升降序 / 多选 / 刷新
    private var overflowItems: [PopupMenuItem] {
        var items: [PopupMenuItem] = BrowseSortKey.allCases.map { key in
            PopupMenuItem(
                title: (viewModel.sortKey == key ? "✓ " : "") + "按" + key.displayName,
                systemImage: "arrow.up.arrow.down"
            ) {
                if viewModel.sortKey == key {
                    viewModel.sortAscending.toggle()
                } else {
                    viewModel.sortKey = key
                }
            }
        }
        items.append(PopupMenuItem(
            title: viewModel.sortAscending ? "✓ 升序" : "✓ 降序",
            systemImage: viewModel.sortAscending ? "chevron.up" : "chevron.down"
        ) {
            viewModel.sortAscending.toggle()
        })
        items.append(PopupMenuItem(title: "选择", systemImage: "checkmark.circle") {
            viewModel.selection = []
        })
        items.append(PopupMenuItem(title: "刷新", systemImage: "arrow.clockwise") {
            Task { await viewModel.refresh() }
        })
        return items
    }

    // MARK: - 操作菜单（长按 / 指针右键）

    private func contextMenuItems(for entry: FileEntry) -> [PopupMenuItem] {
        let type = MediaType.detect(ext: entry.ext)
        var items: [PopupMenuItem] = [
            PopupMenuItem(title: entry.isDir ? "进入" : "打开", systemImage: "arrow.right.circle") {
                tap(entry)
            },
        ]
        if type == .novel, entry.ext == "txt" {
            // txt 默认已走纯 txt 阅读器，这里提供「以小说阅读器打开」切换章节/进度阅读
            items.append(PopupMenuItem(title: "以小说阅读器打开", systemImage: "book") {
                novelReader.open(connection: connection, entry: entry)
            })
            items.append(PopupMenuItem(title: "在线编辑", systemImage: "square.and.pencil") {
                sheet = .editText(entry)
            })
        }
        // 手动覆盖（IOS-207 漫画识别策略 4）：zip/rar/epub 可强制以漫画阅读器打开
        if !entry.isDir, ["zip", "rar", "epub"].contains(entry.ext), type != .comic {
            items.append(PopupMenuItem(title: "以漫画阅读打开", systemImage: "photo.stack") {
                comicReader.open(connection: connection, entry: entry)
            })
        }
        if !entry.isDir, type == .subtitle || type == .other {
            items.append(PopupMenuItem(title: "纯文本查看", systemImage: "doc.plaintext") {
                sheet = .viewText(entry)
            })
        }
        items.append(PopupMenuItem(
            title: viewModel.favoritePaths.contains(entry.path) ? "取消收藏" : "收藏",
            systemImage: viewModel.favoritePaths.contains(entry.path) ? "star.fill" : "star"
        ) {
            viewModel.toggleFavorite(entry)
        })
        items.append(PopupMenuItem(title: "重命名", systemImage: "pencil") {
            renameText = entry.name
            renaming = entry
        })
        items.append(PopupMenuItem(title: "移动到…", systemImage: "arrow.right.doc.on.clipboard") {
            sheet = .move([entry.path])
        })
        items.append(PopupMenuItem(title: "复制到…", systemImage: "doc.on.doc") {
            sheet = .copy([entry.path])
        })
        if !entry.isDir {
            items.append(PopupMenuItem(title: "下载到本地", systemImage: "arrow.down.circle") {
                Task { await viewModel.downloadToLocal(paths: [entry.path]) }
            })
            items.append(PopupMenuItem(title: "存储到「文件」", systemImage: "folder") {
                Task {
                    do {
                        let url = try await viewModel.downloadToTemp(entry)
                        sheet = .share(url)
                    } catch {
                        viewModel.operationError = "准备文件失败：\(error.localizedDescription)"
                    }
                }
            })
            // 仅图片类型可保存到相册
            if type == .image {
                items.append(PopupMenuItem(title: "保存到相册", systemImage: "photo.on.rectangle") {
                    Task {
                        do {
                            try await viewModel.saveToPhotos(entry)
                        } catch {
                            viewModel.operationError = "保存到相册失败：\(error.localizedDescription)"
                        }
                    }
                })
            }
        }
        // 多选：与右上角「…」→「选择」一致（进入多选，不预选）
        items.append(PopupMenuItem(title: "多选", systemImage: "checkmark.circle") {
            viewModel.selection = []
        })
        items.append(PopupMenuItem(title: "删除", systemImage: "trash", destructive: true) {
            deletingPaths = [entry.path]
        })
        return items
    }

    // MARK: - 交互

    /// 点击：多选模式下切换选中；否则打开
    private func tap(_ entry: FileEntry) {
        if viewModel.isSelecting {
            viewModel.toggleSelection(entry)
        } else {
            open(entry)
        }
    }

    /// 面包屑回跳：crumb 深度 d 对应导航栈第 d+1 层（第 1 层为连接根目录）
    private func navigateToCrumb(depth: Int) {
        let remove = navPath.count - (depth + 1)
        guard remove > 0 else { return }
        navPath.removeLast(remove)
    }

    private func open(_ entry: FileEntry) {
        if entry.isDir {
            navPath.append(BrowseLocation(connectionID: connectionID, path: entry.path))
            return
        }
        switch MediaType.detect(ext: entry.ext) {
        case .video, .audio:
            // 解析数据源（本地 file:// / 边下边播代理）+ 历史进度恢复（TODO §4.2）
            player.play(connection: connection, entry: entry)
        case .image:
            // 纯图片预览（独立界面）：同目录图片自然序，定位到当前张
            let images = viewModel.entries
                .filter { !$0.isDir && MediaType.detect(ext: $0.ext) == .image }
                .sorted { $0.name.naturalCompare($1.name) == .orderedAscending }
            if let index = images.firstIndex(where: { $0.path == entry.path }) {
                imagePreview = ImagePreviewContext(images: images, index: index)
            }
        case .novel:
            // txt 默认走纯 txt 阅读器（全文滚动）；epub 走小说阅读器（章节/进度）
            if entry.ext == "txt" {
                txtReader.open(connection: connection, entry: entry)
            } else {
                novelReader.open(connection: connection, entry: entry)
            }
        case .comic:
            // 漫画阅读器（TODO §6）：先展示加载 UI，再后台解析归档（弱网不卡顿）+ 点击防抖
            comicReader.open(connection: connection, entry: entry)
        case .subtitle, .other:
            // 不支持预览的文件：底部菜单 → 纯文本查看 / 下载
            unsupportedEntry = entry
        }
    }
}

// MARK: - 面包屑

/// 面包屑路径导航（IOS-102）：连接名 / 逐级目录，点击回跳
private struct BreadcrumbBar: View {
    let connectionName: String
    let path: String
    let onSelect: (Int) -> Void

    private var crumbs: [String] {
        [connectionName] + path.split(separator: "/").map(String.init)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    Button {
                        onSelect(index)
                    } label: {
                        Text(crumb)
                            .font(.subheadline)
                            .foregroundStyle(index == crumbs.count - 1
                                             ? AppColors.textPrimary : AppColors.primary)
                            .lineLimit(1)
                    }
                    .disabled(index == crumbs.count - 1)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}
