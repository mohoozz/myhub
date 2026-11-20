import SwiftUI

@main
struct MyHubApp: App {
    // 界面方向回调宿主：播放页横竖屏切换依赖动态方向掩码（App 平时锁竖屏）
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    init() {
        _ = AppLogger.shared
        GlobalAppearance.apply()
        AppSettings.Reader.migrateReaderThemeToAutoIfNeeded()   // 旧版固定主题 → 跟随系统（一次性迁移）
        AppSettings.Player.migratePreloadWindowIfNeeded()   // 旧默认预读 30s → 10s（发热优化）
        NetworkPathMonitor.shared.start()
    }

    /// scenePhase 可读名称（日志用）
    private static func describe(_ phase: ScenePhase) -> String {
        switch phase {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
    // 全局状态：主题 / 启动 / 播放呈现 / 弹出菜单 / 浏览器会话（全局持有）
    @StateObject private var themeManager = ThemeManager()
    @StateObject private var appState = AppState()
    @StateObject private var playerPresenter = PlayerPresenter()
    @StateObject private var popupPresenter = PopupMenuPresenter()
    @StateObject private var browserSession = BrowserSessionStore()
    @StateObject private var browseLocator = BrowseLocator()
    @StateObject private var router = AppRouter()              // 全局路由（跨 Tab 跳转）
    @StateObject private var favoritesStore = FavoritesStore.shared   // 收藏唯一数据源（双向同步）
    @StateObject private var readingHistory = ReadingHistoryStore.shared
    @StateObject private var novelReader = NovelReaderPresenter()
    @StateObject private var comicReader = ComicReaderPresenter()
    @StateObject private var txtReader = TxtReaderPresenter()         // 纯 txt 阅读器全屏路由（txt 默认打开）
    @StateObject private var appLock = AppLockManager.shared
    @StateObject private var browserDataStore = BrowserDataStore.shared
    @StateObject private var browseDisplaySettings = BrowseDisplaySettings.shared
    @StateObject private var connectionStore = ConnectionStore()   // 连接源唯一数据源（浏览页/设置页/回收站共享，测试结果实时同步）
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .onAppear {
                    PlaybackProgressStore.shared.attach()   // 播放进度上报落库（§4.2）
                    NowPlaying.shared.attach()              // 后台音频 + 锁屏/控制中心（§4.3）
                    // epub 图集型「以漫画阅读器打开」→ 漫画阅读器接管
                    novelReader.onOpenComic = { context in
                        comicReader.open(connection: context.connection, entry: context.entry)
                    }
                }
                .preferredColorScheme(themeManager.colorScheme)
                .environmentObject(themeManager)
                .environmentObject(appState)
                .environmentObject(playerPresenter)
                .environmentObject(popupPresenter)
                .environmentObject(browserSession)
                .environmentObject(browseLocator)
                .environmentObject(router)
                .environmentObject(favoritesStore)
                .environmentObject(readingHistory)
                .environmentObject(novelReader)
                .environmentObject(comicReader)
                .environmentObject(txtReader)
                .environmentObject(appLock)
                .environmentObject(browserDataStore)
                .environmentObject(browseDisplaySettings)
                .environmentObject(connectionStore)
                // 进入后台时按设置上锁，返回前台显示锁定遮罩
                .onChange(of: scenePhase) { phase in
                    // 全相位面包屑：熄屏→亮屏的 inactive/background/active 时序
                    let core = PlayerCore.shared
                    AppLogger.shared.log(
                        "scenePhase -> \(Self.describe(phase)) 播放=\(core.state.logDescription) 引擎=\(core.engineDiagnostics) item=\(core.currentItem?.title ?? "nil") 锁定=[\(RoutedWebDAVAdapter.lockSnapshot())] 代理=\(LocalStreamProxy.shared.healthSnapshot()) 网络=\(NetworkPathMonitor.shared.snapshot())",
                        level: .info, module: "lifecycle"
                    )
                    if phase == .background {
                        appLock.lockForBackground()
                        browserSession.persistNow()
                        // 网页媒体兜底暂停：标签常驻保活且允许自动播放
                        browserSession.suspendAllMediaPlayback()
                        NetworkRecovery.shared.noteDidEnterBackground()
                        Task { await SegmentCache.shared.flushIndexNow() }   // 分片索引合并落盘的兜底落盘
                    } else if phase == .active {
                        NetworkRecovery.shared.recoverAfterReturningToForeground()
                        // 回到前台重算浏览器可见性：可见才解除媒体暂停
                        browserSession.setBrowserVisible(router.selectedTab == .browser)
                    }
                }
                .overlay {
                    if appLock.isLocked {
                        AppLockView()
                    }
                }
        }
    }
}
