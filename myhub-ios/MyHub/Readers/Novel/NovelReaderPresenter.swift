import Foundation

/// 小说打开上下文（浏览页 / 收藏页 / 正在阅读页统一入口）
struct NovelOpenContext: Identifiable, Equatable {
    let connection: Connection
    let entry: FileEntry

    var id: String { "\(connection.id ?? 0)|\(entry.path)" }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// 全局小说阅读器呈现（TODO §5）：与播放器同为独立全屏路由，不随 Tab 切换销毁。
/// 漫画阅读器（TODO §6）落地后，epub 图集「一键转漫画」经 `onOpenComic` 接管。
final class NovelReaderPresenter: ObservableObject {
    @Published var current: NovelOpenContext?
    /// epub 图集型转交漫画阅读器的回调（§6 接入后赋值）
    var onOpenComic: ((NovelOpenContext) -> Void)?

    func open(connection: Connection, entry: FileEntry) {
        current = NovelOpenContext(connection: connection, entry: entry)
    }

    func close() {
        current = nil
    }
}
