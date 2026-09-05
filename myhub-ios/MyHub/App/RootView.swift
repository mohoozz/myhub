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
    @EnvironmentObject private var txtReader: TxtReaderPresenter
    @EnvironmentObject private var connectionStore: ConnectionStore
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
        .task {
            await appState.launch()
            // 内外网路由锁定：启动后探测一次全部已启用连接源，后续操作复用本次判定
            await connectionStore.probeOnLaunch()
        }
        // 播放器独立全屏路由：不随 Tab 切换销毁
        .fullScreenCover(isPresented: $player.isFullscreen, onDismiss: {
            player.isMinimizing = false   // 全屏封面 dismiss 完成后重置瞬消标志，避免下次展开内容仍透明
            // dismiss 转场已结束，此时恢复竖屏是安全的：requestGeometryUpdate 不与转场并发。
            // onDisappear 在转场「进行中」触发，若在那一刻旋转会与 dismiss 并发，导致 iOS 16 崩溃。
            AppLogger.shared.log("fullScreenCover onDismiss isLandscape=\(OrientationController.shared.isLandscape)", module: "player")
            if OrientationController.shared.isLandscape {
                OrientationController.shared.lockPortrait()
            }
        }) {
            PlayerView()
        }
        // 小说阅读器独立全屏路由（TODO §5）
        .fullScreenCover(item: $novelReader.current) { context in
            NovelReaderView(context: context)
        }
        // 纯 txt 阅读器独立全屏路由（txt 默认打开，与小说阅读器并列）
        .fullScreenCover(item: $txtReader.current) { context in
            TxtReaderView(context: context)
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
        // mini 播放器：iPhone 贴底部页签栏（见 mainShell），iPad 悬浮底部
        // 全局弹出菜单层：… 按钮 / iOS 长按 → 底部抽屉；+ 按钮 / 指针右键 → 锚点圆角卡片
        .overlay {
            if let state = popup.state {
                switch state.style {
                case .popover:
                    PopupMenuLayer(state: state) { popup.dismiss() }
                case .drawer:
                    BottomMenuDrawer(items: state.items) { popup.dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var mainShell: some View {
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                sidebar
            } detail: {
                keepAliveDetail
            }
            .overlay(alignment: .bottom) {
                if player.isMini {
                    MiniPlayer()
                }
            }
        } else {
            // 自定义底部页签栏：系统 TabView 无法直接缩小图标，
            // 改用 ZStack 保活 + 自绘 HStack 页签（纯图标、图标尺寸可控）
            // mini 播放器贴底页签栏上方（对齐 Flutter 移动端 bottomNavigationBar）
            VStack(spacing: 0) {
                keepAlivePhoneTabs
                if player.isMini {
                    MiniPlayer()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                BottomTabBar(selection: $router.selectedTab, tabs: AppTab.phoneTabs)
            }
        }
    }

    /// iPad 侧边栏：选中项浅蓝胶囊高亮（§2.10）
    private var sidebar: some View {
        List {
            ForEach(AppTab.allCases) { tab in
                Button {
                    router.selectedTab = tab
                } label: {
                    Label(tab.title, systemImage: tab.symbol)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .foregroundStyle(selection == tab ? AppColors.primary : AppColors.textPrimary)
                }
                .buttonStyle(.plain)
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

    /// iPhone 底栏保活：手机端页签常驻，仅切换可见性（与 iPad 同策略，保状态）
    private var keepAlivePhoneTabs: some View {
        ZStack {
            ForEach(AppTab.phoneTabs) { tab in
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

/// iPhone 底部页签栏：自绘以精确控制图标大小（系统 TabView 纯图标会过大）
private struct BottomTabBar: View {
    @Binding var selection: AppTab
    let tabs: [AppTab]

    /// 液体玻璃模式：开启时页签栏使用 Liquid Glass 背景，关闭时用实色背景
    @AppStorage("ui.liquidGlassMode") private var liquidGlassMode = true

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                let isSelected = selection == tab
                Button {
                    selection = tab
                } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 20))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .foregroundStyle(isSelected ? AppColors.primary : AppColors.textSecondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
            }
        }
        .background(barBackground.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Divider().opacity(0.4) }
    }

    /// 页签栏背景：液体玻璃开 → Liquid Glass（iOS 26）/ 毛玻璃回退；关 → 实色
    @ViewBuilder
    private var barBackground: some View {
        if liquidGlassMode {
            if #available(iOS 26.0, *) {
                Rectangle()
                    .fill(Color.clear)
                    .glassEffect(.regular, in: Rectangle())
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
        } else {
            Rectangle().fill(AppColors.sidebarBackground)
        }
    }
}
