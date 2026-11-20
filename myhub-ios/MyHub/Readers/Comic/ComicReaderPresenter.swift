import Foundation

/// 全局漫画阅读器呈现：与播放器/小说阅读器同为独立全屏路由，不随 Tab 切换销毁。
final class ComicReaderPresenter: ObservableObject {
    @Published private(set) var current: NovelOpenContext?

    /// 打开漫画；重复点击同一文件（加载中/阅读中）直接忽略（防抖去重）
    func open(connection: Connection, entry: FileEntry) {
        let context = NovelOpenContext(connection: connection, entry: entry)
        guard current != context else { return }
        current = context
    }

    /// 翻完打开下一本（entry 变更 → id 变化，fullScreenCover 重建阅读器视图）
    func openNext(connection: Connection, entry: FileEntry) {
        current = NovelOpenContext(connection: connection, entry: entry)
    }

    func close() {
        current = nil
    }
}
