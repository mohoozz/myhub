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
}
