import Foundation

/// 全局路由（跨模块跳转）：收藏页文件夹「在浏览中打开」等场景切换主导航 Tab。
final class AppRouter: ObservableObject {
    @Published var selectedTab: AppTab = .reading {
        didSet {
            guard oldValue != selectedTab else { return }
            previousTab = oldValue
        }
    }

    /// 进入浏览器前停留的页签，即沉浸态退出的目标页签
    private(set) var previousTab: AppTab = .reading

    /// 「重复点击当前页签」请求：每次点击生成新 id，保证连续多次点击都能触发
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

    /// 回到上一个页签（内置浏览器沉浸态退出）。
    func backToPreviousTab() {
        guard previousTab != selectedTab, AppTab.phoneTabs.contains(previousTab) else {
            selectedTab = AppTab.phoneTabs.first ?? .reading
            return
        }
        selectedTab = previousTab
    }
}
