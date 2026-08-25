import Foundation
import GRDB

/// 浏览器数据 Store（TODO §8.3，IOS-402/403）：
/// 书签 / 浏览历史 / 起始页快捷入口 的唯一数据源（单例 + environmentObject 注入）。
/// 无痕浏览不记录历史（由调用方依据 `BrowserSessionStore.isIncognito` 决定是否调用）。
@MainActor
final class BrowserDataStore: ObservableObject {
    static let shared = BrowserDataStore()

    @Published private(set) var bookmarks: [Bookmark] = []
    @Published private(set) var history: [BrowserHistory] = []
    @Published private(set) var shortcuts: [BrowserShortcut] = []

    private static let seededKey = "browser.shortcuts.seeded"

    private init() {
        reloadAll()
        seedShortcutsIfNeeded()
    }

    // MARK: - 加载

    func reloadAll() {
        reloadBookmarks()
        reloadHistory()
        reloadShortcuts()
    }

    func reloadBookmarks() {
        guard let db = AppDatabase.shared.dbQueue else { return }
        bookmarks = (try? db.read { try Bookmark.order(Column("createdAt").desc).fetchAll($0) }) ?? []
    }

    func reloadHistory() {
        guard let db = AppDatabase.shared.dbQueue else { return }
        history = (try? db.read { try BrowserHistory.order(Column("visitedAt").desc).fetchAll($0) }) ?? []
    }

    func reloadShortcuts() {
        guard let db = AppDatabase.shared.dbQueue else { return }
        shortcuts = (try? db.read { try BrowserShortcut.order(Column("sortOrder").asc).fetchAll($0) }) ?? []
    }

    // MARK: - 书签

    func isBookmarked(_ url: String) -> Bool {
        bookmarks.contains { $0.url == url }
    }

    /// 切换书签（星标）；已收藏则移除
    func toggleBookmark(title: String, url: String, favicon: String?) {
        if let existing = bookmarks.first(where: { $0.url == url }) {
            removeBookmark(existing)
        } else {
            addBookmark(title: title, url: url, favicon: favicon)
        }
    }

    func addBookmark(title: String, url: String, favicon: String?) {
        guard let db = AppDatabase.shared.dbQueue else { return }
        var record = Bookmark(id: nil, title: title, url: url, favicon: favicon, createdAt: Date())
        _ = try? db.write { try record.insert($0) }
        reloadBookmarks()
    }

    func removeBookmark(_ bookmark: Bookmark) {
        guard let db = AppDatabase.shared.dbQueue, let id = bookmark.id else { return }
        _ = try? db.write { try db.execute(sql: "DELETE FROM bookmark WHERE id = ?", arguments: [id]) }
        reloadBookmarks()
    }

    func updateBookmark(_ bookmark: Bookmark) {
        guard let db = AppDatabase.shared.dbQueue, bookmark.id != nil else { return }
        var updated = bookmark
        _ = try? db.write { try updated.update($0) }
        reloadBookmarks()
    }

    // MARK: - 历史

    /// 记录一次访问；同一 URL 连续访问仅更新时间戳，避免重复条目
    func recordVisit(title: String, url: String, favicon: String?) {
        guard let db = AppDatabase.shared.dbQueue else { return }
        _ = try? db.write { db in
            if let latest = try BrowserHistory.order(Column("visitedAt").desc).fetchOne(db),
               latest.url == url,
               let latestID = latest.id {
                try db.execute(
                    sql: "UPDATE browserHistory SET visitedAt = ?, title = ? WHERE id = ?",
                    arguments: [Date(), title, latestID]
                )
            } else {
                var record = BrowserHistory(id: nil, title: title, url: url, favicon: favicon, visitedAt: Date())
                try record.insert(db)
            }
        }
        reloadHistory()
    }

    func removeHistory(_ record: BrowserHistory) {
        guard let db = AppDatabase.shared.dbQueue, let id = record.id else { return }
        _ = try? db.write { try db.execute(sql: "DELETE FROM browserHistory WHERE id = ?", arguments: [id]) }
        reloadHistory()
    }

    func clearHistory() {
        guard let db = AppDatabase.shared.dbQueue else { return }
        _ = try? db.write { try BrowserHistory.deleteAll($0) }
        reloadHistory()
    }

    // MARK: - 起始页快捷入口

    func addShortcut(title: String, url: String) {
        guard let db = AppDatabase.shared.dbQueue else { return }
        let nextOrder = (shortcuts.map(\.sortOrder).max() ?? -1) + 1
        var record = BrowserShortcut(id: nil, title: title, url: url, sortOrder: nextOrder)
        _ = try? db.write { try record.insert($0) }
        reloadShortcuts()
    }

    func removeShortcut(_ shortcut: BrowserShortcut) {
        guard let db = AppDatabase.shared.dbQueue, let id = shortcut.id else { return }
        _ = try? db.write { try db.execute(sql: "DELETE FROM browserShortcut WHERE id = ?", arguments: [id]) }
        reloadShortcuts()
    }

    func updateShortcut(_ shortcut: BrowserShortcut) {
        guard let db = AppDatabase.shared.dbQueue, shortcut.id != nil else { return }
        var updated = shortcut
        _ = try? db.write { try updated.update($0) }
        reloadShortcuts()
    }

    /// 拖拽排序：按新顺序重写 sortOrder
    func moveShortcuts(from source: IndexSet, to destination: Int) {
        var reordered = shortcuts
        reordered.move(fromOffsets: source, toOffset: destination)
        guard let db = AppDatabase.shared.dbQueue else { return }
        _ = try? db.write { db in
            for (index, var item) in reordered.enumerated() {
                item.sortOrder = index
                try item.update(db)
            }
        }
        reloadShortcuts()
    }

    // MARK: - 首启预置

    private func seedShortcutsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.seededKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.seededKey)

        let presets: [(String, String)] = [
            ("Google", "https://www.google.com"),
            ("Bing", "https://www.bing.com"),
            ("哔哩哔哩", "https://www.bilibili.com"),
            ("GitHub", "https://github.com")
        ]
        guard let db = AppDatabase.shared.dbQueue else { return }
        _ = try? db.write { db in
            for (index, preset) in presets.enumerated() {
                var record = BrowserShortcut(id: nil, title: preset.0, url: preset.1, sortOrder: index)
                try record.insert(db)
            }
        }
        reloadShortcuts()
    }
}
