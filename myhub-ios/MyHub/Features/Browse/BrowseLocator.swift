import Foundation
import SwiftUI

/// 「定位到原路径」全局触发器
@MainActor
final class BrowseLocator: ObservableObject {
    struct Request: Equatable {
        let id = UUID()
        let connectionID: Int64
        let filePath: String

        static func == (lhs: Request, rhs: Request) -> Bool { lhs.id == rhs.id }
    }

    /// 当前定位高亮目标：连接 + 文件全路径 + token（标识本次定位）
    struct Highlight: Equatable {
        let connectionID: Int64
        let path: String
        let token: UUID
    }

    /// 待处理的跳转请求（浏览主页消费后置空）
    @Published private(set) var request: Request?
    /// 当前定位高亮（约 10s 后自动清除；目标目录页滚动定位到目标时续期）
    @Published private(set) var highlight: Highlight?

    private var dismissTask: Task<Void, Never>?

    func locate(connectionID: Int64, filePath: String) {
        let path = StoragePath.normalize(filePath)
        let token = UUID()
        request = Request(connectionID: connectionID, filePath: path)
        withAnimation(.appQuick) {
            highlight = Highlight(connectionID: connectionID, path: path, token: token)
        }
        scheduleDismiss(token: token)
    }

    func consume() {
        request = nil
    }

    /// 高亮续期：目标目录页完成加载并滚动定位到目标时调用
    func keepAliveHighlight(token: UUID) {
        guard highlight?.token == token else { return }
        scheduleDismiss(token: token)
    }

    /// 约 10s 后清除高亮（不常亮）；期间若有新定位（token 不同）则不影响新高亮
    private func scheduleDismiss(token: UUID) {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, let self, self.highlight?.token == token else { return }
            withAnimation(.appQuick) { self.highlight = nil }
        }
    }
}
