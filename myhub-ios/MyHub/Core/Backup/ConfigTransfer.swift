import Foundation
import GRDB

/// 导出包：连接源（不含明文密码，密码留 Keychain）+ 偏好设置快照（§2.3 数据导入导出）
struct ConfigBundle: Codable {
    var formatVersion: Int = 1
    var exportedAt: Date
    var appVersion: String
    var connections: [Connection]
    var preferences: PreferencesSnapshot
}

/// 偏好快照（显式字段，保证跨版本稳定）
struct PreferencesSnapshot: Codable {
    var readerFontSize: Double
    var readerLineSpacing: Double
    var readerTheme: String
    var readerPageMode: String
    var comicDirection: String
    var playerDefaultSpeed: Double
    var decodePreference: String
    var preloadSeconds: Double
    var audioOnlyByDefault: Bool
    var volumeStep: Double
    var searchEngine: String
    var customSearchTemplate: String
    var browserUserAgent: String
    var cacheLimitMB: Int
    var contentCachingEnabled: Bool
    var trashRetentionDays: Int

    static func capture() -> PreferencesSnapshot {
        PreferencesSnapshot(
            readerFontSize: AppSettings.Reader.fontSize,
            readerLineSpacing: AppSettings.Reader.lineSpacing,
            readerTheme: AppSettings.Reader.theme.rawValue,
            readerPageMode: AppSettings.Reader.pageMode.rawValue,
            comicDirection: AppSettings.Reader.comicDirection.rawValue,
            playerDefaultSpeed: AppSettings.Player.defaultSpeed,
            decodePreference: AppSettings.Player.decodePreference.rawValue,
            preloadSeconds: AppSettings.Player.preloadSeconds,
            audioOnlyByDefault: AppSettings.Player.audioOnlyByDefault,
            volumeStep: AppSettings.Player.volumeStep,
            searchEngine: AppSettings.Browser.searchEngine.rawValue,
            customSearchTemplate: AppSettings.Browser.customSearchTemplate,
            browserUserAgent: AppSettings.Browser.userAgent.rawValue,
            cacheLimitMB: AppSettings.Cache.totalLimitMB,
            contentCachingEnabled: AppSettings.Cache.contentCachingEnabled,
            trashRetentionDays: AppSettings.Trash.retentionDays
        )
    }

    func apply() {
        AppSettings.Reader.fontSize = readerFontSize
        AppSettings.Reader.lineSpacing = readerLineSpacing
        AppSettings.Reader.theme = ReaderTheme(rawValue: readerTheme) ?? .auto
        AppSettings.Reader.pageMode = ReaderPageMode(rawValue: readerPageMode) ?? .paging
        AppSettings.Reader.comicDirection = ComicReadingDirection(rawValue: comicDirection) ?? .auto
        AppSettings.Player.defaultSpeed = playerDefaultSpeed
        AppSettings.Player.decodePreference = DecodePreference(rawValue: decodePreference) ?? .auto
        AppSettings.Player.preloadSeconds = preloadSeconds
        AppSettings.Player.audioOnlyByDefault = audioOnlyByDefault
        AppSettings.Player.volumeStep = volumeStep
        AppSettings.Browser.searchEngine = SearchEngine(rawValue: searchEngine) ?? .bing
        AppSettings.Browser.customSearchTemplate = customSearchTemplate
        AppSettings.Browser.userAgent = BrowserUserAgent(rawValue: browserUserAgent) ?? .platform
        AppSettings.Cache.totalLimitMB = cacheLimitMB
        AppSettings.Cache.contentCachingEnabled = contentCachingEnabled
        AppSettings.Trash.retentionDays = trashRetentionDays
    }
}

struct ImportSummary {
    var insertedConnections: Int
    var updatedConnections: Int
}

enum ConfigTransferError: Error, LocalizedError {
    case databaseNotReady

    var errorDescription: String? { "数据库尚未就绪" }
}

/// 配置导入 / 导出（不含明文密码）
final class ConfigTransfer {
    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    /// 导出为 JSON 文件（临时目录），供分享面板使用
    func export() throws -> URL {
        guard let db = database.dbQueue else { throw ConfigTransferError.databaseNotReady }
        let connections = try db.read { try Connection.fetchAll($0) }
        let bundle = ConfigBundle(
            exportedAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            connections: connections,
            preferences: .capture()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(bundle)
        let stamp = Self.fileDateFormatter.string(from: Date())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyHub-Config-\(stamp).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 导入：连接源按挂载点 upsert（id 重新分配，密码需重新录入），偏好直接应用
    @discardableResult
    func `import`(from url: URL) throws -> ImportSummary {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(ConfigBundle.self, from: data)
        guard let db = database.dbQueue else { throw ConfigTransferError.databaseNotReady }

        var inserted = 0
        var updated = 0
        try db.write { db in
            for var conn in bundle.connections {
                if var existing = try Connection
                    .filter(Column("mountPoint") == conn.mountPoint)
                    .fetchOne(db) {
                    existing.name = conn.name
                    existing.type = conn.type
                    existing.configJSON = conn.configJSON
                    existing.enabled = conn.enabled
                    try existing.update(db)
                    updated += 1
                } else {
                    conn.id = nil
                    try conn.insert(db)
                    inserted += 1
                }
            }
        }
        bundle.preferences.apply()
        return ImportSummary(insertedConnections: inserted, updatedConnections: updated)
    }

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter
    }()
}
