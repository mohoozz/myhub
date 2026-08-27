import SwiftUI
import GRDB

/// 正在阅读首页（TODO §7，IOS-209）：
/// - 列表项：封面、标题、类型徽标、进度条、最后阅读时间；网格/列表两种视图（偏好持久化）；
/// - 点击恢复进度进入对应阅读器/播放器（精准续播/锚点定位/页码恢复由各自内核完成）；
/// - 长按弹底部抽屉菜单（含「多选」入口），多选时底部操作栏「删除阅读记录」（不影响源文件）/「删除源文件」（优先移入回收站，回收站不可用时彻底删除）；
/// - 文案区分：视频「已看完」/ 音频「已听完」/ 漫画·小说「已读完」（默认「已读完」）；
/// - 进度上报后自动刷新（ReadingHistoryStore 订阅 playbackProgressDidChange 广播）。
struct ReadingHomeView: View {
    @EnvironmentObject private var history: ReadingHistoryStore
    @EnvironmentObject private var player: PlayerPresenter
    @EnvironmentObject private var novelReader: NovelReaderPresenter
    @EnvironmentObject private var comicReader: ComicReaderPresenter
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var locator: BrowseLocator

    @AppStorage("ui.liquidGlassMode") private var liquidGlassMode = true

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
    /// 「删除源文件」确认：优先移入回收站；回收站不可用时降级「彻底删除」确认（与浏览界面一致）
    @State private var deletingSourceIDs: [Int64]?
    @State private var forceDeletingSourceIDs: [Int64]?
    @State private var message: String?
    /// 长按菜单 →「属性」：当前展示属性页的记录
    @State private var infoRecord: ReadingProgress?

    private var isSelecting: Bool { selection != nil }

    var body: some View {
        NavigationStack {
            content
                .background(AppColors.pageBackground)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                // 多选态标题居中；常态用 .editor 令「阅读」大标题左对齐（与其余标签一致）。
                // 液体玻璃按钮背景由工具栏项各自的 .liquidGlassToolbar 控制。
                .toolbarRole(isSelecting ? .navigationStack : .editor)
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
        .confirmationDialog(
            "删除源文件",
            isPresented: Binding(
                get: { deletingSourceIDs != nil },
                set: { if !$0 { deletingSourceIDs = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("移入回收站", role: .destructive) {
                if let ids = deletingSourceIDs {
                    Task {
                        do {
                            let moved = try await deleteSourceFiles(ids: ids)
                            message = moved == ids.count
                                ? "已将 \(ids.count) 个源文件移入回收站，并清理阅读记录"
                                : "已将 \(moved) 个源文件移入回收站（\(ids.count - moved) 个源文件已不存在），并清理阅读记录"
                        } catch {
                            forceDeletingSourceIDs = ids   // 回收站不可用 → 降级为彻底删除确认
                        }
                    }
                }
                deletingSourceIDs = nil
            }
            Button("取消", role: .cancel) { deletingSourceIDs = nil }
        } message: {
            Text("将删除 \(deletingSourceIDs?.count ?? 0) 个源文件及对应阅读记录（保留 \(AppSettings.Trash.retentionDays) 天，可在回收站还原）")
        }
        .confirmationDialog(
            "无法使用回收站",
            isPresented: Binding(
                get: { forceDeletingSourceIDs != nil },
                set: { if !$0 { forceDeletingSourceIDs = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("彻底删除", role: .destructive) {
                if let ids = forceDeletingSourceIDs {
                    Task { await forceDeleteSourceFiles(ids: ids) }
                }
                forceDeletingSourceIDs = nil
            }
            Button("取消", role: .cancel) { forceDeletingSourceIDs = nil }
        } message: {
            Text("连接源不支持回收站，将彻底删除 \(forceDeletingSourceIDs?.count ?? 0) 个源文件及其阅读记录，不可恢复。")
        }
        .alert("提示", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("知道了", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
        .sheet(item: $infoRecord) { record in
            ReadingFileInfoView(
                record: record,
                connection: connections[record.connectionID],
                adapter: adapters[record.connectionID]
            )
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
                            // 参照旧版 Flutter：卡片最大宽 320（iPhone 上两列横卡）
                            columns: [GridItem(.adaptive(minimum: 160, maximum: 320), spacing: 12)],
                            spacing: 12
                        ) {
                            ForEach(history.records) { record in
                                gridCell(record)
                            }
                        }
                        .padding(12)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(history.records) { record in
                                listRow(record)
                            }
                        }
                        .padding(.horizontal, 12)
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

    /// 网格卡（参照旧版 Flutter）：封面铺满整卡 + 左深右浅渐变蒙层，
    /// 标题/进度白字叠加在封面上，类型徽标在右上角，底部白色细进度条
    private func gridCell(_ record: ReadingProgress) -> some View {
        let entry = entry(for: record)
        let isSelected = isSelected(record)
        return ZStack(alignment: .topLeading) {
            ReadingCoverImage(
                record: record, entry: entry,
                connection: connections[record.connectionID],
                adapter: adapters[record.connectionID],
                immersive: true
            )

            // 左深右浅蒙层，保证白字可读
            LinearGradient(
                colors: [.black.opacity(0.55), .black.opacity(0.15)],
                startPoint: .leading,
                endPoint: .trailing
            )

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: entry.placeholderSymbol)
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    if !isSelecting {
                        MediaTypeBadge(type: record.mediaType)
                    }
                }
                Text(title(of: record))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 4)
                Spacer(minLength: 8)
                HStack(alignment: .center, spacing: 8) {
                    Text(DisplayFormatters.relative(record.updatedAt))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if record.finished || record.percent > 0 {
                        progressRing(record, textColor: .white, emphasizedColor: .white)
                    }
                }
            }
            .padding(10)
        }
        .aspectRatio(1.28, contentMode: .fit)   // Flutter：cellHeight = cellWidth × 0.78
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .hoverEffect(.highlight)
        .overlay(alignment: .topTrailing) {
            if isSelecting {
                SelectionCheckmark(isSelected: isSelected)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? AppColors.primary : Color.white.opacity(0.08),
                        lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        .cellPressableMenu(
            cornerRadius: 14,
            highlightShape: .circle,
            items: menuItems(for: record),
            onTap: { tap(record) }   // 长按弹底部抽屉菜单；指针右键弹锚点菜单
        )
    }

    // MARK: - 列表行

    private func listRow(_ record: ReadingProgress) -> some View {
        let entry = entry(for: record)
        let isSelected = isSelected(record)
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                ReadingCoverImage(
                    record: record, entry: entry,
                    connection: connections[record.connectionID],
                    adapter: adapters[record.connectionID]
                )
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title(of: record))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)
                    Text(subtitle(for: record))
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 8)
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? AppColors.primary : AppColors.textSecondary)
                } else if record.finished || record.percent > 0 {
                    progressRing(record)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .hoverEffect(.highlight)
            .background(
                isSelected ? AppColors.primary.opacity(0.08) : Color.clear
            )
            .cellPressableMenu(
                cornerRadius: 0,
                highlightShape: .circle,
                items: menuItems(for: record),
                onTap: { tap(record) }
            )

            // 分割线（参照 Flutter iOS，缩进从封面右侧开始）
            Rectangle()
                .fill(AppColors.separator)
                .frame(height: 0.5)
                .padding(.leading, 76)
        }
    }

    /// 饼状图进度条（参考浏览界面的饼状图进度条）：环形进度从 12 点方向顺时针填充，
    /// 百分比/状态文案（已看完/已听完/已读完 或 百分比）显示在饼状图下面。
    private func progressRing(
        _ record: ReadingProgress,
        textColor: Color = AppColors.textSecondary,
        emphasizedColor: Color = AppColors.primary
    ) -> some View {
        VStack(spacing: 6) {
            ReadingProgressRing(percent: record.finished ? 1 : record.percent, size: 22)
            Text(record.finished ? finishedText(record.mediaType) : percentText(record))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(record.finished ? emphasizedColor : textColor)
                .fixedSize()
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

    /// 副标题：源名 · 类型 · 日期（参照 Flutter iOS）
    private func subtitle(for record: ReadingProgress) -> String {
        var parts: [String] = []
        if let name = connections[record.connectionID]?.name, !name.isEmpty {
            parts.append(name)
        }
        parts.append(record.mediaType.label)
        parts.append(DisplayFormatters.shortDate(record.updatedAt))
        return parts.joined(separator: " · ")
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
            .liquidGlassToolbar(liquidGlassMode)
            ToolbarItem(placement: .principal) {
                Text("已选 \(selection?.count ?? 0) 项")
                    .font(.headline)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { selection = nil }
                    .fontWeight(.semibold)
            }
            .liquidGlassToolbar(liquidGlassMode)
        } else {
            ToolbarItem(placement: .principal) {
                Text("阅读")
                    .font(.title.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if !history.records.isEmpty {
                    Text("\(history.records.count) 项")
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }
                PopupMenuButton(items: overflowItems)
            }
            .liquidGlassToolbar(liquidGlassMode)
        }
    }

    /// 右上角 … 菜单（圆角 + 弹出动画，IOS-704）
    private var overflowItems: [PopupMenuItem] {
        [
            PopupMenuItem(
                title: viewMode == .grid ? "列表视图" : "网格视图",
                systemImage: viewMode == .grid ? BrowseViewMode.list.symbol : BrowseViewMode.grid.symbol
            ) {
                viewMode = viewMode == .grid ? .list : .grid
            },
            PopupMenuItem(title: "选择", systemImage: "checkmark.circle") {
                selection = []
            },
            PopupMenuItem(title: "刷新", systemImage: "arrow.clockwise") {
                history.reload()
            },
        ]
    }

    /// 长按（iOS，底部抽屉）/ 指针右键（iPad/PC，锚点卡片）操作菜单
    private func menuItems(for record: ReadingProgress) -> [PopupMenuItem] {
        [
            PopupMenuItem(
                title: record.mediaType == .video || record.mediaType == .audio ? "继续播放" : "继续阅读",
                systemImage: "play.circle"
            ) {
                open(record)
            },
            // 多选：与右上角「…」→「选择」一致（进入多选，不预选）
            PopupMenuItem(title: "多选", systemImage: "checkmark.circle") {
                selection = []
            },
            // 定位到源路径位置：切到浏览页并呼吸灯高亮源文件所在目录（参照 Flutter 端与收藏页「在浏览中定位」）
            PopupMenuItem(title: "定位到源路径位置", systemImage: "scope") {
                locate(record)
            },
            // 属性：展示文件信息（长按菜单 → 属性）
            PopupMenuItem(title: "属性", systemImage: "info.circle") {
                infoRecord = record
            },
            PopupMenuItem(title: "删除源文件", systemImage: "trash.slash", destructive: true) {
                if let id = record.id { deletingSourceIDs = [id] }
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

    /// 多选操作栏：删除阅读记录（不影响源文件）/ 删除源文件（优先移入回收站，不可用时彻底删除）
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

            Rectangle()
                .fill(AppColors.separator)
                .frame(width: 0.5, height: 34)

            Button {
                if let selection, !selection.isEmpty {
                    deletingSourceIDs = Array(selection)
                }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash.slash")
                        .font(.body)
                    Text("删除源文件")
                        .font(.caption2)
                }
                .foregroundStyle(count > 0 ? Color.red : AppColors.textSecondary.opacity(0.5))
                .frame(maxWidth: .infinity)
            }
            .disabled(count == 0)
        }
        .padding(.vertical, 8)
        .background(selectionBarBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppColors.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 12)
    }

    /// 多选操作栏背景：液体玻璃模式开 → 毛玻璃材质；关 → 当前实色卡片背景
    @ViewBuilder
    private var selectionBarBackground: some View {
        if liquidGlassMode {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        } else {
            AppColors.cardBackground
        }
    }

    // MARK: - 交互

    private func tap(_ record: ReadingProgress) {
        if isSelecting {
            toggleSelection(record)
        } else {
            open(record)
        }
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
            // 从阅读界面打开的小说（txt/epub 等）统一走小说阅读器：
            // 阅读记录均由小说阅读器产生（含章节索引/进度锚点），恢复时才可精准续读；
            // 纯 txt 阅读器仅用于浏览/收藏页的轻量全文滚动入口，不产生进度记录。
            novelReader.open(connection: connection, entry: entry)
        case .comic:
            // 直接恢复到上次页码（TODO §6）
            comicReader.open(connection: connection, entry: entry)
        case .image, .subtitle, .other:
            break   // 进度记录仅由播放/阅读内核产生，不会出现其他类型
        }
    }

    /// 定位到源路径位置：跳浏览页并呼吸灯定位（IOS-704，参照收藏页「在浏览中定位」）
    private func locate(_ record: ReadingProgress) {
        locator.locate(connectionID: record.connectionID, filePath: record.filePath)
        router.selectedTab = .browse
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

    // MARK: - 删除源文件

    /// 删除源文件（回收站优先，与浏览界面同机制）：
    /// 按连接分组，将文件移动到挂载点下 `.trash/时间戳-原名` 并写 `.meta.json` 还原元数据；
    /// 源文件已不存在 / 连接不可用的记录只清理阅读记录；返回实际移入回收站数量。
    @discardableResult
    private func deleteSourceFiles(ids: [Int64]) async throws -> Int {
        let records = history.records.filter { ids.contains($0.id ?? -1) }
        var moved = 0
        let groups = Dictionary(grouping: records, by: \.connectionID)
        for (connectionID, group) in groups {
            guard let adapter = adapters[connectionID] else { continue }   // 连接不可用：仅清理记录
            do {
                try await adapter.mkdir("/.trash")
            } catch {
                // 目录已存在或创建失败均继续尝试移动
            }
            let stamp = Self.trashStamp()
            for record in group {
                // 现场 stat 确认源文件仍在（记录可能残留/源已被外部删除），不存在则跳过移动
                let fileEntry: FileEntry?
                do {
                    fileEntry = try await adapter.stat(record.filePath)
                } catch {
                    fileEntry = nil
                }
                guard let fileEntry else { continue }
                let trashPath = "/.trash/\(stamp)-\(fileEntry.name)"
                try await adapter.move(fileEntry.path, trashPath)
                await writeTrashMeta(adapter: adapter, trashPath: trashPath, entry: fileEntry)
                moved += 1
            }
        }
        // 无论文件删除是否全部成功，对应阅读记录一并清理（源文件没了 / 连接没了，记录失去意义）
        history.remove(ids: ids)
        selection = nil
        return moved
    }

    /// 彻底删除源文件（回收站不可用时的降级路径）：按连接分组直接删除，已不存在的文件忽略
    private func forceDeleteSourceFiles(ids: [Int64]) async {
        let records = history.records.filter { ids.contains($0.id ?? -1) }
        let groups = Dictionary(grouping: records, by: \.connectionID)
        for (connectionID, group) in groups {
            guard let adapter = adapters[connectionID] else { continue }
            for record in group {
                try? await adapter.delete(record.filePath)
            }
        }
        history.remove(ids: ids)
        selection = nil
        message = "已彻底删除 \(ids.count) 个源文件，并清理阅读记录"
    }

    /// 写回收站还原元数据（与浏览界面 `BrowseDirectoryViewModel.TrashMeta` 一致，供回收站页还原）
    private func writeTrashMeta(adapter: StorageAdapter, trashPath: String, entry: FileEntry) async {
        let meta = TrashMeta(
            originalPath: entry.path,
            name: entry.name,
            isDir: entry.isDir,
            deletedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(meta) else { return }
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(data)
            continuation.finish()
        }
        try? await adapter.writeStream(trashPath + ".meta.json", data: stream)
    }

    private struct TrashMeta: Codable {
        var originalPath: String
        var name: String
        var isDir: Bool
        var deletedAt: Date
    }

    private static func trashStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
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
    /// 沉浸样式（网格卡）：无封面时类型渐变底 + 白色图标
    var immersive = false

    @State private var cachedImage: UIImage?
    @State private var probed = false

    var body: some View {
        ZStack {
            if immersive {
                entry.coverPlaceholderGradient
            }
            if let cachedImage {
                Color.clear
                    .overlay {
                        Image(uiImage: cachedImage)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                    .transition(.opacity)
            } else if probed {
                fallback
            } else {
                placeholderIcon
            }
        }
        .clipped()
        .task(id: record.cover) {
            guard let name = record.cover else {
                cachedImage = nil
                probed = true
                return
            }
            let url = CacheManager.shared.url(for: .thumbnails).appendingPathComponent(name)
            let image = await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: url.path)
            }.value
            if image != nil {
                CacheManager.shared.touch(url)   // 刷新访问时间，防封面被 LRU 误淘汰
            }
            withAnimation(.appQuick) {
                cachedImage = image
                probed = true
            }
        }
    }

    private var placeholderIcon: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            Image(systemName: entry.placeholderSymbol)
                .font(.system(size: immersive ? 40 : max(30, side * 0.55)))
                .foregroundStyle(immersive ? Color.white.opacity(0.9) : AppColors.textSecondary)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    @ViewBuilder
    private var fallback: some View {
        // entry.size == 0 表示 stat 尚未完成（媒体文件恒 > 0），此时缓存键（含 size/modTime）
        // 与浏览页不一致，会错过已存封面并触发重复加载。先显示占位，待真实 entry 就绪后
        // 视图重建再加载，确保命中浏览页磁盘缓存。
        if let connection, let adapter, entry.size > 0 {
            RemoteCoverImage(
                entry: entry, connection: connection, adapter: adapter,
                immersivePlaceholder: immersive
            )
        } else {
            placeholderIcon
        }
    }
}
