import Foundation
import GRDB

/// 播放数据源解析（《需求分析文档》§4.3 数据源层）：
/// 连接源条目 → PlaybackRequest——本地直连 file://；WebDAV / SMB 注册本地串流代理（边下边播）。
/// 同时查询历史播放进度生成 startAt，供引擎首帧就绪后一次性精准 seek（精准续播，无「先 0 后跳」）。
enum PlaybackSourceResolver {
    static func makeRequest(connection: Connection, entry: FileEntry) async throws -> PlaybackRequest {
        let mediaType = MediaType.detect(ext: entry.ext)
        let item = PlayableItem(
            title: entry.name,
            path: entry.path,
            isAudioOnly: mediaType == .audio,
            connectionID: connection.id
        )
        let startAt = resumePosition(connectionID: connection.id, path: entry.path, mediaType: mediaType)

        switch connection.type {
        case .local:
            guard let adapter = try AdapterFactory.makeAdapter(for: connection) as? LocalAdapter,
                  let url = adapter.localFileURL(for: entry.path) else {
                throw StorageError.invalidPath(entry.path)
            }
            return PlaybackRequest(item: item, url: url, mediaType: mediaType, startAt: startAt)

        case .webdav, .smb:
            let adapter = try AdapterFactory.makeAdapter(for: connection)
            var identity = SegmentCache.FileIdentity(
                connectionID: connection.id ?? 0,
                path: entry.path,
                size: entry.size,
                modTime: entry.modTime.timeIntervalSince1970
            )
            // IOS-605 离线兜底：stat 失败构造的兜底条目（size <= 0）时，反查分片缓存身份，
            // 命中则以缓存身份起播——已缓存分片离线可播，未缓存区间快速报错不重试
            var offline = false
            if entry.size <= 0,
               let cached = await SegmentCache.shared.cachedIdentity(
                   connectionID: connection.id ?? 0, path: entry.path
               ) {
                identity = cached
                offline = true
            }
            let source = AdapterRangeDataSource(
                adapter: adapter, path: entry.path,
                contentLength: identity.size,
                maxAttempts: offline ? 1 : 3
            )
            let reader = CachedRangeReader(
                source: source,
                identity: identity,
                cachingEnabled: AppSettings.Cache.contentCachingEnabled,
                offlineMode: offline
            )
            let url = try LocalStreamProxy.shared.register(reader: reader, fileName: entry.name)
            return PlaybackRequest(item: item, url: url, mediaType: mediaType, startAt: startAt)

        // 预留：FTP / SFTP / NFS
        case .ftp, .sftp, .nfs:
            throw StorageError.unsupportedProtocol(connection.type.rawValue.uppercased())
        }
    }

    /// 历史播放进度（秒）：仅音视频、未读完、进度 > 1s 才恢复
    private static func resumePosition(connectionID: Int64?, path: String, mediaType: MediaType) -> TimeInterval? {
        guard mediaType == .video || mediaType == .audio,
              let connectionID,
              let db = AppDatabase.shared.dbQueue else { return nil }
        let record = try? db.read { database in
            try ReadingProgress
                .filter(Column("connectionID") == connectionID && Column("filePath") == path)
                .fetchOne(database)
        }
        guard let record, !record.finished,
              let seconds = Double(record.progressJSON.trimmingCharacters(in: .whitespaces)),
              seconds > 1 else { return nil }
        return seconds
    }
}
