import Foundation
import GRDB

/// 全局收藏 Store（IOS-107）：收藏记录唯一数据源。
/// 浏览页星标与收藏页经它读写并广播变更（`favoritesDidChange`），实现双向同步。
/// 单例 + environmentObject 注入同一实例。
@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()
    static let didChangeNotification = Notification.Name("FavoritesDidChange")

    @Published private(set) var favorites: [Favorite] = []

    private init() {}

    func reload() {
        guard let db = AppDatabase.shared.dbQueue else { return }
        favorites = (try? db.read {
            try Favorite.order(Column("createdAt").desc).fetchAll($0)
        }) ?? []
    }

    // MARK: - 查询

    func isFavorited(connectionID: Int64, path: String) -> Bool {
        favorites.contains { $0.connectionID == connectionID && $0.filePath == path }
    }

    /// 某连接源的已收藏路径集合（浏览页星标）
    func paths(for connectionID: Int64) -> Set<String> {
        Set(favorites.filter { $0.connectionID == connectionID }.map(\.filePath))
    }

    // MARK: - 变更

    /// 切换收藏；返回当前是否已收藏
    @discardableResult
    func toggle(connectionID: Int64, entry: FileEntry) -> Bool {
        if isFavorited(connectionID: connectionID, path: entry.path) {
            remove(connectionID: connectionID, path: entry.path)
            return false
        }
        add(connectionID: connectionID, entries: [entry])
        return true
    }

    /// 批量收藏；返回新增数量
    @discardableResult
    func add(connectionID: Int64, entries: [FileEntry]) -> Int {
        guard let db = AppDatabase.shared.dbQueue else { return 0 }
        var added = 0
        for entry in entries where !isFavorited(connectionID: connectionID, path: entry.path) {
            var favorite = Favorite(
                id: nil, connectionID: connectionID, filePath: entry.path,
                mediaType: entry.isDir ? .other : MediaType.detect(ext: entry.ext),
                size: entry.size, createdAt: Date()
            )
            if (try? db.write({ try favorite.insert($0) })) != nil {
                added += 1
            }
        }
        if added > 0 { reloadAndNotify() }
        return added
    }

    func remove(_ favorite: Favorite) {
        guard let db = AppDatabase.shared.dbQueue, let id = favorite.id else { return }
        _ = try? db.write { db in
            try db.execute(
                sql: "DELETE FROM favorite WHERE id = ?",
                arguments: [id]
            )
        }
        reloadAndNotify()
    }

    func remove(connectionID: Int64, path: String) {
        guard let db = AppDatabase.shared.dbQueue else { return }
        _ = try? db.write { db in
            try db.execute(
                sql: "DELETE FROM favorite WHERE connectionID = ? AND filePath = ?",
                arguments: [connectionID, path]
            )
        }
        reloadAndNotify()
    }

    private func reloadAndNotify() {
        reload()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
