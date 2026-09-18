import SwiftUI

/// 全局底部装饰（悬浮页签栏 + mini 播放器）自身高度，**不含**系统底部安全区（Home 指示条）。
/// 悬浮页签栏经 `safeAreaInset` 注入后，页面内 `safeAreaInset(edge: .bottom)` / `overlay(alignment:)`
/// 的落点仍是「系统底部安全区」，并不包含页签栏，于是底部操作栏会落进页签栏之下被遮挡（TODO 379）。
/// 页面只需在该安全区之上再让出装饰自身高度 + 间距，即可正好停在装饰上方。
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

/// 多选态隐藏底部悬浮页签栏（TODO 385）：页面进入多选时置 true，把底部让给多选操作栏，退出多选恢复。
/// 用绑定而非单向值：多选状态由各页自己持有，需向上回写（iPad 无页签栏，默认常量绑定写入无副作用）。
private struct BottomTabBarHiddenKey: EnvironmentKey {
    static let defaultValue: Binding<Bool> = .constant(false)
}

extension EnvironmentValues {
    /// 是否隐藏底部悬浮页签栏（多选态，TODO 385）
    var bottomTabBarHidden: Binding<Bool> {
        get { self[BottomTabBarHiddenKey.self] }
        set { self[BottomTabBarHiddenKey.self] = newValue }
    }
}

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

    /// 底部装饰（mini 播放器 + 悬浮页签栏）占用的高度：页面据此抬升底部操作栏（TODO 379）
    @State private var bottomChromeHeight: CGFloat = 0
    /// 多选态隐藏悬浮页签栏（由页面经 `\.bottomTabBarHidden` 回写，TODO 385）
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
            player.isMinimizing = false   // 全屏封面 dismiss 完成后重置瞬消标志，避免下次展开内容仍透明
            // dismiss 转场已结束，此时恢复竖屏是安全的：requestGeometryUpdate 不与转场并发。
            // onDisappear 在转场「进行中」触发，若在那一刻旋转会与 dismiss 并发，导致 iOS 16 崩溃。
            AppLogger.shared.log("fullScreenCover onDismiss isLandscape=\(OrientationController.shared.isLandscape)", module: "player")
            // 退出播放页：恢复竖屏并停止自动跟随（方向偏好保留，下次播放沿用）
            OrientationController.shared.exitPlayer()
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
            // mini 播放器 + 页签栏（TODO 376 方案 C 悬浮圆角胶囊）：经 safeAreaInset 注入，
            // 内容可滚动穿过胶囊下方而不被遮挡；二者左右内缩 12pt 对齐、间距 8pt。
            keepAlivePhoneTabs
                .environment(\.bottomChromeHeight, bottomChromeHeight)
                .environment(\.bottomTabBarHidden, $bottomTabBarHidden)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    phoneBottomChrome
                }
        }
    }

    /// iPhone 底部装饰：mini 播放器 + 悬浮圆角页签栏（TODO 376 方案 C）。
    /// 同时量出自身高度（含 mini 播放器），回写 `bottomChromeHeight`，
    /// 供页面把底部操作栏抬到装饰之上（TODO 379）。
    /// 多选态隐藏页签栏（`bottomTabBarHidden`，TODO 385）：底部让给多选操作栏，测量值随之变小，
    /// 操作栏自动落到页签栏原本的位置。
    private var phoneBottomChrome: some View {
        VStack(spacing: 8) {
            if player.isMini {
                MiniPlayer(roundedBottom: true)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !bottomTabBarHidden {
                BottomTabBar(selection: $router.selectedTab, tabs: AppTab.phoneTabs)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.appQuick, value: bottomTabBarHidden)
        .background {
            GeometryReader { proxy in
                // 页面内 safeAreaInset / overlay 的落点是「系统底部安全区」（Home 指示条），
                // 不含祖先注入的页签栏，因此这里只取装饰自身高度：窗口底边到装饰顶边 − 系统安全区
                let window = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap { $0.windows }
                    .first { $0.isKeyWindow }
                let windowHeight = window?.bounds.height ?? proxy.frame(in: .global).maxY
                let height = max(0, windowHeight - proxy.frame(in: .global).minY - (window?.safeAreaInsets.bottom ?? 0))
                Color.clear
                    .onAppear { bottomChromeHeight = height }
                    .onChange(of: height) { bottomChromeHeight = $0 }
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

/// iPhone 底部页签栏：自绘以精确控制图标大小（系统 TabView 纯图标会过大）。
/// TODO 376 方案 C：悬浮圆角胶囊——四周圆角 26pt + 1pt 灰色描边与白色主界面分割 + 轻阴影，
/// 不再贴底通栏（左右内缩与底部间距由 RootView 的 safeAreaInset 外壳统一控制）。
private struct BottomTabBar: View {
    @Binding var selection: AppTab
    let tabs: [AppTab]

    @EnvironmentObject private var router: AppRouter

    /// 液体玻璃模式：开启时页签栏使用 Liquid Glass 背景，关闭时用实色背景
    @AppStorage("ui.liquidGlassMode") private var liquidGlassMode = true

    /// 胶囊圆角 / 条高（TODO 376 方案 C）
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
                        selection = tab
                    }
                } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 20))
                        .frame(maxWidth: .infinity)
                        .frame(height: barHeight)
                        .foregroundStyle(isSelected ? AppColors.primary : AppColors.textSecondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
            }
        }
        .frame(height: barHeight)
        .background(barBackground)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // 1pt 极浅描边：与 mini 播放器 / 多选操作栏统一为 `cardBorder`（TODO 385）
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(AppColors.cardBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
    }

    /// 页签栏背景：液体玻璃开 → Liquid Glass（iOS 26）/ 毛玻璃回退；关 → 实色
    @ViewBuilder
    private var barBackground: some View {
        if liquidGlassMode {
            if #available(iOS 26.0, *) {
                Rectangle()
                    .fill(Color.clear)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
        } else {
            Rectangle().fill(AppColors.sidebarBackground)
        }
    }
}
