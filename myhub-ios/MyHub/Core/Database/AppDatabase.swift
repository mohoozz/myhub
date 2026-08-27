import Foundation
import GRDB

/// 本地数据库入口（GRDB / SQLite，IOS-002）。
/// 表结构见 `Records/`；通过 DatabaseMigrator 建表与版本迁移。
final class AppDatabase {
    static let shared = AppDatabase()

    private(set) var dbQueue: DatabaseQueue?

    private init() {}

    /// 打开（或创建）数据库并执行迁移，App 启动时调用
    func setup() throws {
        let url = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("myhub.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try Self.migrator.migrate(queue)
        dbQueue = queue
    }

    static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            // 连接源
            try db.create(table: Connection.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("type", .text).notNull()
                t.column("configJSON", .text).notNull()
                t.column("mountPoint", .text).notNull()
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["mountPoint"])
            }

            // 收藏
            try db.create(table: Favorite.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("connectionID", .integer).notNull()
                    .references(Connection.databaseTableName, onDelete: .cascade)
                t.column("filePath", .text).notNull()
                t.column("mediaType", .text).notNull()
                t.column("size", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["connectionID", "filePath"])
            }

            // 阅读/播放进度
            try db.create(table: ReadingProgress.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("connectionID", .integer).notNull()
                    .references(Connection.databaseTableName, onDelete: .cascade)
                t.column("filePath", .text).notNull()
                t.column("mediaType", .text).notNull()
                t.column("title", .text).notNull()
                t.column("cover", .text)
                t.column("progressJSON", .text).notNull()
                t.column("percent", .double).notNull().defaults(to: 0)
                t.column("finished", .boolean).notNull().defaults(to: false)
                t.column("updatedAt", .datetime).notNull()
                t.uniqueKey(["connectionID", "filePath"])
            }
            try db.create(index: "readingProgress_on_updatedAt",
                          on: ReadingProgress.databaseTableName, columns: ["updatedAt"])

            // 小说章节索引（可重建）
            try db.create(table: NovelIndex.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("connectionID", .integer).notNull()
                    .references(Connection.databaseTableName, onDelete: .cascade)
                t.column("filePath", .text).notNull()
                t.column("encoding", .text).notNull()
                t.column("chaptersJSON", .text).notNull()
                t.column("fileSize", .integer).notNull()
                t.column("modTime", .datetime).notNull()
                t.uniqueKey(["connectionID", "filePath"])
            }

            // 浏览器书签
            try db.create(table: Bookmark.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("url", .text).notNull()
                t.column("favicon", .text)
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["url"])
            }

            // 浏览器历史
            try db.create(table: BrowserHistory.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("url", .text).notNull()
                t.column("favicon", .text)
                t.column("visitedAt", .datetime).notNull()
            }
            try db.create(index: "browserHistory_on_visitedAt",
                          on: BrowserHistory.databaseTableName, columns: ["visitedAt"])

            // 起始页快捷入口
            try db.create(table: BrowserShortcut.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("url", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }

            // 下载任务
            try db.create(table: DownloadTask.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("connectionID", .integer).notNull()
                    .references(Connection.databaseTableName, onDelete: .cascade)
                t.column("remotePath", .text).notNull()
                t.column("localPath", .text).notNull()
                t.column("status", .text).notNull()
                t.column("progress", .double).notNull().defaults(to: 0)
            }

            // 动态（预留）
            try db.create(table: FeedItem.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("platform", .text).notNull()
                t.column("contentID", .text).notNull()
                t.column("type", .text).notNull()
                t.column("title", .text).notNull()
                t.column("cover", .text)
                t.column("url", .text).notNull()
                t.column("publishedAt", .datetime).notNull()
                t.uniqueKey(["platform", "contentID"])
            }
        }

        // v2：阅读/播放进度持久化文件指纹（fileSize/modTime）。
        // 「正在阅读」页 stat 成功后写回，重进 app 时先用旧指纹构造 entry 秒出封面，
        // 后台再静默 stat 校正，无需等待每次的网络 stat。
        migrator.registerMigration("v2_reading_fingerprint") { db in
            try db.alter(table: ReadingProgress.databaseTableName) { t in
                t.add(column: "fileSize", .integer)
                t.add(column: "modTime", .datetime)
            }
        }

        return migrator
    }()
}
