import Foundation
import GRDB

/// 「正在阅读」进度记录全局 Store
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
        do {
            records = try db.read {
                try ReadingProgress.order(Column("updatedAt").desc).fetchAll($0)
            }
        } catch {
            // 读取失败时保留上一次的列表：此前 `?? []` 会把整页清成空态
            AppLogger.shared.log(
                "ReadingHistoryStore.reload 失败，保留旧列表：\(error)",
                level: .error,
                module: "history"
            )
        }
    }

 // MARK: - 删除阅读记录（手动移除；不影响源文件）

    func remove(_ record: ReadingProgress) {
        guard let id = record.id else { return }
        remove(ids: [id])
    }

    func remove(ids: [Int64]) {
        guard let db = AppDatabase.shared.dbQueue, !ids.isEmpty else { return }
        suppressProgressWrites(from: records.filter { ids.contains($0.id ?? -1) })
        _ = try? db.write { database in
            try database.execute(
                sql: "DELETE FROM readingProgress WHERE id IN (\(ids.map { "\($0)" }.joined(separator: ",")))"
            )
        }
        reload()
    }

    /// 撤销删除：把删除前缓存的记录原样插回。
    func restore(_ snapshots: [ReadingProgress]) {
        guard let db = AppDatabase.shared.dbQueue, !snapshots.isEmpty else { return }
        for record in snapshots {
            PlaybackProgressStore.shared.resume(
                connectionID: record.connectionID, path: record.filePath
            )
        }
        _ = try? db.write { database in
            for record in snapshots {
                // insert 失败（唯一约束冲突）不应中断其余记录的回插
                try? record.insert(database)
            }
        }
        reload()
    }

    /// 记录删除后短时抑制播放器的进度回写（播放器收尾的强制上报可能晚于删除，会把记录复活）
    private func suppressProgressWrites(from removed: [ReadingProgress]) {
        guard !removed.isEmpty else { return }
        let grouped = Dictionary(grouping: removed, by: \.connectionID)
        for (connectionID, group) in grouped {
            PlaybackProgressStore.shared.suppress(
                connectionID: connectionID, paths: Set(group.map(\.filePath))
            )
        }
    }

 // MARK: - 源文件同步（浏览界面删除 / 移动 / 重命名时）

    /// 删除某连接下指定路径的阅读记录（源文件被删除或移动后同步清理，避免残留失效记录）
    func remove(connectionID: Int64, filePaths: Set<String>) {
        guard let db = AppDatabase.shared.dbQueue, !filePaths.isEmpty else { return }
        PlaybackProgressStore.shared.suppress(connectionID: connectionID, paths: filePaths)
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

    /// 删除某路径**及其子路径**下的阅读记录（删除/移走目录时用）。
    func removeTree(connectionID: Int64, path: String) {
        guard let db = AppDatabase.shared.dbQueue, !path.isEmpty else { return }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let affected = records.filter {
            $0.connectionID == connectionID
                && ($0.filePath == path || $0.filePath.hasPrefix(prefix))
        }
        PlaybackProgressStore.shared.suppress(
            connectionID: connectionID, paths: Set(affected.map(\.filePath))
        )
        _ = try? db.write { database in
            try database.execute(
                sql: """
                    DELETE FROM readingProgress
                    WHERE connectionID = ? AND (filePath = ? OR filePath LIKE ?)
                    """,
                arguments: StatementArguments([connectionID, path, "\(path)/%"] as [DatabaseValueConvertible?])
            )
        }
        reload()
    }

 // MARK: - 文件指纹（stat 成功后写回，重进时秒出封面）

    /// 更新指定记录的文件指纹（仅 stat 成功时调用；失败保留旧指纹，重进时封面仍可命中缓存）
    func updateFingerprint(recordID: Int64, size: Int64, modTime: Date) {
        guard let db = AppDatabase.shared.dbQueue else { return }
        _ = try? db.write { database in
            try database.execute(
                sql: "UPDATE readingProgress SET fileSize = ?, modTime = ? WHERE id = ?",
                arguments: [size, modTime, recordID]
            )
        }
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
                arguments: StatementArguments([newPath, oldPath, connectionID, oldPath, "\(oldPath)/%"] as [DatabaseValueConvertible?])
            )
        }
        reload()
    }
}
