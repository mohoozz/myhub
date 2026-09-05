import Foundation
import GRDB

extension Notification.Name {
    /// 播放进度落库后广播（「正在阅读」列表自动刷新，TODO §7 订阅）
    static let playbackProgressDidChange = Notification.Name("playbackProgressDidChange")
}

/// 播放进度上报落库（IOS-209）：
/// PlayerCore.onProgressReport（5s 节流 + 暂停/seek/结束/退出强制）→ ReadingProgress upsert。
final class PlaybackProgressStore {
    static let shared = PlaybackProgressStore()

    private init() {}

    /// App 启动时挂接（MyHubApp 根视图 onAppear）
    @MainActor
    func attach() {
        PlayerCore.shared.onProgressReport = { [weak self] report in
            self?.save(report)
        }
    }

    private func save(_ report: PlaybackProgressReport) {
        guard let connectionID = report.connectionID,
              let db = AppDatabase.shared.dbQueue else { return }
        let percent = report.duration > 0 ? min(1, max(0, report.position / report.duration)) : 0
        try? db.write { database in
            if var existing = try ReadingProgress
                .filter(Column("connectionID") == connectionID && Column("filePath") == report.path)
                .fetchOne(database) {
                existing.progressJSON = String(report.position)
                existing.percent = report.finished ? 1 : percent
                existing.finished = report.finished
                existing.title = report.title
                existing.updatedAt = Date()
                try existing.update(database)
            } else {
                let record = ReadingProgress(
                    id: nil,
                    connectionID: connectionID,
                    filePath: report.path,
                    mediaType: report.mediaType,
                    title: report.title,
                    cover: nil,
                    progressJSON: String(report.position),
                    percent: report.finished ? 1 : percent,
                    finished: report.finished,
                    updatedAt: Date()
                )
                try record.insert(database)
            }
        }
        NotificationCenter.default.post(name: .playbackProgressDidChange, object: nil)
    }
}
