import Foundation

/// 「定位到原路径」全局触发器（IOS-704）：
/// 收藏 / 正在阅读等模块调用 `locate`，浏览页跳转到目标所在目录并以呼吸灯高亮约 10s（不常亮）。
/// 由 MyHubApp 注入 environmentObject。
final class BrowseLocator: ObservableObject {
    struct Request: Equatable {
        let id = UUID()
        let connectionID: Int64
        let filePath: String

        static func == (lhs: Request, rhs: Request) -> Bool { lhs.id == rhs.id }
    }

    @Published private(set) var request: Request?

    func locate(connectionID: Int64, filePath: String) {
        request = Request(connectionID: connectionID, filePath: StoragePath.normalize(filePath))
    }

    func consume() {
        request = nil
    }
}
