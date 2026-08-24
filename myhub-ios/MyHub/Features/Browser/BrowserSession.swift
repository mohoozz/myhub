import Foundation

/// 浏览器标签会话全局持有（TODO §1.1 页面保活 / §8.1 `TabManager` 落地处）：
/// 由 App 层以 `@StateObject` 持有并注入环境，切换页签不销毁会话。
final class BrowserSessionStore: ObservableObject {
    // TODO(8.1): 标签列表、激活标签、无痕开关、会话持久化（退出保存 + 启动恢复）
}
