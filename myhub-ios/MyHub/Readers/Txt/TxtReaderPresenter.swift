import Foundation

/// 纯 txt 阅读器打开上下文（浏览页 / 收藏页 / 正在阅读页统一入口）
struct TxtOpenContext: Identifiable, Equatable {
    let connection: Connection
    let entry: FileEntry

    var id: String { "\(connection.id ?? 0)|\(entry.path)" }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// 全局纯 txt 阅读器呈现：与小说阅读器并列的独立全屏路由，不随 Tab 切换销毁。
final class TxtReaderPresenter: ObservableObject {
    @Published var current: TxtOpenContext?

    func open(connection: Connection, entry: FileEntry) {
        current = TxtOpenContext(connection: connection, entry: entry)
    }

    func close() {
        current = nil
    }
}
