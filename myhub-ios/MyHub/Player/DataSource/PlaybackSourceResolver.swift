import Foundation
import GRDB

/// 回环串流会话的用途（TODO 404）：播放与封面抽帧共用同一套边下边播通道，
/// 但资源策略必须分开——封面只读首帧、流量有硬上限、连接池独立，
/// 否则失控的封面抽帧会把连接与带宽吃光，导致点击音视频无法播放。
enum StreamPurpose {
    case playback
    case cover

    var adapterPurpose: AdapterFactory.Purpose {
        switch self {
        case .playback: return .general
        case .cover: return .cover
        }
    }

    /// 预读：播放开（窗口 15MB 平滑播放）；封面关（只读首帧，避免每次 read 向后预取）
    var prefetchEnabled: Bool { self == .playback }

    /// 网络拉取字节上限：播放不限；封面 24MB——首帧/moov/artwork 实际只需数百 KB~数 MB，
    /// 超过即判定为「整文件拉取」失控并取消会话
    var networkByteBudget: Int64? {
        switch self {
        case .playback: return nil
        case .cover: return 24 * 1024 * 1024
        }
    }
}

/// 播放数据源解析（《需求分析文档》§4.3 数据源层）：
/// 连接源条目 → PlaybackRequest——本地直连 file://；WebDAV / SMB 注册本地串流代理（边下边播）。
/// 同时查询历史播放进度生成 startAt，供引擎首帧就绪后一次性精准 seek（精准续播，无「先 0 后跳」）。
enum PlaybackSourceResolver {
    static func makeRequest(connection: Connection, entry: FileEntry) async throws -> PlaybackRequest {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let mediaType = MediaType.detect(ext: entry.ext)
        let item = PlayableItem(
            title: entry.name,
            path: entry.path,
            isAudioOnly: mediaType == .audio,
            connectionID: connection.id
        )
        let startAt = resumePosition(connectionID: connection.id, path: entry.path, mediaType: mediaType)

        let url: URL
        do {
            if let remote = try await makeRemoteStreamURL(connection: connection, entry: entry) {
                url = remote
            } else if let adapter = try AdapterFactory.makeAdapter(for: connection) as? LocalAdapter,
                      let fileURL = adapter.localFileURL(for: entry.path) {
                url = fileURL
            } else {
                throw StorageError.invalidPath(entry.path)
            }
        } catch {
            // 解析失败面包屑（TODO 380）：区分「点播后就卡在数据源解析」还是进入了引擎加载
            AppLogger.shared.log(
                "数据源解析失败 file=\(entry.name) type=\(connection.type.rawValue) error=\(error.localizedDescription) 网络=\(NetworkPathMonitor.shared.snapshot())",
                level: .error, module: "player-audio"
            )
            throw error
        }
        AppLogger.shared.log(
            "数据源解析完成 file=\(entry.name) type=\(connection.type.rawValue) url=\(url.absoluteString) startAt=\(startAt.map { String(Int($0)) } ?? "nil") 耗时=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))ms",
            level: .info, module: "player-audio"
        )
        return PlaybackRequest(item: item, url: url, mediaType: mediaType, startAt: startAt)
    }

    /// 远程源（WebDAV/SMB）注册边下边播回环串流 URL，供播放器与封面抽帧按需 Range 读取；
    /// 本地源返回 nil（封面走 withLocalAccess 直读 file://）。FTP/SFTP/NFS 暂不支持，抛错。
    /// - Parameter purpose: `.playback` 边下边播（预读 + 不限流量 + 共享连接池）；
    ///   `.cover` 封面抽帧（关预读、独立连接池、网络拉取字节上限，避免单个封面占满连接，TODO 404）
    static func makeRemoteStreamURL(
        connection: Connection, entry: FileEntry, purpose: StreamPurpose = .playback
    ) async throws -> URL? {
        switch connection.type {
        case .local:
            return nil
        case .webdav, .smb:
            let adapter = try AdapterFactory.makeAdapter(for: connection, purpose: purpose.adapterPurpose)
            var identity = SegmentCache.FileIdentity(
                connectionID: connection.id ?? 0,
                path: entry.path,
                size: entry.size,
                modTime: entry.modTime.timeIntervalSince1970
            )
            // IOS-605 离线兜底：stat 失败构造的兜底条目（size <= 0）时，反查分片缓存身份，
            // 命中则以缓存身份起播——已缓存分片离线可播，未缓存区间快速报错不重试
            var offline = false
            if entry.size <= 0 {
                if let cached = await SegmentCache.shared.cachedIdentity(
                    connectionID: connection.id ?? 0, path: entry.path
                ) {
                    identity = cached
                    offline = true
                    // 熄屏回来 stat 失败时命中缓存身份才可能继续播（TODO 380 诊断）
                    AppLogger.shared.log(
                        "离线兜底：命中分片缓存身份 file=\(entry.name) size=\(cached.size)（按缓存身份起播）",
                        level: .warn, module: "player-audio"
                    )
                } else {
                    AppLogger.shared.log(
                        "离线兜底：无分片缓存身份 file=\(entry.name)（stat 失败且无缓存，未缓存区间将快速失败）",
                        level: .warn, module: "player-audio"
                    )
                }
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
                offlineMode: offline,
                prefetchEnabled: purpose.prefetchEnabled,
                networkByteBudget: purpose.networkByteBudget
            )
            return try LocalStreamProxy.shared.register(reader: reader, fileName: entry.name)
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
