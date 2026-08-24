import SwiftUI

/// 自适应导航壳（IOS-001 / TODO §1.1）：
/// - iPhone（Compact）：底部 `TabView`（系统保持各页状态）
/// - iPad（Regular）：`NavigationSplitView` 侧边栏（含「收藏」），detail 用 ZStack 常驻保活
/// - 播放器独立全屏路由 + mini 播放器全局悬浮 + 全局圆角弹出菜单层
/// - 首启 / 初始化期间展示 `LaunchLoadingView`，无长白屏
struct RootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: PlayerPresenter
    @EnvironmentObject private var popup: PopupMenuPresenter
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var novelReader: NovelReaderPresenter
    @EnvironmentObject private var comicReader: ComicReaderPresenter
    private var selection: AppTab { router.selectedTab }

    /// 漫画阅读器路由绑定（下滑/系统关闭时联动 presenter）
    private var comicReaderBinding: Binding<NovelOpenContext?> {
        Binding(
            get: { comicReader.current },
            set: { if $0 == nil { comicReader.close() } }
        )
    }

    var body: some View {
        Group {
            if appState.isReady {
                mainShell
            } else {
                LaunchLoadingView()
            }
        }
        .task { await appState.launch() }
        // 播放器独立全屏路由：不随 Tab 切换销毁
        .fullScreenCover(isPresented: $player.isFullscreen) {
            PlayerView()
        }
        // 小说阅读器独立全屏路由（TODO §5）
        .fullScreenCover(item: $novelReader.current) { context in
            NovelReaderView(context: context)
        }
        // 漫画阅读器独立全屏路由（TODO §6）
        .fullScreenCover(item: comicReaderBinding) { context in
            ComicReaderView(
                context: context,
                onClose: { comicReader.close() },
                onOpenNext: { entry in
                    comicReader.openNext(connection: context.connection, entry: entry)
                }
            )
        }
        // mini 播放器全局悬浮（跨页面保持）
        .overlay(alignment: .bottom) {
            if player.isMini {
                MiniPlayer()
                    .padding(.bottom, 64)   // 避开底部 TabBar
            }
        }
        // 全局圆角弹出菜单层
        .overlay {
            if let state = popup.state {
                PopupMenuLayer(state: state) { popup.dismiss() }
            }
        }
        .animation(.appQuick, value: player.isMini)
    }

    @ViewBuilder
    private var mainShell: some View {
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                sidebar
            } detail: {
                keepAliveDetail
            }
        } else {
            TabView(selection: $router.selectedTab) {
                ForEach(AppTab.phoneTabs) { tab in
                    tab.makeView()
                        .tabItem { Label(tab.title, systemImage: tab.symbol) }
                        .tag(tab)
                }
            }
            .tint(AppColors.primary)
        }
    }

    /// iPad 侧边栏：选中项浅蓝胶囊高亮（§2.10）
    private var sidebar: some View {
        List(selection: $router.selectedTab) {
            ForEach(AppTab.allCases) { tab in
                Label(tab.title, systemImage: tab.symbol)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .foregroundStyle(selection == tab ? AppColors.primary : AppColors.textPrimary)
                    .tag(tab)
                    .listRowSeparator(.hidden)
                    .listRowBackground(
                        Capsule()
                            .fill(selection == tab ? AppColors.highlightBackground : Color.clear)
                            .padding(.horizontal, 6)
                    )
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppColors.sidebarBackground)
        .navigationTitle("MyHub")
    }

    /// iPad detail 保活：所有页常驻，仅切换可见性（§2.2.2）
    private var keepAliveDetail: some View {
        ZStack {
            ForEach(AppTab.allCases) { tab in
                tab.makeView()
                    .opacity(selection == tab ? 1 : 0)
                    .allowsHitTesting(selection == tab)
                    .accessibilityHidden(selection != tab)
            }
        }
    }
}

/// 导航项（《需求分析文档》§2.2.1）
enum AppTab: String, CaseIterable, Identifiable {
    case reading, favorites, feed, browse, browser, settings

    var id: String { rawValue }

    /// iPhone 底部 Tab（收藏并入阅读/浏览，iPad 侧栏独立）
    static let phoneTabs: [AppTab] = [.reading, .feed, .browse, .browser, .settings]

    var title: String {
        switch self {
        case .reading: return "阅读"
        case .favorites: return "收藏"
        case .feed: return "动态"
        case .browse: return "浏览"
        case .browser: return "浏览器"
        case .settings: return "设置"
        }
    }

    var symbol: String {
        switch self {
        case .reading: return "books.vertical"
        case .favorites: return "star"
        case .feed: return "bolt"
        case .browse: return "folder"
        case .browser: return "globe"
        case .settings: return "gearshape"
        }
    }

    @ViewBuilder
    func makeView() -> some View {
        switch self {
        case .reading: ReadingHomeView()
        case .favorites: FavoritesView()
        case .feed: FeedView()
        case .browse: BrowseHomeView()
        case .browser: BrowserHomeView()
        case .settings: SettingsHomeView()
        }
    }
}
