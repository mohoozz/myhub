import Foundation

/// 每个目录的文件显示顺序偏好（TODO 370）：
/// 浏览界面按「连接 + 目录路径」单独缓存排序字段（名称/大小/修改时间）与升降序，
/// 切换目录时各自恢复自己的顺序；某目录首次进入（无记录）时回落全局默认
/// `AppSettings.Browse.sortKey` / `sortAscending`（由最近一次修改更新，新目录沿用最近使用的顺序）。
///
/// 存储：UserDefaults 单键 JSON 字典（键 = `connectionID|标准化路径`）。
/// 长期使用会产生大量目录记录，超过 `maxEntries` 时按最久未更新淘汰，避免无限膨胀。
enum BrowseSortPreferences {

    /// 单目录排序偏好
    struct Preference: Codable, Equatable {
        var sortKey: BrowseSortKey
        var ascending: Bool
        /// 最近更新时间（容量淘汰依据）
        var updatedAt: Date
    }

    /// 最多缓存的目录数
    private static let maxEntries = 500
    private static let storageKey = "browse.sortPreferences.v1"
    private static let lock = NSLock()

    // MARK: - 读写

    /// 读取某目录的排序偏好；无记录返回 nil（调用方回落全局默认）
    static func preference(connectionID: Int64, path: String) -> Preference? {
        synchronized { load()[key(connectionID: connectionID, path: path)] }
    }

    /// 写入某目录的排序偏好（超容量按最久未更新淘汰）
    static func save(_ preference: Preference, connectionID: Int64, path: String) {
        synchronized {
            var dict = load()
            dict[key(connectionID: connectionID, path: path)] = preference
            if dict.count > maxEntries {
                let overflow = dict.count - maxEntries
                let stale = dict.sorted { $0.value.updatedAt < $1.value.updatedAt }
                    .prefix(overflow)
                    .map { $0.key }
                for key in stale { dict.removeValue(forKey: key) }
            }
            persist(dict)
        }
    }

    // MARK: - 内部

    /// 存储键：连接 ID 数字前缀 + 「|」分隔（首个分隔符前必为纯数字 ID，无歧义）
    private static func key(connectionID: Int64, path: String) -> String {
        "\(connectionID)|\(StoragePath.normalize(path))"
    }

    private static func load() -> [String: Preference] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Preference].self, from: data)) ?? [:]
    }

    private static func persist(_ dict: [String: Preference]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// 字典读-改-写非原子；读取可能来自后台（「下一部/下一本」查找），写入来自主线程，加锁兜底
    private static func synchronized<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
