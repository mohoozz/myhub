import SwiftUI

/// 全局底部装饰（悬浮页签栏 + mini 播放器）自身高度，**不含**系统底部安全区（Home 指示条）。
private struct BottomChromeHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// 全局底部装饰自身高度（0 表示无装饰，如 iPad）
    var bottomChromeHeight: CGFloat {
        get { self[BottomChromeHeightKey.self] }
        set { self[BottomChromeHeightKey.self] = newValue }
    }
}

/// 多选态隐藏底部悬浮页签栏：页面进入多选时置 true，把底部让给多选操作栏，退出多选恢复。
private struct BottomTabBarHiddenKey: EnvironmentKey {
    static let defaultValue: Binding<Bool> = .constant(false)
}

extension EnvironmentValues {
    /// 是否隐藏底部悬浮页签栏（多选态）
    var bottomTabBarHidden: Binding<Bool> {
        get { self[BottomTabBarHiddenKey.self] }
        set { self[BottomTabBarHiddenKey.self] = newValue }
    }
}

/// 自适应导航壳
/// - iPhone（Compact）：底部 `TabView`（系统保持各页状态）
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

    /// 底部装饰（mini 播放器 + 悬浮页签栏）占用的高度：页面据此抬升底部操作栏
    @State private var bottomChromeHeight: CGFloat = 0
    /// 多选态隐藏悬浮页签栏（由页面经 `\.bottomTabBarHidden` 回写）
    @State private var bottomTabBarHidden = false

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
            player.isMinimizing = false
            // dismiss 转场已结束，此时恢复竖屏是安全的：requestGeometryUpdate 不与转场并发。
            OrientationController.shared.exitPlayer()
        }) {
            PlayerView()
        }
        // 小说阅读器独立全屏路
        .fullScreenCover(item: $novelReader.current) { context in
            NovelReaderView(context: context)
        }
        // 纯 txt 阅读器独立全屏路由（txt 默认打开，与小说阅读器并列）
        .fullScreenCover(item: $txtReader.current) { context in
            TxtReaderView(context: context)
        }
        // 漫画阅读器独立全屏路
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
            // 自定义底部页签栏：系统 TabView 无法直接缩小图标
            keepAlivePhoneTabs
                .environment(\.bottomChromeHeight, bottomChromeHeight)
                .environment(\.bottomTabBarHidden, $bottomTabBarHidden)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    phoneBottomChrome
                }
        }
    }

    /// iPhone 底部装饰：mini 播放器 + 悬浮圆角页签栏。
    private var phoneBottomChrome: some View {
        VStack(spacing: 8) {
            // 多选态 mini 播放器与页签栏一并隐藏，把整个底部让给多选操作栏
            if player.isMini && !bottomTabBarHidden {
                MiniPlayer(roundedBottom: true)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !bottomTabBarHidden {
                BottomTabBar(selection: $router.selectedTab, tabs: AppTab.phoneTabs)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        // 隐藏态（iPhone 浏览器沉浸态）连这条 8pt 外边距也不占：整条装饰高度归零
        .padding(.bottom, bottomTabBarHidden ? 0 : 8)
        .animation(.appQuick, value: bottomTabBarHidden)
        .background {
            GeometryReader { proxy in
                // 页面内 safeAreaInset / overlay 的落点是「系统底部安全区」（Home 指示条）
                let window = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap { $0.windows }
                    .first { $0.isKeyWindow }
                let windowHeight = window?.bounds.height ?? proxy.frame(in: .global).maxY
                let height = max(0, windowHeight - proxy.frame(in: .global).minY - (window?.safeAreaInsets.bottom ?? 0))
                Color.clear
                    .onAppear {
                        bottomChromeHeight = height
                    }
                    .onChange(of: height) { newValue in
                        bottomChromeHeight = newValue
                    }
            }
        }
    }

    /// iPad 侧边栏：选中项浅蓝胶囊高亮
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

    /// iPad detail 保活：所有页常驻，仅切换可见性
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

/// 导航项
enum AppTab: String, CaseIterable, Identifiable {
    case reading, favorites, feed, browse, browser, settings

    var id: String { rawValue }

    /// iPhone 底部 Tab（收藏并入阅读/浏览，iPad 侧栏独立）
    static let phoneTabs: [AppTab] = [.reading, .browse, .browser, .settings]

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

/// iPhone 底部页签栏：自绘以精确控制图标大小（系统 TabView 纯图标会过大）。
private struct BottomTabBar: View {
    @Binding var selection: AppTab
    let tabs: [AppTab]

    @EnvironmentObject private var router: AppRouter

    /// 胶囊圆角 / 条高
    private let cornerRadius: CGFloat = 26
    private let barHeight: CGFloat = 56

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                let isSelected = selection == tab
                Button {
                    if isSelected {
                        // 重复点击当前页签：通知该页回到起始界面（浏览页 → 路径源选择）
                        router.reselect(tab)
                    } else {
                        // 仅页签图标做弹性反馈（见 label 的 .animation(.appPop)）
                        selection = tab
                    }
                } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 20))
                        // 选中态：图标放大一档 + 主色（切换走 appPop 弹性，点击有「弹起」反馈）
                        .scaleEffect(isSelected ? 1.12 : 1)
                        .foregroundStyle(isSelected ? AppColors.primary : AppColors.textSecondary)
                        .animation(.appPop, value: isSelected)
                        .frame(maxWidth: .infinity)
                        .frame(height: barHeight)
                        .contentShape(Rectangle())
                }
                // 按下即回缩 0.86（经 PressVisualGate 保底最短可见时长，快速单点也能看到动画）
                .buttonStyle(ScaleButtonStyle(scale: 0.86))
                .accessibilityLabel(tab.title)
            }
        }
        .frame(height: barHeight)
        .background(barBackground)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // 1pt 极浅描边：与 mini 播放器 / 多选操作栏统一为 `cardBorder`
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(AppColors.cardBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
    }

    /// 页签栏背景：Liquid Glass（iOS 26）/ 毛玻璃回退
    @ViewBuilder
    private var barBackground: some View {
        if #available(iOS 26.0, *) {
            Rectangle()
                .fill(Color.clear)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
    }
}
