import Foundation

/// 全局路由（跨模块跳转）：收藏页文件夹「在浏览中打开」等场景切换主导航 Tab。
final class AppRouter: ObservableObject {
    @Published var selectedTab: AppTab = .reading {
        didSet {
            guard oldValue != selectedTab else { return }
            previousTab = oldValue
        }
    }

    /// 切换到当前页签之前所停留的页签：内置浏览器沉浸态的退出目标
    /// （原型 `prototype/browser-exit-handle-collapse-options.html` 策略 S1：
    /// 点左下角退出钮 = 回到「进入浏览器前的页签」，页签栏与 mini 播放器随之恢复）。
    /// 非 `@Published`：仅作为跳转目标读取，不驱动界面刷新。
    private(set) var previousTab: AppTab = .reading

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

    /// 回到上一个页签（内置浏览器沉浸态退出）。
    /// 两种情况回落到首个页签：①上一个页签就是当前页签（如首启即停在浏览器，无处可退）；
    /// ②上一个页签不在 iPhone 底部页签内（`.favorites` / `.feed` 为 iPad 侧边栏独有，
    /// 直落会让 `RootView.keepAlivePhoneTabs` 的保活 ZStack 无任何页签可显示，表现为白屏）。
    func backToPreviousTab() {
        guard previousTab != selectedTab, AppTab.phoneTabs.contains(previousTab) else {
            selectedTab = AppTab.phoneTabs.first ?? .reading
            return
        }
        selectedTab = previousTab
    }
}
