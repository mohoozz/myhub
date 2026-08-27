import SwiftUI

@main
struct MyHubApp: App {
    // 界面方向回调宿主：播放页横竖屏切换依赖动态方向掩码（App 平时锁竖屏）
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    init() {
        _ = AppLogger.shared   // 尽早初始化日志 + 安装崩溃捕获（避免启动早期崩溃漏捕获）
        AppSettings.Reader.migrateReaderThemeToAutoIfNeeded()   // 旧版固定主题 → 跟随系统（一次性迁移）
    }
    // 全局状态：主题 / 启动 / 播放呈现 / 弹出菜单 / 浏览器会话（§2.2.2 全局持有）
    @StateObject private var themeManager = ThemeManager()
    @StateObject private var appState = AppState()
    @StateObject private var playerPresenter = PlayerPresenter()
    @StateObject private var popupPresenter = PopupMenuPresenter()
    @StateObject private var browserSession = BrowserSessionStore()
    @StateObject private var browseLocator = BrowseLocator()   // 「定位到原路径」全局触发（IOS-704）
    @StateObject private var router = AppRouter()              // 全局路由（跨 Tab 跳转）
    @StateObject private var favoritesStore = FavoritesStore.shared   // 收藏唯一数据源（双向同步）
    @StateObject private var readingHistory = ReadingHistoryStore.shared   // 正在阅读进度（上报后自动刷新，TODO §7）
    @StateObject private var novelReader = NovelReaderPresenter()     // 小说阅读器全屏路由（TODO §5）
    @StateObject private var comicReader = ComicReaderPresenter()     // 漫画阅读器全屏路由（TODO §6）
    @StateObject private var txtReader = TxtReaderPresenter()         // 纯 txt 阅读器全屏路由（txt 默认打开）
    @StateObject private var appLock = AppLockManager.shared          // 应用锁（TODO §10 安全）
    @StateObject private var browserDataStore = BrowserDataStore.shared   // 浏览器书签/历史/快捷入口唯一数据源（TODO §8.3）
    @StateObject private var browseDisplaySettings = BrowseDisplaySettings.shared   // 浏览显示偏好（文件名行数等，IOS-102）
    @StateObject private var connectionStore = ConnectionStore()   // 连接源唯一数据源（浏览页/设置页/回收站共享，测试结果实时同步）
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .onAppear {
                    PlaybackProgressStore.shared.attach()   // 播放进度上报落库（§4.2）
                    NowPlaying.shared.attach()              // 后台音频 + 锁屏/控制中心（§4.3）
                    // epub 图集型「以漫画阅读器打开」→ 漫画阅读器接管（TODO §6）
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
                // 进入后台时按设置上锁，返回前台显示锁定遮罩（TODO §10 安全）；
                // 同时兜底落盘浏览器会话，确保导航后立即退出也不丢失
                .onChange(of: scenePhase) { phase in
                    if phase == .background {
                        appLock.lockForBackground()
                        browserSession.persistNow()
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
