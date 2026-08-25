import SwiftUI
import GRDB

/// 收藏页（IOS-107）：网格/列表切换，封面 + 类型徽标，卡片整体可点击；
/// 点击进入对应播放器/阅读器（文件夹经「定位到原路径」跳浏览页）；与浏览页星标经 FavoritesStore 双向同步。
struct FavoritesView: View {
    @EnvironmentObject private var favoritesStore: FavoritesStore
    @EnvironmentObject private var player: PlayerPresenter
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var locator: BrowseLocator
    @EnvironmentObject private var novelReader: NovelReaderPresenter
    @EnvironmentObject private var comicReader: ComicReaderPresenter
    @EnvironmentObject private var txtReader: TxtReaderPresenter

    @State private var viewMode: BrowseViewMode = AppSettings.Favorites.viewMode {
        didSet { AppSettings.Favorites.viewMode = viewMode }
    }
    @State private var connections: [Int64: Connection] = [:]
    @State private var resolved: [Int64: FileEntry] = [:]   // stat 后的真实条目（含 isDir）
    @State private var resolving: Set<Int64> = []
    @State private var imagePreview: PreviewContext?
    @State private var message: String?

    private struct PreviewContext: Identifiable {
        let id = UUID()
        var images: [FileEntry]
        var index: Int
        var adapter: StorageAdapter
    }

    var body: some View {
        NavigationStack {
            content
                .background(AppColors.pageBackground)
                .navigationTitle("收藏")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            viewMode = viewMode == .grid ? .list : .grid
                        } label: {
                            Image(systemName: viewMode == .grid
                                  ? BrowseViewMode.list.symbol : BrowseViewMode.grid.symbol)
                        }
                    }
                }
        }
        .fullScreenCover(item: $imagePreview) { context in
            ImagePreviewView(images: context.images, initialIndex: context.index, adapter: context.adapter)
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
            favoritesStore.reload()
            loadConnections()
            resolveAll()
        }
        .onReceive(favoritesStore.$favorites) { _ in resolveAll() }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if favoritesStore.favorites.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "star")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("暂无收藏")
                    .foregroundStyle(AppColors.textSecondary)
                Text("在浏览页长按文件进入多选，或右键菜单收藏")
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                if viewMode == .grid {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(favoritesStore.favorites) { favorite in
                            gridCell(favorite)
                        }
                    }
                    .padding(12)
                } else {
                    LazyVStack(spacing: 6) {
                        ForEach(favoritesStore.favorites) { favorite in
                            listRow(favorite)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: - 单元格

    private func gridCell(_ favorite: Favorite) -> some View {
        let entry = entry(for: favorite)
        return VStack(spacing: 6) {
            cover(for: favorite, entry: entry)
                .frame(maxWidth: .infinity)
                .aspectRatio(1.35, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(AppSettings.Browse.fileNameLines, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Text(connections[favorite.connectionID]?.name ?? "")
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .hoverEffect(.highlight)
        .cellPressableMenu(items: menuItems(for: favorite)) { open(favorite) }
    }

    private func listRow(_ favorite: Favorite) -> some View {
        let entry = entry(for: favorite)
        return HStack(spacing: 12) {
            cover(for: favorite, entry: entry)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.body)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                Text("\(connections[favorite.connectionID]?.name ?? "") · \(favorite.filePath)")
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            Image(systemName: "star.fill")
                .font(.caption)
                .foregroundStyle(AppColors.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AppColors.cardBackground)
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .cellPressableMenu(cornerRadius: 10, items: menuItems(for: favorite)) { open(favorite) }
    }

    /// 封面（复用浏览页组件，保证两页一致）；文件夹直接图标
    @ViewBuilder
    private func cover(for favorite: Favorite, entry: FileEntry) -> some View {
        if let connection = connections[favorite.connectionID],
           let adapter = try? AdapterFactory.makeAdapter(for: connection) {
            RemoteCoverImage(entry: entry, connection: connection, adapter: adapter)
        } else {
            ZStack {
                AppColors.cardBackground
                Image(systemName: entry.placeholderSymbol)
                    .font(.title2)
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
    }

    private func menuItems(for favorite: Favorite) -> [PopupMenuItem] {
        [
            PopupMenuItem(title: "打开", systemImage: "arrow.right.circle") { open(favorite) },
            PopupMenuItem(title: "在浏览中定位", systemImage: "scope") {
                locate(favorite)
            },
            PopupMenuItem(title: "取消收藏", systemImage: "star.slash", destructive: true) {
                favoritesStore.remove(favorite)
            },
        ]
    }

    // MARK: - 打开路由

    private func open(_ favorite: Favorite) {
        let entry = entry(for: favorite)
        if entry.isDir {
            locate(favorite)
            return
        }
        guard let connection = connections[favorite.connectionID],
              let adapter = try? AdapterFactory.makeAdapter(for: connection) else {
            message = "连接源不可用"
            return
        }
        switch favorite.mediaType {
        case .video, .audio:
            // 解析数据源（本地 file:// / 边下边播代理）+ 历史进度恢复（TODO §4.2）
            player.play(connection: connection, entry: entry)
        case .image:
            // 同目录图片自然序，定位当前张
            Task { @MainActor in
                let parent = StoragePath.parent(of: entry.path)
                let siblings = ((try? await adapter.list(parent)) ?? [entry])
                    .filter { !$0.isDir && MediaType.detect(ext: $0.ext) == .image }
                    .sorted { $0.name.naturalCompare($1.name) == .orderedAscending }
                let index = siblings.firstIndex { $0.path == entry.path } ?? 0
                imagePreview = PreviewContext(
                    images: siblings.isEmpty ? [entry] : siblings,
                    index: siblings.isEmpty ? 0 : index,
                    adapter: adapter
                )
            }
        case .novel:
            // txt 默认走纯 txt 阅读器（全文滚动）；epub 走小说阅读器（章节/进度）
            if entry.ext == "txt" {
                txtReader.open(connection: connection, entry: entry)
            } else {
                novelReader.open(connection: connection, entry: entry)
            }
        case .comic:
            // 漫画阅读器（TODO §6）：直接恢复上次页码
            comicReader.open(connection: connection, entry: entry)
        case .subtitle, .other:
            locate(favorite)
        }
    }

    /// 文件夹 / 未识别类型：跳浏览页并呼吸灯定位（IOS-704）
    private func locate(_ favorite: Favorite) {
        locator.locate(connectionID: favorite.connectionID, filePath: favorite.filePath)
        router.selectedTab = .browse
    }

    // MARK: - 数据解析

    /// Favorite 记录 → FileEntry（stat 成功用真实值；否则按记录构造兜底）
    private func entry(for favorite: Favorite) -> FileEntry {
        if let resolved = resolved[favorite.id ?? -1] { return resolved }
        return FileEntry(
            name: StoragePath.fileName(of: favorite.filePath),
            path: favorite.filePath,
            isDir: false,
            size: favorite.size,
            modTime: favorite.createdAt,
            ext: StoragePath.ext(of: favorite.filePath)
        )
    }

    private func loadConnections() {
        guard let db = AppDatabase.shared.dbQueue else { return }
        let all = (try? db.read { try Connection.fetchAll($0) }) ?? []
        connections = Dictionary(uniqueKeysWithValues: all.compactMap { connection in
            connection.id.map { ($0, connection) }
        })
    }

    /// 批量 stat 解析真实 FileEntry（限并发 3；文件夹/大小/类型以真实为准）
    private func resolveAll() {
        let targets = favoritesStore.favorites.filter { resolved[$0.id ?? -1] == nil && !resolving.contains($0.id ?? -1) }
        guard !targets.isEmpty else { return }
        for favorite in targets.prefix(3) {
            guard let favoriteID = favorite.id,
                  let connection = connections[favorite.connectionID],
                  let adapter = try? AdapterFactory.makeAdapter(for: connection) else { continue }
            resolving.insert(favoriteID)
            Task { @MainActor in
                let entry = try? await adapter.stat(favorite.filePath)
                resolving.remove(favoriteID)
                if let entry {
                    resolved[favoriteID] = entry
                }
                resolveAll()   // 继续下一批
            }
        }
    }
}
