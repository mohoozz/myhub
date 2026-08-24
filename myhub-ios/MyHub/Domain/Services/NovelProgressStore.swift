import Foundation
import GRDB

/// 小说阅读进度落库（IOS-209 / IOS-205/206）：
/// progressJSON 存 `NovelAnchor`（txt 全局字节偏移 / epub spine+段内偏移，排版无关锚点），
/// 落库后广播 `playbackProgressDidChange` 供「正在阅读」列表自动刷新（与播放进度共用通道）。
enum NovelProgressStore {

    /// 查询历史进度锚点
    static func loadAnchor(
        connectionID: Int64, path: String, isEpub: Bool,
        fileSize: Int64, modTime: Date
    ) -> NovelAnchor? {
        guard let db = AppDatabase.shared.dbQueue,
              let record = try? db.read({ database in
                  try ReadingProgress
                      .filter(Column("connectionID") == connectionID && Column("filePath") == path)
                      .fetchOne(database)
              }), !record.finished else { return nil }
        return NovelAnchor.parse(record.progressJSON, fileSize: fileSize, modTime: modTime, isEpub: isEpub)
    }

    /// 保存进度（upsert）；finished 时 percent = 1
    static func save(
        connectionID: Int64,
        path: String,
        title: String,
        anchor: NovelAnchor,
        percent: Double,
        finished: Bool,
        cover: String? = nil
    ) {
        guard let db = AppDatabase.shared.dbQueue else { return }
        let json = anchor.json()
        let clamped = min(1, max(0, percent))
        try? db.write { database in
            if var existing = try ReadingProgress
                .filter(Column("connectionID") == connectionID && Column("filePath") == path)
                .fetchOne(database) {
                existing.progressJSON = json
                existing.percent = finished ? 1 : clamped
                existing.finished = finished
                existing.title = title
                if let cover { existing.cover = cover }
                existing.updatedAt = Date()
                try existing.update(database)
            } else {
                var record = ReadingProgress(
                    id: nil,
                    connectionID: connectionID,
                    filePath: path,
                    mediaType: .novel,
                    title: title,
                    cover: cover,
                    progressJSON: json,
                    percent: finished ? 1 : clamped,
                    finished: finished,
                    updatedAt: Date()
                )
                try record.insert(database)
            }
        }
        NotificationCenter.default.post(name: .playbackProgressDidChange, object: nil)
    }
}
