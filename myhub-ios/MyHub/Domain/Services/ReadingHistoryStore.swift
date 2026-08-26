import Foundation
import GRDB

/// 「正在阅读」进度记录全局 Store（IOS-209 / TODO §7）：
/// ReadingProgress 表唯一读取源（按最后阅读时间降序，含已读完记录——保留至用户手动删除）。
/// 订阅 `playbackProgressDidChange`（播放 / 小说 / 漫画进度落库共用广播通道），
/// **进度上报后自动刷新列表**，无需手动下拉。
/// 单例 + environmentObject 注入同一实例（与 FavoritesStore 同一模式）。
@MainActor
final class ReadingHistoryStore: ObservableObject {
    static let shared = ReadingHistoryStore()

    @Published private(set) var records: [ReadingProgress] = []

    private var progressObserver: NSObjectProtocol?

    private init() {
        progressObserver = NotificationCenter.default.addObserver(
            forName: .playbackProgressDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    deinit {
        if let progressObserver {
            NotificationCenter.default.removeObserver(progressObserver)
        }
    }

    /// 全量重载：最后阅读时间降序
    func reload() {
        guard let db = AppDatabase.shared.dbQueue else { return }
        records = (try? db.read {
            try ReadingProgress.order(Column("updatedAt").desc).fetchAll($0)
        }) ?? []
    }

    // MARK: - 删除阅读记录（手动移除；不影响源文件）

    func remove(_ record: ReadingProgress) {
        guard let id = record.id else { return }
        remove(ids: [id])
    }

    func remove(ids: [Int64]) {
        guard let db = AppDatabase.shared.dbQueue, !ids.isEmpty else { return }
        _ = try? db.write { database in
            try database.execute(
                sql: "DELETE FROM readingProgress WHERE id IN (\(ids.map { "\($0)" }.joined(separator: ",")))"
            )
        }
        reload()
    }

    // MARK: - 源文件同步（浏览界面删除 / 移动 / 重命名时，TODO §7.309）

    /// 删除某连接下指定路径的阅读记录（源文件被删除或移动后同步清理，避免残留失效记录）
    func remove(connectionID: Int64, filePaths: Set<String>) {
        guard let db = AppDatabase.shared.dbQueue, !filePaths.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: filePaths.count).joined(separator: ",")
        var arguments: [DatabaseValueConvertible?] = [connectionID]
        arguments.append(contentsOf: filePaths.sorted())
        _ = try? db.write { database in
            try database.execute(
                sql: "DELETE FROM readingProgress WHERE connectionID = ? AND filePath IN (\(placeholders))",
                arguments: StatementArguments(arguments)
            )
        }
        reload()
    }

    /// 更新某连接下记录的 filePath（源文件重命名后同步，目录重命名时内部文件路径前缀一并更新）
    func updatePath(connectionID: Int64, from oldPath: String, to newPath: String) {
        guard let db = AppDatabase.shared.dbQueue else { return }
        _ = try? db.write { database in
            try database.execute(
                sql: """
                    UPDATE readingProgress
                    SET filePath = ? || substr(filePath, length(?) + 1)
                    WHERE connectionID = ?
                      AND (filePath = ? OR filePath LIKE ?)
                    """,
                arguments: StatementArguments([newPath, oldPath, connectionID, oldPath, "\(oldPath)/%"])
            )
        }
        reload()
    }
}
