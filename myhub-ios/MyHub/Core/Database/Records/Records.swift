import Foundation
import GRDB

// MARK: - 连接源（IOS-101）

/// 连接源类型；ftp / sftp / nfs 为预留（§8.2 协议适配器扩展点）
enum ConnectionType: String, Codable, CaseIterable {
    case local, webdav, smb
    case ftp, sftp, nfs   // 预留
}

struct Connection: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var name: String
    var type: ConnectionType
    var configJSON: String      // 地址、共享名、根路径等（不含密码；密码存 Keychain "conn.<id>"）
    var mountPoint: String
    var enabled: Bool
    var createdAt: Date

    static let databaseTableName = "connection"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    func decodeConfig<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(T.self, from: Data(configJSON.utf8))
    }

    static func makeConfigJSON<T: Encodable>(_ config: T) -> String {
        guard let data = try? JSONEncoder().encode(config),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}

/// WebDAV 连接配置（密码不入库）
struct WebDAVConfig: Codable {
    var baseURL: String         // https://host:port
    var username: String
    var rootPath: String = "/"
}

/// SMB 连接配置（密码不入库）
struct SMBConfig: Codable {
    var host: String
    var share: String
    var username: String?       // nil + guest=true 表示访客
    var domain: String?         // 域 / 工作组
    var guest: Bool = false
}

/// 本地连接配置
struct LocalConfig: Codable {
    var path: String?           // 自定义根目录（默认应用沙盒 Documents）
    var bookmarkData: Data?     // 「文件」App 共享目录的 Security-Scoped Bookmark
}

// MARK: - 收藏（IOS-107）

struct Favorite: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var connectionID: Int64
    var filePath: String        // (connectionID, filePath) 唯一
    var mediaType: MediaType
    var size: Int64
    var createdAt: Date

    static let databaseTableName = "favorite"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - 阅读/播放进度（IOS-209）

struct ReadingProgress: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var connectionID: Int64
    var filePath: String        // (connectionID, filePath) 唯一
    var mediaType: MediaType
    var title: String
    var cover: String?
    /// 秒数(音视频) / 全局字节偏移(txt) / EpubAnchor(epub) / 页码(漫画) 的 JSON
    var progressJSON: String
    var percent: Double
    var finished: Bool
    var updatedAt: Date

    static let databaseTableName = "readingProgress"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// epub 排版无关进度锚点（IOS-205/206）：spine 序号 + 段内偏移；不实现完整 CFI
struct EpubAnchor: Codable {
    var spineIndex: Int
    var paragraphIndex: Int
    var characterOffset: Int
}

// MARK: - 小说章节索引（可重建缓存）

struct NovelIndex: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var connectionID: Int64
    var filePath: String
    var encoding: String
    var chaptersJSON: String    // 各章标题 + 起始字节偏移列表（供全局偏移二分反查章节）
    var fileSize: Int64         // 文件指纹：fileSize + modTime，变更则重建
    var modTime: Date

    static let databaseTableName = "novelIndex"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// 章节索引条目（chaptersJSON 元素）
struct ChapterInfo: Codable {
    var title: String
    var startOffset: Int64      // 全局字节偏移
}

// MARK: - 浏览器（IOS-403 / 402）

struct Bookmark: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var title: String
    var url: String             // 唯一
    var favicon: String?
    var createdAt: Date

    static let databaseTableName = "bookmark"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct BrowserHistory: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var title: String
    var url: String
    var favicon: String?
    var visitedAt: Date

    static let databaseTableName = "browserHistory"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct BrowserShortcut: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var title: String
    var url: String
    var sortOrder: Int

    static let databaseTableName = "browserShortcut"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - 下载任务（IOS-603）

enum DownloadStatus: String, Codable {
    case queued, downloading, paused, done, failed
}

struct DownloadTask: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var connectionID: Int64
    var remotePath: String
    var localPath: String
    var status: DownloadStatus
    var progress: Double

    static let databaseTableName = "downloadTask"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - 动态（IOS-301，预留）

enum FeedItemType: String, Codable {
    case video, audio, text
}

struct FeedItem: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var platform: String
    var contentID: String       // (platform, contentID) 唯一
    var type: FeedItemType
    var title: String
    var cover: String?
    var url: String
    var publishedAt: Date

    static let databaseTableName = "feedItem"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
