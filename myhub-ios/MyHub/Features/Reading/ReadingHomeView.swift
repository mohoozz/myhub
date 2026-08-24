import SwiftUI
import GRDB

/// 正在阅读首页（TODO §7，IOS-209）：
/// - 列表项：封面、标题、类型徽标、进度条、最后阅读时间；网格/列表两种视图（偏好持久化）；
/// - 点击恢复进度进入对应阅读器/播放器（精准续播/锚点定位/页码恢复由各自内核完成）；
/// - 长按进入多选模式（非仅弹菜单），底部操作栏「删除阅读记录」（已读完记录保留至手动删除）；
/// - 文案区分：视频「已看完」/ 音频「已听完」/ 漫画·小说「已读完」（默认「已读完」）；
/// - 进度上报后自动刷新（ReadingHistoryStore 订阅 playbackProgressDidChange 广播）。
struct ReadingHomeView: View {
    @EnvironmentObject private var history: ReadingHistoryStore
    @EnvironmentObject private var player: PlayerPresenter
    @EnvironmentObject private var novelReader: NovelReaderPresenter
    @EnvironmentObject private var comicReader: ComicReaderPresenter

    @State private var viewMode: BrowseViewMode = AppSettings.Reading.viewMode {
        didSet { AppSettings.Reading.viewMode = viewMode }
    }
    /// 多选模式：nil = 非多选；值为选中记录 id 集合
    @State private var selection: Set<Int64>?
    @State private var connections: [Int64: Connection] = [:]
    @State private var adapters: [Int64: StorageAdapter] = [:]
    @State private var resolved: [Int64: FileEntry] = [:]   // stat 后的最新条目（供文件指纹校验）
    @State private var resolving: Set<Int64> = []
    @State private var confirmDeleteIDs: [Int64]?
    @State private var message: String?

    private var isSelecting: Bool { selection != nil }

    var body: some View {
        NavigationStack {
            content
                .background(AppColors.pageBackground)
                .navigationTitle(isSelecting ? "已选 \(selection?.count ?? 0) 项" : "阅读")
                .toolbar { toolbar }
                .overlay(alignment: .bottom) { bottomOverlay }
        }
        .confirmationDialog(
            "删除阅读记录",
            isPresented: Binding(
                get: { confirmDeleteIDs != nil },
                set: { if !$0 { confirmDeleteIDs = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let ids = confirmDeleteIDs {
                    history.remove(ids: ids)
                    selection = nil
                }
                confirmDeleteIDs = nil
            }
            Button("取消", role: .cancel) { confirmDeleteIDs = nil }
        } message: {
            Text("将删除 \(confirmDeleteIDs?.count ?? 0) 条阅读记录（不影响源文件）")
        }
        .alert("提示", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("知道了", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
        .onAppear {
            history.reload()
            loadConnections()
            resolveAll()
        }
        .onReceive(history.$records) { _ in resolveAll() }
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        if history.records.isEmpty {
            emptyState
        } else {
            ScrollView {
                Group {
                    if viewMode == .grid {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 12)],
                            spacing: 12
                        ) {
                            ForEach(history.records) { record in
                                gridCell(record)
                            }
                        }
                        .padding(12)
                    } else {
                        LazyVStack(spacing: 6) {
                            ForEach(history.records) { record in
                                listRow(record)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
                .animation(.appQuick, value: viewMode)
                .padding(.bottom, isSelecting ? 64 : 0)   // 给多选操作栏留位
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("暂无阅读记录")
                .foregroundStyle(AppColors.textSecondary)
            Text("播放视频 / 音频或阅读小说 / 漫画后，会出现在这里")
                .font(.caption)
                .foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 网格单元格

    private func gridCell(_ record: ReadingProgress) -> some View {
        let entry = entry(for: record)
        let isSelected = isSelected(record)
        return Button {
            tap(record)
        } label: {
            VStack(spacing: 6) {
                ReadingCoverImage(
                    record: record, entry: entry,
                    connection: connections[record.connectionID],
                    adapter: adapters[record.connectionID]
                )
                .aspectRatio(1.35, contentMode: .fit)
                .background(AppColors.highlightBackground.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if !isSelecting {
                        MediaTypeBadge(type: record.mediaType).padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isSelecting {
                        SelectionCheckmark(isSelected: isSelected)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title(of: record))
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    progressLine(record)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(AppColors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(SelectableCellStyle())
        .hoverEffect(.highlight)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? AppColors.primary : Color.clear, lineWidth: 2)
        )
        .popupSecondaryMenu(menuItems(for: record))          // 指针右键菜单；长按进入多选
        .onLongPressGesture(minimumDuration: 0.5) { beginSelection(with: record) }
    }

    // MARK: - 列表行

    private func listRow(_ record: ReadingProgress) -> some View {
        let entry = entry(for: record)
        let isSelected = isSelected(record)
        return Button {
            tap(record)
        } label: {
            HStack(spacing: 12) {
                ReadingCoverImage(
                    record: record, entry: entry,
                    connection: connections[record.connectionID],
                    adapter: adapters[record.connectionID]
                )
                .frame(width: 52, height: 52)
                .background(AppColors.highlightBackground.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if !isSelecting {
                        MediaTypeBadge(type: record.mediaType)
                            .padding(3)
                            .scaleEffect(0.85, anchor: .topLeading)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title(of: record))
                        .font(.body)
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)
                    progressLine(record)
                }
                Spacer(minLength: 8)
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? AppColors.primary : AppColors.textSecondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(AppColors.cardBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(SelectableCellStyle(cornerRadius: 10))
        .hoverEffect(.highlight)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? AppColors.primary : Color.clear, lineWidth: 2)
        )
        .popupSecondaryMenu(menuItems(for: record))
        .onLongPressGesture(minimumDuration: 0.5) { beginSelection(with: record) }
    }

    /// 进度条 + 状态文案（已看完/已听完/已读完 或 百分比）+ 最后阅读时间
    private func progressLine(_ record: ReadingProgress) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: record.finished ? 1 : min(1, max(0, record.percent)))
                .tint(AppColors.primary)
            HStack {
                Text(record.finished ? finishedText(record.mediaType) : percentText(record))
                    .foregroundStyle(record.finished ? AppColors.primary : AppColors.textSecondary)
                Spacer()
                Text(DisplayFormatters.relative(record.updatedAt))
                    .foregroundStyle(AppColors.textSecondary)
            }
            .font(.caption2)
        }
    }

    private func percentText(_ record: ReadingProgress) -> String {
        "\(Int((min(1, max(0, record.percent)) * 100).rounded()))%"
    }

    /// 已读完文案：视频「已看完」/ 音频「已听完」/ 漫画·小说「已读完」（默认「已读完」）
    private func finishedText(_ type: MediaType) -> String {
        switch type {
        case .video: return "已看完"
        case .audio: return "已听完"
        default: return "已读完"
        }
    }

    private func title(of record: ReadingProgress) -> String {
        record.title.isEmpty ? StoragePath.fileName(of: record.filePath) : record.title
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("全选") {
                    selection = Set(history.records.compactMap(\.id))
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { selection = nil }
                    .fontWeight(.semibold)
            }
        } else {
            // 头像入口：点击直达个人主页（IOS-704）
            ToolbarItem(placement: .topBarLeading) {
                ProfileEntryButton()
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    viewMode = viewMode == .grid ? .list : .grid
                } label: {
                    Image(systemName: viewMode == .grid
                          ? BrowseViewMode.list.symbol : BrowseViewMode.grid.symbol)
                }
                PopupMenuButton(items: overflowItems)
            }
        }
    }

    /// 右上角 … 菜单（圆角 + 弹出动画，IOS-704）
    private var overflowItems: [PopupMenuItem] {
        [
            PopupMenuItem(title: "选择", systemImage: "checkmark.circle") {
                selection = []
            },
            PopupMenuItem(title: "刷新", systemImage: "arrow.clockwise") {
                history.reload()
            },
        ]
    }

    /// 右键操作菜单（iPad/PC 指针；iOS 长按进入多选）
    private func menuItems(for record: ReadingProgress) -> [PopupMenuItem] {
        [
            PopupMenuItem(
                title: record.mediaType == .video || record.mediaType == .audio ? "继续播放" : "继续阅读",
                systemImage: "play.circle"
            ) {
                open(record)
            },
            PopupMenuItem(title: "删除阅读记录", systemImage: "trash", destructive: true) {
                if let id = record.id { confirmDeleteIDs = [id] }
            },
        ]
    }

    // MARK: - 底部多选操作栏

    @ViewBuilder
    private var bottomOverlay: some View {
        VStack {
            if isSelecting {
                selectionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 10)
        .animation(.appQuick, value: isSelecting)
    }

    /// 多选操作栏：删除阅读记录（「标记已读完」已改为手动删除）
    private var selectionBar: some View {
        let count = selection?.count ?? 0
        return HStack(spacing: 0) {
            Button {
                if let selection, !selection.isEmpty {
                    confirmDeleteIDs = Array(selection)
                }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash")
                        .font(.body)
                    Text("删除阅读记录")
                        .font(.caption2)
                }
                .foregroundStyle(count > 0 ? Color.red : AppColors.textSecondary.opacity(0.5))
                .frame(maxWidth: .infinity)
            }
            .disabled(count == 0)
        }
        .padding(.vertical, 8)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppColors.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 12)
    }

    // MARK: - 交互

    private func tap(_ record: ReadingProgress) {
        if isSelecting {
            toggleSelection(record)
        } else {
            open(record)
        }
    }

    private func beginSelection(with record: ReadingProgress) {
        guard !isSelecting, let id = record.id else { return }
        selection = [id]
    }

    private func toggleSelection(_ record: ReadingProgress) {
        guard var set = selection, let id = record.id else { return }
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        selection = set
    }

    private func isSelected(_ record: ReadingProgress) -> Bool {
        guard let id = record.id else { return false }
        return selection?.contains(id) ?? false
    }

    /// 点击恢复进度进入对应阅读器/播放器
    private func open(_ record: ReadingProgress) {
        guard let connection = connections[record.connectionID] else {
            message = "连接源不可用（可能已删除）"
            return
        }
        let entry = entry(for: record)
        switch record.mediaType {
        case .video, .audio:
            // 精准续播：PlaybackSourceResolver 查历史进度直接从历史位置起播（TODO §4.2）
            player.play(connection: connection, entry: entry)
        case .novel:
            // 排版无关锚点一步定位恢复（TODO §5）
            novelReader.open(connection: connection, entry: entry)
        case .comic:
            // 直接恢复到上次页码（TODO §6）
            comicReader.open(connection: connection, entry: entry)
        case .image, .subtitle, .other:
            break   // 进度记录仅由播放/阅读内核产生，不会出现其他类型
        }
    }

    // MARK: - 数据解析

    /// 记录 → FileEntry（stat 成功用最新值——文件指纹校验依赖准确的 size/modTime；否则按记录构造兜底）
    private func entry(for record: ReadingProgress) -> FileEntry {
        if let resolved = resolved[record.id ?? -1] { return resolved }
        return FileEntry(
            name: StoragePath.fileName(of: record.filePath),
            path: record.filePath,
            isDir: false,
            size: 0,
            modTime: record.updatedAt,
            ext: StoragePath.ext(of: record.filePath)
        )
    }

    private func loadConnections() {
        guard let db = AppDatabase.shared.dbQueue else { return }
        let all = (try? db.read { try Connection.fetchAll($0) }) ?? []
        connections = Dictionary(uniqueKeysWithValues: all.compactMap { connection in
            connection.id.map { ($0, connection) }
        })
        adapters = Dictionary(uniqueKeysWithValues: all.compactMap { connection in
            guard let id = connection.id,
                  let adapter = try? AdapterFactory.makeAdapter(for: connection) else { return nil }
            return (id, adapter)
        })
    }

    /// 批量 stat 解析最新 FileEntry（限并发 3；失败落兜底条目，避免反复重试）
    private func resolveAll() {
        let targets = history.records.filter {
            let id = $0.id ?? -1
            return resolved[id] == nil && !resolving.contains(id)
        }
        guard !targets.isEmpty else { return }
        for record in targets.prefix(3) {
            guard let recordID = record.id,
                  let adapter = adapters[record.connectionID] else { continue }
            resolving.insert(recordID)
            Task { @MainActor in
                let entry = (try? await adapter.stat(record.filePath)) ?? entry(for: record)
                resolving.remove(recordID)
                resolved[recordID] = entry
                resolveAll()   // 继续下一批
            }
        }
    }
}

// MARK: - 类型徽标

/// 类型徽标（视频/音频/漫画/小说）
private struct MediaTypeBadge: View {
    let type: MediaType

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(AppColors.primary)
            .clipShape(Capsule())
    }

    private var text: String {
        switch type {
        case .video: return "视频"
        case .audio: return "音频"
        case .novel: return "小说"
        case .comic: return "漫画"
        case .image: return "图片"
        case .subtitle: return "字幕"
        case .other: return "其他"
        }
    }
}

// MARK: - 封面

/// 正在阅读封面（与浏览页一致，IOS-702）：
/// 优先进度记录内嵌的缩略图缓存（epub/漫画阅读时提取写入 Caches/Thumbnails，零网络秒出）；
/// 否则复用浏览页 `RemoteCoverImage` 异步加载（占位先行、失败占位、不阻塞点击进入）。
private struct ReadingCoverImage: View {
    let record: ReadingProgress
    let entry: FileEntry
    let connection: Connection?
    let adapter: StorageAdapter?

    @State private var cachedImage: UIImage?
    @State private var probed = false

    var body: some View {
        ZStack {
            AppColors.cardBackground
            if let cachedImage {
                Image(uiImage: cachedImage)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else if probed {
                fallback
            } else {
                Image(systemName: entry.placeholderSymbol)
                    .font(.title2)
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
        .clipped()
        .task(id: record.cover) {
            guard let name = record.cover else {
                probed = true
                return
            }
            let url = CacheManager.shared.url(for: .thumbnails).appendingPathComponent(name)
            let image = await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: url.path)
            }.value
            withAnimation(.appQuick) {
                cachedImage = image
                probed = true
            }
        }
    }

    @ViewBuilder
    private var fallback: some View {
        if let connection, let adapter {
            RemoteCoverImage(entry: entry, connection: connection, adapter: adapter)
        } else {
            Image(systemName: entry.placeholderSymbol)
                .font(.title2)
                .foregroundStyle(AppColors.textSecondary)
        }
    }
}
