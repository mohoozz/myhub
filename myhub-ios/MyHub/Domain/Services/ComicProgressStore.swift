import Foundation
import CryptoKit
import GRDB
import UIKit

/// 漫画阅读进度落库（IOS-207 / IOS-209）：
/// progressJSON 存 `ComicAnchor`（页码 + 文件指纹，排版无关）；落库后广播
/// `playbackProgressDidChange` 供「正在阅读」列表自动刷新（与播放/小说进度共用通道）。
enum ComicProgressStore {

    /// 漫画进度锚点：页码 + 文件指纹（fileSize + modTime，文件被替换则进度作废）
    struct ComicAnchor: Codable {
        var page: Int
        var fileSize: Int64
        var modTime: TimeInterval

        func fingerprintMatches(fileSize: Int64, modTime: Date) -> Bool {
            self.fileSize == fileSize && abs(self.modTime - modTime.timeIntervalSince1970) < 2
        }

        func json() -> String {
            guard let data = try? JSONEncoder().encode(self),
                  let string = String(data: data, encoding: .utf8) else { return "{}" }
            return string
        }
    }

    /// 查询历史页码（指纹不匹配返回 nil，由调用方提示重置）
    static func loadAnchor(
        connectionID: Int64, path: String, fileSize: Int64, modTime: Date
    ) -> (anchor: ComicAnchor?, stale: Bool) {
        guard let db = AppDatabase.shared.dbQueue,
              let record = try? db.read({ database in
                  try ReadingProgress
                      .filter(Column("connectionID") == connectionID && Column("filePath") == path)
                      .fetchOne(database)
              }), !record.finished,
              let data = record.progressJSON.data(using: .utf8),
              let anchor = try? JSONDecoder().decode(ComicAnchor.self, from: data)
        else { return (nil, false) }
        if anchor.fingerprintMatches(fileSize: fileSize, modTime: modTime) {
            return (anchor, false)
        }
        return (nil, true)   // 文件已被替换
    }

    /// 保存进度（upsert）；finished 时 percent = 1
    static func save(
        connectionID: Int64,
        path: String,
        title: String,
        anchor: ComicAnchor,
        pageCount: Int,
        finished: Bool,
        cover: String? = nil
    ) {
        guard let db = AppDatabase.shared.dbQueue else { return }
        let percent = pageCount > 0 ? Double(anchor.page + 1) / Double(pageCount) : 0
        let clamped = min(1, max(0, percent))
        try? db.write { database in
            if var existing = try ReadingProgress
                .filter(Column("connectionID") == connectionID && Column("filePath") == path)
                .fetchOne(database) {
                existing.progressJSON = anchor.json()
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
                    mediaType: .comic,
                    title: title,
                    cover: cover,
                    progressJSON: anchor.json(),
                    percent: finished ? 1 : clamped,
                    finished: finished,
                    updatedAt: Date()
                )
                try record.insert(database)
            }
        }
        NotificationCenter.default.post(name: .playbackProgressDidChange, object: nil)
    }

    /// 封面缩略图写入缓存分区（Caches/Thumbnails），返回缓存文件名（供 ReadingProgress.cover）
    static func cacheCover(data: Data, connectionID: Int64, path: String) -> String? {
        guard let image = ImageDownsampler.downsample(data: data, maxPixel: 512),
              let jpeg = image.jpegData(compressionQuality: 0.8) else { return nil }
        let raw = "comic-cover|\(connectionID)|\(path)"
        let key = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        let name = "comic-\(key).jpg"
        let url = CacheManager.shared.url(for: .thumbnails).appendingPathComponent(name)
        try? jpeg.write(to: url, options: .atomic)
        CacheManager.shared.evictPartitionIfNeeded(.thumbnails)   // 封面分区 LRU（IOS-605）
        return name
    }
}
