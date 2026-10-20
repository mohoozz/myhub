import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PhotosUI

/// 浏览导航位置（连接源内某目录）
struct BrowseLocation: Hashable, Codable {
    var connectionID: Int64
    var path: String
}

/// 浏览内容区滚动偏移上报：minY >= 0 表示已回到顶部。
/// 用于驱动「搜索框在顶部时显示，下滑即隐藏」（TODO 336）。
/// 采用自绘搜索框替代系统 `.searchable`：iOS 26 上 `.searchable` 与 `.refreshable`
/// 叠加会导致内容区无法上下滚动（TODO 283/284），自绘后各 iOS 版本统一挂载 `.refreshable`，
/// 下拉刷新图标（TODO 335）与搜索框两全。
private struct BrowseScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 目录浏览页（IOS-102 浏览 + IOS-103~105 文件操作）：
/// - 导航栏显示当前目录名（TODO 364，根目录为连接名）+ 搜索 + 视图切换 + 排序 + 上传（文件/相册）+ 下拉刷新 + 空/加载/错误状态；
/// - 长按（iOS，底部抽屉菜单）/ 指针右键（iPad/PC，锚点菜单）弹操作菜单；多选经菜单「多选」或右上角「…」→「选择」进入，底部操作栏：移动/复制/重命名/下载/收藏/删除；
/// - NavigationStack 系统交互式 pop 返回上一级。
struct BrowseDirectoryView: View {
    let connection: Connection
    let path: String
    @Binding var navPath: NavigationPath
    /// 可用连接源（移动/复制跨源目标选择）
    var connections: [Connection] = []

    @StateObject private var viewModel: BrowseDirectoryViewModel
    /// 「定位到原路径」全局状态（IOS-704）：本目录若为目标文件所在目录则滚动定位 + 呼吸灯高亮
    @EnvironmentObject private var locator: BrowseLocator
    @EnvironmentObject private var player: PlayerPresenter
    @EnvironmentObject private var novelReader: NovelReaderPresenter
    @EnvironmentObject private var comicReader: ComicReaderPresenter
    @EnvironmentObject private var txtReader: TxtReaderPresenter
    @EnvironmentObject private var popupMenu: PopupMenuPresenter
    /// 阅读进度记录（用于文件项进度环，参考 Flutter 浏览界面）
    @ObservedObject private var readingHistory = ReadingHistoryStore.shared
    /// 播放引擎状态（区分播放中/暂停，仅播放中才高亮）
    @ObservedObject private var playerCore = PlayerCore.shared

    /// 全局底部装饰（悬浮页签栏 / mini 播放器）占用高度：底部覆盖层据此抬升（TODO 379）
    @Environment(\.bottomChromeHeight) private var bottomChromeHeight
    /// 多选态隐藏全局悬浮页签栏（回写 RootView，底部让给操作栏，TODO 385）
    @Environment(\.bottomTabBarHidden) private var bottomTabBarHidden

    @State private var sheet: SheetRoute?
    @State private var imagePreview: ImagePreviewContext?
    @State private var renaming: FileEntry?
    @State private var renameText = ""
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var showImporter = false
    @State private var showPhotosPicker = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var deletingPaths: Set<String>?
    @State private var forceDeletePaths: Set<String>?
    /// 回收站移动失败原因（占用/网络/不支持，TODO 373）：「无法使用回收站」弹窗附带展示
    @State private var forceDeleteReason: String?
    /// 搜索框显隐（TODO 336/345）：滚到顶部显示、下滑超过搜索框高度隐藏，带迟滞避免抖动
    @State private var showSearchBar = true
    /// 搜索输入框焦点（TODO 403）：聚焦期间锁定搜索框可见，避免键盘弹出引发的布局抖动把它收起
    @FocusState private var searchFieldFocused: Bool
    /// 左滑删除后的「撤销」提示条（TODO 408）
    @StateObject private var undoToast = UndoToastState()

    /// 搜索框当前是否可见：滚动显隐状态为准，但输入中（已聚焦）始终保持展开
    private var isSearchBarVisible: Bool {
        showSearchBar || searchFieldFocused
    }

    init(
        connection: Connection,
        path: String,
        navPath: Binding<NavigationPath>,
        connections: [Connection] = []
    ) {
        self.connection = connection
        self.path = StoragePath.normalize(path)
        self._navPath = navPath
        self.connections = connections
        _viewModel = StateObject(
            wrappedValue: BrowseDirectoryViewModel(connection: connection, path: path)
        )
    }

    private var connectionID: Int64 { connection.id ?? 0 }

    // MARK: - 删除前释放文件占用（TODO 372/373）

    /// 「无法使用回收站」弹窗文案：附失败原因（占用/网络/权限），便于用户判断重试时机
    private var forceDeleteMessage: String {
        var text = "该连接源不支持回收站或部分项目移动失败"
        if let reason = forceDeleteReason, !reason.isEmpty {
            text += "（\(reason)）"
        }
        text += "，将彻底删除剩余的 \(forceDeletePaths?.count ?? 0) 个项目，不可恢复。"
        return text
    }

    /// 待删项包含当前播放（含 mini）的文件时先停止播放并稍候：
    /// 注销串流会话、取消在途分片请求，让服务端句柄尽快释放，
    /// 避免 NAS 因文件仍被读取而拒绝 MOVE/DELETE（表现为刚播放完删除失败，TODO 373）
    private func releasePlaybackIfNeeded(_ paths: Set<String>) async {
        guard let current = player.current,
              (current.connectionID ?? 0) == connectionID,
              paths.contains(current.path) else { return }
        AppLogger.shared.log("删除前停止播放被删文件 path=\(current.path)", module: "browse")
        player.close()
        // 轮询等待 PlayerCore 注销串流会话（reader.cancel 立即置位并停止在途请求），
        // 最长 1s；未在播放该文件时首轮即返回，不引入额外延迟
        for _ in 0..<10 {
            if PlayerCore.shared.request == nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // 再等一小段，让取消的在途请求传播到服务端（释放读取句柄）
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    // MARK: - 导航栏标题（TODO 364）

    /// 导航栏标题：普通浏览态显示当前目录名，多选态显示已选数量
    private var navigationTitleText: String {
        viewModel.isSelecting
            ? "已选 \(viewModel.selection?.count ?? 0) 项"
            : currentDirectoryName
    }

    /// 当前目录名：根目录回退显示连接名（面包屑已删除，目录归属改由导航栏承载）
    private var currentDirectoryName: String {
        let normalized = StoragePath.normalize(viewModel.path)
        return normalized == "/" ? connection.name : StoragePath.fileName(of: normalized)
    }

    // MARK: - 定位到原路径（IOS-704）

    /// 目标文件全路径：仅当本目录是「定位目标」的所在目录时非 nil（其余目录层不参与高亮/滚动）
    private var highlightPath: String? {
        guard let highlight = locator.highlight,
              highlight.connectionID == connectionID,
              StoragePath.parent(of: highlight.path) == path
        else { return nil }
        return highlight.path
    }

    /// 本次定位 token：同一文件重复定位时值不同，驱动重新滚动定位
    private var highlightToken: UUID? { highlightPath == nil ? nil : locator.highlight?.token }

    /// 定位滚动任务键：目标路径 / 定位 token / 目录加载态与展示条目数，
    /// 任一变化（新定位、目录加载完成、搜索过滤变化）都会重新滚动定位
    private struct HighlightScrollKey: Equatable {
        var path: String?
        var token: UUID?
        var loaded: Bool
        var count: Int
    }

    private var highlightScrollKey: HighlightScrollKey {
        HighlightScrollKey(
            path: highlightPath,
            token: highlightToken,
            loaded: viewModel.state == .loaded,
            count: viewModel.displayedEntries.count
        )
    }

    /// 诊断：body 求值频率（限流日志，用于排查「文件多无法滑动」）
    private static var renderCount = 0
    private static var renderLogLast = Date.distantPast

    /// 诊断（TODO 413）：本次统计窗口内各上游对象的发布次数——
    /// 用来回答「到底是什么在推动每秒 1~5 次重绘」这个唯一还缺的事实
    private static var triggerTally: [String: Int] = [:]

    /// 诊断（TODO 413）：页面挂载 / 卸载 / `.task` 触发次数——
    /// 三者都在涨说明宿主层级在反复重排（不是用户在导航）
    private static var pageAppearCount = 0
    private static var pageDisappearCount = 0
    private static var pageTaskCount = 0

    private static func note(_ source: String) {
        triggerTally[source, default: 0] += 1
    }

    /// 取出并清空本窗口的触发来源统计（按次数降序）
    private static func drainTriggerTally() -> String {
        guard !triggerTally.isEmpty else { return "无对外发布" }
        let text = triggerTally
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        triggerTally.removeAll()
        return text
    }

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
        case share(URL)

        var id: String {
            switch self {
            case .move: return "move"
            case .copy: return "copy"
            case .editText(let entry): return "edit-\(entry.path)"
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
            // 搜索框常驻视图树，仅用高度 + 透明度收起（TODO 403）：
            // 此前用 `if showSearchBar { searchBar }` 条件插拔，点击输入框时键盘弹出引发的布局变化
            // 会让偏移上报抖动一次 → 搜索框被移除 → TextField 连同第一响应者一起销毁 → 键盘刚弹即收
            //（表现为「要点两次才出输入法」），且收起/展开动画被打断时 VStack 会停在中间高度
            //（表现为「点完搜索框变矮」）。常驻 + 高度动画后视图标识稳定，焦点不再丢失。
            searchBar
                .frame(height: isSearchBarVisible ? searchBarHeight : 0, alignment: .top)
                .opacity(isSearchBarVisible ? 1 : 0)
                .clipped()
                .allowsHitTesting(isSearchBarVisible)

            content
        }
        .animation(.appQuick, value: isSearchBarVisible)
        .background(AppColors.pageBackground)
        // 主色：与设置等页一致（它们都逐页声明 `.tint(AppColors.primary)`）——不声明的话本页
        // 导航栏取系统默认色，返回按钮与右上角按钮会偏白（iOS 26）
        .tint(AppColors.primary)
        // 面包屑已移除（TODO 364）：普通态标题显示当前目录名（根目录为连接名），
        // 多选态改为「已选 N 项」作为操作状态反馈。
        .navigationTitle(navigationTitleText)
        .navigationBarTitleDisplayMode(.inline)
        // 多选态隐藏系统返回按钮：多选态左侧是纯文字的「全选 / 完成」，而系统返回按钮在 iOS 26 是
        // 圆形玻璃胶囊，两者风格不一致；且多选态本就不应被返回上一级目录（TODO 386）
        .navigationBarBackButtonHidden(viewModel.isSelecting)
        .toolbar { toolbar }
        // iOS 26：右上角改由 UIKit 装到本页面的 `UINavigationItem` 上（TODO 404）。
        // 透明挂载点：只借它拿到「当前页面」，不显示内容、不参与命中。
        .background {
            if !viewModel.isSelecting, usesUIKitTrailing {
                NavigationBarTrailingButtons(items: uikitTrailingButtons)
            }
        }
        // 底部覆盖层（多选操作栏 / 传输横幅 / 轻提示，TODO 379）：
        // safeAreaInset 只为滚动内容预留底部空间（高度固定），覆盖层本体由 overlay 绘制并抬升——
        // 页面内 safeAreaInset / overlay 的落点是「系统底部安全区」，不含祖先注入的悬浮页签栏，
        // 直接注入会落进页签栏之下被遮挡。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: hasBottomOverlayContent ? Self.bottomOverlayReserve : 0)
        }
        .overlay(alignment: .bottom) { bottomOverlay }
        // 多选态隐藏全局页签栏：底部让给操作栏；退出多选或本页退场即恢复（TODO 385）
        .onChange(of: viewModel.isSelecting) { bottomTabBarHidden.wrappedValue = $0 }
        .onAppear {
            bottomTabBarHidden.wrappedValue = viewModel.isSelecting   // 返回本页时按当前多选态校正
            Self.pageAppearCount += 1
            AppLogger.shared.log(
                "页面 onAppear 第 \(Self.pageAppearCount) 次（\(viewModel.instanceTag)）",
                level: .debug, module: "browse"
            )
        }
        .onDisappear {
            bottomTabBarHidden.wrappedValue = false
            Self.pageDisappearCount += 1
            AppLogger.shared.log(
                "页面 onDisappear 第 \(Self.pageDisappearCount) 次（\(viewModel.instanceTag)）",
                level: .debug, module: "browse"
            )
        }
        // 诊断（TODO 413）：归因每一次重绘——本页观察到的每个 `ObservableObject`
        // 与外部环境值（底部装饰高度）各自记一笔，随限流日志一并打出；
        // viewModel 再按属性细分，直接回答「是哪个 @Published 在反复发布」
        .onReceive(viewModel.objectWillChange) { Self.note("viewModel") }
        .onReceive(viewModel.$entries) { _ in Self.note("vm.entries") }
        .onReceive(viewModel.$state) { _ in Self.note("vm.state") }
        .onReceive(viewModel.$isRefreshing) { _ in Self.note("vm.isRefreshing") }
        .onReceive(viewModel.$favoritePaths) { _ in Self.note("vm.favoritePaths") }
        .onReceive(viewModel.$comicEpubPaths) { _ in Self.note("vm.comicEpubPaths") }
        .onReceive(viewModel.$selection) { _ in Self.note("vm.selection") }
        .onReceive(viewModel.$toast) { _ in Self.note("vm.toast") }
        .onReceive(viewModel.$transfer) { _ in Self.note("vm.transfer") }
        .onReceive(viewModel.$operationError) { _ in Self.note("vm.operationError") }
        .onReceive(viewModel.$searchText) { _ in Self.note("vm.searchText") }
        .onReceive(viewModel.$sortKey) { _ in Self.note("vm.sortKey") }
        .onReceive(viewModel.$sortAscending) { _ in Self.note("vm.sortAscending") }
        .onReceive(viewModel.$viewMode) { _ in Self.note("vm.viewMode") }
        .onReceive(readingHistory.objectWillChange) { Self.note("readingHistory") }
        .onReceive(readingHistory.$records) { _ in Self.note("history.records") }
        .onReceive(playerCore.objectWillChange) { Self.note("playerCore") }
        .onReceive(locator.objectWillChange) { Self.note("locator") }
        .onReceive(player.objectWillChange) { Self.note("player") }
        .onReceive(novelReader.objectWillChange) { Self.note("novelReader") }
        .onReceive(comicReader.objectWillChange) { Self.note("comicReader") }
        .onReceive(txtReader.objectWillChange) { Self.note("txtReader") }
        .onReceive(popupMenu.objectWillChange) { Self.note("popupMenu") }
        .onChange(of: bottomChromeHeight) { _ in Self.note("env:bottomChromeHeight") }
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
        .alert(
            "删除确认",
            isPresented: Binding(get: { deletingPaths != nil }, set: { if !$0 { deletingPaths = nil } })
        ) {
            Button("移入回收站", role: .destructive) {
                if let paths = deletingPaths {
                    Task {
                        // 删除前释放占用：被删文件正在播放（含 mini）时先停播并等待串流会话注销（TODO 373）
                        await releasePlaybackIfNeeded(paths)
                        do {
                            try await viewModel.delete(paths: paths)
                        } catch let trashError as BrowseDirectoryViewModel.TrashError {
                            // 回收站不可用 → 仅对未成功的剩余项降级真删确认：
                            // 已移入回收站的项目不再重复删除，避免误报「删除失败」（TODO 369），
                            // 附带失败原因（占用/网络/不支持）供弹窗提示（TODO 373）
                            let remaining = paths.subtracting(trashError.movedToTrash)
                            if !remaining.isEmpty {
                                forceDeleteReason = trashError.reason
                                forceDeletePaths = remaining
                            }
                        } catch {
                            forceDeleteReason = error.localizedDescription
                            forceDeletePaths = paths
                        }
                    }
                }
                deletingPaths = nil
            }
            Button("取消", role: .cancel) { deletingPaths = nil }
        } message: {
            Text("将删除 \(deletingPaths?.count ?? 0) 个项目（保留 \(AppSettings.Trash.retentionDays) 天，可在回收站还原）")
        }
        .alert(
            "无法使用回收站",
            isPresented: Binding(
                get: { forceDeletePaths != nil },
                set: { if !$0 { forceDeletePaths = nil; forceDeleteReason = nil } }
            )
        ) {
            Button("彻底删除", role: .destructive) {
                if let paths = forceDeletePaths {
                    Task {
                        // 兜底再释放一次占用：首轮 MOVE 可能正因占用失败，此时文件可能仍在播放（TODO 373）
                        await releasePlaybackIfNeeded(paths)
                        await viewModel.forceDelete(paths: paths)
                    }
                }
                forceDeletePaths = nil
            }
            Button("取消", role: .cancel) { forceDeletePaths = nil }
        } message: {
            Text(forceDeleteMessage)
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
            // 诊断（TODO 413）：`.task` 只在视图「初次挂载」执行一次；若这里反复打印，
            // 说明本页宿主被反复重建（这也正是右上角 `+`/`…` 胶囊反复弹一下的来源）
            let nth = await MainActor.run { () -> Int in
                Self.pageTaskCount += 1
                return Self.pageTaskCount
            }
            AppLogger.shared.log(
                "页面 task 第 \(nth) 次触发（\(viewModel.instanceTag)）",
                level: .debug, module: "browse"
            )
            await viewModel.loadIfNeeded()
            readingHistory.reload()   // 首次进入时预载阅读进度（后续经 .playbackProgressDidChange 自动刷新）
        }
    }

    private var availableConnections: [Connection] {
        connections.isEmpty ? [connection] : connections
    }

    // MARK: - 内容区

    /// 搜索框自身高度估算（含上下内外边距）：作为下滑隐藏阈值——
    /// 内容需上滚超过该高度再隐藏，确保隐藏后腾出的空间已被滚动量吸收，
    /// 否则会被 ScrollView 拉回顶部，造成「隐藏即回弹（看似下滑不消失）」的抖动。
    private let searchBarHeight: CGFloat = 60

    /// 搜索框内胶囊自身高度：`searchBarHeight` 减去上下各 8pt 外边距。
    /// 显式固定而非靠内边距撑开——键盘弹出时外层可用高度骤减，VStack 会压缩非滚动子视图，
    /// 导致「点一下搜索框就变矮」（TODO 403）。
    private var searchBarFieldHeight: CGFloat { searchBarHeight - 16 }

    @ViewBuilder
    private var content: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                Group {
                    // 顶部零高探测器：滚动偏移通过 preference 上报，驱动搜索框显隐
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: BrowseScrollOffsetKey.self,
                            value: proxy.frame(in: .named("browseScroll")).minY
                        )
                    }
                    .frame(height: 0)

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
                // 点击空白区域收起左滑展开行（TODO 411）
                .dismissSwipeRowOnBlankTap()
            }
            .coordinateSpace(name: "browseScroll")
            .refreshable { await viewModel.refresh() }
            .scrollDismissesKeyboard(.immediately)
            .onPreferenceChange(BrowseScrollOffsetKey.self) { value in
                // 输入中不参与显隐：键盘弹出会改变可用高度并让偏移上报抖动，
                // 此时若收起搜索框会把正在编辑的输入框一并收走（TODO 403）。
                // 用户一滚动即由 `.scrollDismissesKeyboard(.immediately)` 失焦，随后恢复正常判定。
                guard !searchFieldFocused else { return }
                // 迟滞判定（避免阈值边界抖动 / 隐藏回弹）：
                // - 回到顶部附近（minY >= -1）显示；
                // - 内容上滚超过搜索框高度（minY < -searchBarHeight）才隐藏；
                // - 二者之间为死区，保持当前状态。
                if value >= -1 {
                    if !showSearchBar { showSearchBar = true }
                } else if value < -searchBarHeight {
                    if showSearchBar { showSearchBar = false }
                }
            }
            // 「定位到原路径」：目标目录加载完成后滚动到目标文件（IOS-704）
            .task(id: highlightScrollKey) {
                await scrollToHighlightIfNeeded(scrollProxy)
            }
        }
    }

    /// 滚动定位到「定位到原路径」目标文件：
    /// LazyVGrid / LazyVStack 增量实例化，目标单元格未挂载时单次 scrollTo 会落空
    /// （初始 contentSize 偏小、懒加载尚未展开），故分阶段重试逐次逼近；
    /// 全程无动画瞬时滚动，避免多次动画叠加产生抖动（与漫画阅读器整页定位同策略）。
    private func scrollToHighlightIfNeeded(_ proxy: ScrollViewProxy) async {
        guard let target = highlightPath, viewModel.state == .loaded else { return }
        // 目标被当前搜索过滤时先清空搜索，保证目标出现在展示列表中
        if !viewModel.searchText.isEmpty,
           !viewModel.displayedEntries.contains(where: { $0.path == target }) {
            viewModel.searchText = ""
        }
        if let token = highlightToken {
            // 高亮续期：从「目标即将可见」起重新计满约 10s
            locator.keepAliveHighlight(token: token)
        }
        let delays: [UInt64] = [0, 120_000_000, 300_000_000, 600_000_000, 1_000_000_000]
        for (index, delay) in delays.enumerated() {
            if index > 0 {
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
            }
            if Task.isCancelled { return }
            proxy.scrollTo(target, anchor: .center)
        }
    }

    /// 搜索框：位于导航栏与内容之间，仅在列表处于顶部时显示（下滑隐藏，TODO 336）
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppColors.textSecondary)
            TextField("搜索当前目录", text: $viewModel.searchText)
                .font(.subheadline)
                .foregroundStyle(AppColors.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($searchFieldFocused)
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppColors.textSecondary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        // 固定胶囊高度（原为 .padding(.vertical, 12) 撑开）：键盘弹出使外层可用高度骤减时，
        // VStack 不会再把这条非滚动子视图压扁（TODO 403）
        .frame(height: searchBarFieldHeight)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppColors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppColors.separator, lineWidth: 0.5)
                )
        )
        // 整条胶囊可点聚焦：此前只有 TextField 自身区域（去掉图标与内边距后不足一半宽）能唤起键盘，
        // 点在放大镜/空白处无反应，正是「有时要点两次」的另一半原因（TODO 403）
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            guard !searchFieldFocused else { return }
            searchFieldFocused = true
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func fileCollection(adapter: StorageAdapter) -> some View {
        let items = viewModel.displayedEntries
        // 诊断：统计 body 求值频率，帮助定位滑动卡顿是否来自频繁重绘
        Self.renderCount += 1
        let now = Date()
        if now.timeIntervalSince(Self.renderLogLast) >= 1 {
            AppLogger.shared.log(
                "BrowseDirectoryView 重绘 \(Self.renderCount) 次/秒, 条目 \(viewModel.entries.count), 展示 \(items.count), 触发源[\(Self.drainTriggerTally())]",
                module: "browse"
            )
            Self.renderCount = 0
            Self.renderLogLast = now
        }
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
        // 底部覆盖层的占位由 safeAreaInset（固定高度）为 ScrollView 预留内容内边距（TODO 379），
        // 覆盖层本体是 overlay，不再手工叠加底部留白
    }

    private func gridView(_ items: [FileEntry], adapter: StorageAdapter) -> some View {
        let progressMap = progressByPath
        let highlightTarget = highlightPath   // 求值一次，避免每个单元格重复解析路径
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
                    highlighted: entry.path == highlightTarget,
                    isSelecting: viewModel.isSelecting,
                    isSelected: viewModel.selection?.contains(entry.path) ?? false,
                    progress: entry.isDir ? nil : progressMap[entry.path],
                    isPlaying: isPlaying(entry),
                    menuItems: contextMenuItems(for: entry),
                    onTap: { tap(entry) },
                    isComicEpub: viewModel.isComicEpub(entry)
                )
            }
        }
        .padding(12)
    }

    private func listView(_ items: [FileEntry], adapter: StorageAdapter) -> some View {
        let progressMap = progressByPath
        let highlightTarget = highlightPath   // 求值一次，避免每个单元格重复解析路径
        return LazyVStack(spacing: 0) {
            ForEach(items, id: \.path) { entry in
                FileListRow(
                    entry: entry,
                    connection: connection,
                    adapter: adapter,
                    siblings: viewModel.entries,
                    highlighted: entry.path == highlightTarget,
                    isSelecting: viewModel.isSelecting,
                    isSelected: viewModel.selection?.contains(entry.path) ?? false,
                    progress: entry.isDir ? nil : progressMap[entry.path],
                    isPlaying: isPlaying(entry),
                    menuItems: contextMenuItems(for: entry),
                    onTap: { tap(entry) },
                    isComicEpub: viewModel.isComicEpub(entry),
                    // 左滑删除（TODO 408 方案 A）：左滑只露出按钮、点按才删除；多选态禁用
                    trailingSwipeActions: viewModel.isSelecting ? [] : [deleteSwipeAction(entry)]
                )
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

    /// 底部覆盖层高度（供 safeAreaInset 为滚动内容预留空间）：多选操作栏 + 10pt 间距
    private static let bottomOverlayReserve: CGFloat = 64

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
            // 左滑删除的撤销提示条（TODO 408）
            UndoToastBar(state: undoToast)
            if viewModel.isSelecting {
                selectionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // 抬到全局底部装饰（悬浮页签栏 / mini 播放器）之上；无内容时高度为 0，不占空间（TODO 379）
        .padding(.bottom, hasBottomOverlayContent ? bottomChromeHeight + 10 : 0)
        .animation(.appQuick, value: viewModel.isSelecting)
        .animation(.appQuick, value: viewModel.toast)
    }

    /// 底部覆盖层是否有内容（传输横幅 / 轻提示 / 撤销提示条 / 多选操作栏任一在场）
    private var hasBottomOverlayContent: Bool {
        viewModel.transfer != nil || viewModel.toast != nil
            || undoToast.item != nil || viewModel.isSelecting
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
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(AppColors.cardBorder, lineWidth: 1))
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
            // 图标用 square.and.pencil（21×20）而非 pencil（18×16）：与相邻图标视觉体量一致
            selectionButton("重命名", symbol: "square.and.pencil", enabled: count == 1) {
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
        .background(selectionBarBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppColors.cardBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 12)
    }

    /// 多选操作栏背景：毛玻璃材质
    private var selectionBarBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.ultraThinMaterial)
    }

    private func selectionButton(
        _ title: String, symbol: String, enabled: Bool,
        destructive: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.body)
                    // 固定图标槽高度：各 SF Symbol 固有尺寸不同（17pt 下实测 pencil 仅 18×16，
                    // 而 arrow.right.doc.on.clipboard / doc.on.doc 为 21×23、star 22×20、trash 20×21），
                    // 不统一的话重命名按钮内容最矮 → 居中后图标下沉、文字上浮，与相邻按钮错位（TODO 385）
                    .frame(height: 24)
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .foregroundStyle(enabled ? (destructive ? AppColors.destructive : AppColors.primary) : AppColors.textSecondary.opacity(0.5))
            .frame(maxWidth: .infinity)
        }
        .disabled(!enabled)
    }

    // MARK: - 工具栏

    /// iOS 26 起右上角交给 **UIKit**（TODO 404）
    ///
    /// 为什么：左上角返回按钮是同位置的对照组——它从不弹。
    ///
    /// 真正的差别在 **item 是谁**，不在时机：自绘 view 装的 item（`UIBarButtonItem(customView:)`）
    /// 对导航栏是「外来户」，栏得给它现量尺寸、现配玻璃胶囊，成形动画就发生在这一步；换成标准
    /// item（`UIBarButtonItem(image:style:target:action:)`）后，图标成了栏**自己的**内容，只随栏
    /// 走转场，那一下弹就没了。
    ///
    /// 这个结论是**日志证伪**换来的，别再往「时机」上修：真机日志（模块 `navbar`）显示新页面的
    /// item 在 `viewWillAppear` 时就已装好——「转场中=true 已上屏=false」，即转场动画开始前就在位，
    /// 且整个流程没有任何一次被 SwiftUI 清掉重装；把赋值改成 `setRightBarButtonItems(animated: false)`
    /// 加 `performWithoutAnimation` 也照弹。此前六轮修法（自绘 item、标准 `Button`、锁死动画来源、
    /// 显式无转场事务、逐帧锚点写回、自绘胶囊 + `.glassEffectTransition(.identity)`）之所以处处照弹，
    /// 是因为它们改的都是 item 的*内容*或*时机*，而问题在 item 的*种类*。做法见 `NavigationBarTrailingButtons`。
    ///
    /// 这里用运行时条件而不是 `#available` 分支：`ToolbarContentBuilder` 没有空分支能力
    /// （SDK 里只有 `buildBlock<Content>` / `buildIf` / `buildEither`），而 iOS 26 下
    /// SwiftUI 侧必须**一个字都不声明**，否则会改写 `rightBarButtonItems` 覆盖掉 UIKit 装的 item。
    private var usesUIKitTrailing: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if viewModel.isSelecting {
            // 多选态系统返回按钮已隐藏（见 navigationBarBackButtonHidden），
            // 故「全选」成为最左侧按钮，落在左上角（TODO 386）
            ToolbarItem(placement: .navigationBarLeading) {
                Button("全选") { viewModel.selectAll() }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { viewModel.endSelection() }
                    .fontWeight(.semibold)
            }
        }
        // 常态：iOS 26 起右上角**一个字都不声明**（交给 UIKit，见 `usesUIKitTrailing`），
        // 下面这条只服务 iOS 26 以下——那些系统胶囊本来就没有成形动画，保持原样。
        if !viewModel.isSelecting, !usesUIKitTrailing {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                addButton
                overflowButton
            }
        }
    }

    /// iOS 26 的右上角两颗按钮：UIKit item 描述，挂在页面 body 的 `.background` 上
    /// （锚点取按钮自身在窗口中的位置，自绘菜单的定位方式不变）
    private var uikitTrailingButtons: [NavigationBarTrailingButtons.Item] {
        [
            NavigationBarTrailingButtons.Item(symbol: "plus", accessibilityLabel: "添加") { anchor in
                popupMenu.show(items: addItems, anchor: anchor, style: .popover)
            },
            NavigationBarTrailingButtons.Item(symbol: "ellipsis", accessibilityLabel: "更多操作") { anchor in
                popupMenu.show(items: overflowItems, anchor: anchor)
            },
        ]
    }

    /// 右上角 ＋（上传文件 / 从相册上传 / 新建文件夹）——iOS 26 以下的 SwiftUI 版本
    private var addButton: some View {
        ToolbarMenuButton(items: addItems, symbol: "plus", style: .popover)
    }

    /// 右上角 …（多选 / 视图切换 / 排序 / 升降序 / 刷新）
    private var overflowButton: some View {
        ToolbarMenuButton(items: overflowItems)
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

    /// 右上角 … 菜单（圆角 + 弹出动画，IOS-704）：多选 / 视图切换 / 排序 / 升降序 / 刷新
    private var overflowItems: [PopupMenuItem] {
        var items: [PopupMenuItem] = [
            PopupMenuItem(title: "选择", systemImage: "checkmark.circle") {
                viewModel.selection = []
            },
            PopupMenuItem(
                title: viewModel.viewMode == .grid ? "列表视图" : "网格视图",
                systemImage: viewModel.viewMode == .grid ? BrowseViewMode.list.symbol : BrowseViewMode.grid.symbol
            ) {
                viewModel.viewMode = viewModel.viewMode == .grid ? .list : .grid
            },
        ]
        items.append(contentsOf: BrowseSortKey.allCases.map { key in
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
        })
        items.append(PopupMenuItem(
            title: viewModel.sortAscending ? "✓ 升序" : "✓ 降序",
            systemImage: viewModel.sortAscending ? "chevron.up" : "chevron.down"
        ) {
            viewModel.sortAscending.toggle()
        })
        items.append(PopupMenuItem(title: "刷新", systemImage: "arrow.clockwise") {
            Task { await viewModel.refresh() }
        })
        return items
    }

    // MARK: - 操作菜单（长按 / 指针右键）

    private func contextMenuItems(for entry: FileEntry) -> [PopupMenuItem] {
        let type = viewModel.isComicEpub(entry) ? .comic : MediaType.detect(ext: entry.ext)
        var items: [PopupMenuItem] = [
            // 多选：置顶显示（与右上角「…」→「选择」一致，进入多选，不预选）
            PopupMenuItem(title: "多选", systemImage: "checkmark.circle") {
                viewModel.selection = []
            },
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
        // 反向覆盖（IOS-207 策略 5）：epub 已判定为漫画时，可强制以小说阅读器打开
        if !entry.isDir, entry.ext == "epub", type == .comic {
            items.append(PopupMenuItem(title: "以小说阅读打开", systemImage: "book") {
                novelReader.open(connection: connection, entry: entry)
            })
        }
        if !entry.isDir, type == .subtitle || type == .other {
            items.append(PopupMenuItem(title: "纯文本查看", systemImage: "doc.plaintext") {
                txtReader.open(connection: connection, entry: entry)
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

    // MARK: - 左滑删除（TODO 408 方案 A）

    /// 左滑「删除」：图标 / 文案 / 语义色与长按菜单的「删除」项完全一致（`trash` + 系统红）。
    /// 只移入回收站，不做彻底删除降级——不可恢复的操作仍只保留在长按菜单里
    private func deleteSwipeAction(_ entry: FileEntry) -> SwipeAction {
        SwipeAction(title: "删除", systemImage: "trash") {
            Task { await swipeDelete(entry) }
        }
    }

    /// 左滑删除：先释放播放占用（刚播放完的文件服务端句柄可能未释放，TODO 373），
    /// 再移入回收站；失败只提示不弹降级确认框
    private func swipeDelete(_ entry: FileEntry) async {
        await releasePlaybackIfNeeded([entry.path])
        do {
            let receipt = try await viewModel.deleteToTrash(entry)
            let name = entry.name
            undoToast.show("已将「\(name)」移入回收站") {
                Task { await viewModel.undoDeleteToTrash(receipt) }
            }
        } catch {
            viewModel.operationError = "删除失败：\(entry.name)（\(error.localizedDescription)）。请稍后重试"
        }
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
            } else if viewModel.isComicEpub(entry) {
                // 图集型 epub：直接走漫画阅读器，避免小说阅读器判定→转交的二次解包（IOS-207 策略 5）
                comicReader.open(connection: connection, entry: entry)
            } else {
                novelReader.open(connection: connection, entry: entry)
            }
        case .comic:
            // 漫画阅读器（TODO §6）：先展示加载 UI，再后台解析归档（弱网不卡顿）+ 点击防抖
            comicReader.open(connection: connection, entry: entry)
        case .subtitle, .other:
            showUnsupportedMenu(entry)
        }
    }

    /// 不支持直接预览的文件（如 .ini）：底部抽屉菜单 → 纯文本查看 / 下载（与长按菜单同款）
    private func showUnsupportedMenu(_ entry: FileEntry) {
        let items = [
            PopupMenuItem(title: "纯文本查看", systemImage: "doc.plaintext") {
                txtReader.open(connection: connection, entry: entry)
            },
            PopupMenuItem(title: "下载到本地", systemImage: "arrow.down.circle") {
                Task { await viewModel.downloadToLocal(paths: [entry.path]) }
            },
        ]
        popupMenu.show(items: items, style: .drawer)
    }
}
