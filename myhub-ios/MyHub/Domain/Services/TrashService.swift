import Foundation

/// 回收站条目（挂载点下 `.trash` 目录 + `.meta.json` 原路径元数据）
struct TrashItem: Identifiable {
    var trashPath: String        // .trash 内当前路径
    var name: String             // 原始文件名
    var originalPath: String?    // 原路径（无元数据时为 nil，不可还原）
    var isDir: Bool
    var size: Int64
    var deletedAt: Date?

    var id: String { trashPath }
}

/// 回收站服务（IOS-106）：
/// 回收站为挂载点下 `.trash` 目录；删除时由浏览页写入 `<name>.meta.json`（原路径/删除时间），
/// 本服务负责列表、还原（冲突自动重名）、彻底删除、清空与过期自动清理（默认 30 天）。
final class TrashService {
    static let trashRoot = "/.trash"

    private let connection: Connection
    private let adapter: StorageAdapter

    init?(connection: Connection) {
        guard let adapter = try? AdapterFactory.makeAdapter(for: connection) else { return nil }
        self.connection = connection
        self.adapter = adapter
    }

    // MARK: - 列表（meta 配对，删除时间倒序）

    func listItems() async throws -> [TrashItem] {
        let entries: [FileEntry]
        do {
            entries = try await adapter.list(Self.trashRoot)
        } catch {
            return []   // 无 .trash 目录 = 回收站为空
        }
        let metas = entries.filter { $0.name.hasSuffix(".meta.json") }
        var metaMap: [String: TrashMeta] = [:]
        for meta in metas {
            let key = String(meta.name.dropLast(".meta.json".count))
            if let data = try? await adapter.readAll(meta.path, limit: 16 * 1024),
               let parsed = try? JSONDecoder.trash.decode(TrashMeta.self, from: data) {
                metaMap[key] = parsed
            }
        }
        return entries
            .filter { !$0.name.hasSuffix(".meta.json") }
            .map { entry in
                let meta = metaMap[entry.name]
                return TrashItem(
                    trashPath: entry.path,
                    name: meta?.name ?? Self.stripStamp(from: entry.name),
                    originalPath: meta?.originalPath,
                    isDir: entry.isDir,
                    size: entry.size,
                    deletedAt: meta?.deletedAt
                )
            }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    // MARK: - 还原（原路径冲突时自动追加序号）

    func restore(_ item: TrashItem) async throws {
        guard let originalPath = item.originalPath else {
            throw StorageError.invalidPath("缺少原路径信息，无法还原")
        }
        let parent = StoragePath.parent(of: originalPath)
        var candidate = originalPath
        var counter = 1
        while (try? await adapter.stat(candidate)) != nil {
            let stem = (item.name as NSString).deletingPathExtension
            let ext = (item.name as NSString).pathExtension
            let suffix = ext.isEmpty ? " (\(counter))" : " (\(counter)).\(ext)"
            candidate = StoragePath.joining(parent, stem + suffix)
            counter += 1
        }
        try await adapter.move(item.trashPath, candidate)
        try? await adapter.delete(item.trashPath + ".meta.json")
    }

    // MARK: - 彻底删除 / 清空 / 过期清理

    func deletePermanently(_ item: TrashItem) async throws {
        try await adapter.delete(item.trashPath)
        try? await adapter.delete(item.trashPath + ".meta.json")
    }

    func clear() async throws {
        for item in try await listItems() {
            try? await adapter.delete(item.trashPath)
            try? await adapter.delete(item.trashPath + ".meta.json")
        }
    }

    /// 过期自动清理（按元数据删除时间；无元数据的保守保留）
    @discardableResult
    func cleanupExpired(retentionDays: Int) async -> Int {
        guard retentionDays > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-TimeInterval(retentionDays) * 86400)
        var removed = 0
        for item in (try? await listItems()) ?? [] {
            guard let deletedAt = item.deletedAt, deletedAt < cutoff else { continue }
            try? await adapter.delete(item.trashPath)
            try? await adapter.delete(item.trashPath + ".meta.json")
            removed += 1
        }
        return removed
    }

    // MARK: - 内部

    /// 与浏览页删除时写入的 TrashMeta 对应
    private struct TrashMeta: Codable {
        var originalPath: String
        var name: String
        var isDir: Bool
        var deletedAt: Date
    }

    /// 无元数据时从 "yyyyMMdd-HHmmss-原名" 还原显示名
    private static func stripStamp(from trashName: String) -> String {
        guard trashName.count > 16, trashName.dropFirst(15).hasPrefix("-") else { return trashName }
        return String(trashName.dropFirst(16))
    }
}

private extension JSONDecoder {
    static let trash: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
