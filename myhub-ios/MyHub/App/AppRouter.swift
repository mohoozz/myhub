import Foundation

/// 全局路由（跨模块跳转）：收藏页文件夹「在浏览中打开」等场景切换主导航 Tab。
final class AppRouter: ObservableObject {
    @Published var selectedTab: AppTab = .reading
}
