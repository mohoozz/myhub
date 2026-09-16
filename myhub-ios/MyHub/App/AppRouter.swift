import Foundation

/// 全局路由（跨模块跳转）：收藏页文件夹「在浏览中打开」等场景切换主导航 Tab。
final class AppRouter: ObservableObject {
    @Published var selectedTab: AppTab = .reading

    /// 「重复点击当前页签」请求：每次点击生成新 id，保证连续多次点击都能触发；
    /// 对应页签据此回到起始界面（如浏览页回到路径源选择列表）。
    @Published private(set) var reselectRequest: ReselectRequest?

    struct ReselectRequest: Equatable {
        let tab: AppTab
        let id = UUID()

        static func == (lhs: ReselectRequest, rhs: ReselectRequest) -> Bool { lhs.id == rhs.id }
    }

    /// 点击已选中的页签时调用（由底部页签栏触发）
    func reselect(_ tab: AppTab) {
        reselectRequest = ReselectRequest(tab: tab)
    }
}
