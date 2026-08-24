import Foundation

/// App 启动状态（TODO §1.1）：
/// 首启 / 初始化（数据库、网络判定、缓存预热）期间由 RootView 展示 `LaunchLoadingView`，避免长白屏。
final class AppState: ObservableObject {
    @Published private(set) var isReady = false

    func launch() async {
        guard !isReady else { return }
        try? AppDatabase.shared.setup()   // 建表迁移随 §1.2 落地，失败不阻塞启动
        await FavoritesStore.shared.reload()   // 收藏预载（浏览页星标/收藏页共用）
        // 缓存预热：统一容量上限兜底淘汰（IOS-605，跨分区按最久未访问回收超额占用）
        Task.detached(priority: .utility) {
            CacheManager.shared.enforceGlobalLimit()
        }
        await MainActor.run { isReady = true }
        AppLogger.shared.log("应用启动完成")
    }
}
