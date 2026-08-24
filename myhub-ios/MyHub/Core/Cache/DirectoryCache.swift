import Foundation
import CryptoKit

/// 目录结果本地缓存（IOS-102）：网络源目录列表落沙盒 Caches，二次进入先展示缓存再后台刷新。
/// 缓存为可重建派生数据，丢失自动重拉；键含 connectionID + 路径，内容含条目与拉取时间。
final class DirectoryCache {
    static let shared = DirectoryCache()

    struct Snapshot: Codable {
        var entries: [FileEntry]
        var fetchedAt: Date
    }

    private let cache = CacheManager.shared

    private init() {}

    private func fileURL(connectionID: Int64, path: String) -> URL {
        let digest = SHA256.hash(data: Data("\(connectionID)|\(StoragePath.normalize(path))".utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return cache.url(for: .directoryListings).appendingPathComponent("\(name).json")
    }

    /// 读取缓存快照（不存在/损坏返回 nil）
    func load(connectionID: Int64, path: String) -> Snapshot? {
        let url = fileURL(connectionID: connectionID, path: path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        CacheManager.shared.touch(url)   // 刷新访问时间（LRU）
        return try? JSONDecoder.directoryCache.decode(Snapshot.self, from: data)
    }

    /// 写入缓存（异步落盘，不阻塞调用方）
    func save(connectionID: Int64, path: String, entries: [FileEntry]) {
        let url = fileURL(connectionID: connectionID, path: path)
        let snapshot = Snapshot(entries: entries, fetchedAt: Date())
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder.directoryCache.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
            CacheManager.shared.evictPartitionIfNeeded(.directoryListings)   // 目录缓存 LRU（IOS-605）
        }
    }

    /// 使某目录缓存失效（文件增删改后调用）
    func invalidate(connectionID: Int64, path: String) {
        try? FileManager.default.removeItem(at: fileURL(connectionID: connectionID, path: path))
    }
}

private extension JSONEncoder {
    static let directoryCache: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()
}

private extension JSONDecoder {
    static let directoryCache: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
