import Foundation

/// 适配器工厂：按 `Connection.type` 实例化（凭据自动从 Keychain 读取）
enum AdapterFactory {
    private static let credentials = CredentialStore()

    /// 适配器用途（TODO 404）：决定 WebDAV 走哪个 URLSession 连接池。
    /// 封面加载与「列目录 / 播放」隔离，避免失控的封面抽帧占满连接导致点击音视频无法播放。
    enum Purpose {
        /// 列目录 / 播放 / 文件操作（共享 `WebDAVAdapter.streamSession`，16 连接）
        case general
        /// 封面加载（独立 `WebDAVAdapter.coverSession`，4 连接 + 短超时）
        case cover

        var webdavSession: URLSession {
            switch self {
            case .general: return WebDAVAdapter.streamSession
            case .cover: return WebDAVAdapter.coverSession
            }
        }
    }

    /// - Parameters:
    ///   - connection: 连接源记录
    ///   - passwordOverride: 表单「连接测试」时传入未保存的密码；nil 则读 Keychain
    ///   - purpose: 用途（决定 WebDAV 连接池隔离，见 `Purpose`）
    static func makeAdapter(
        for connection: Connection,
        passwordOverride: String? = nil,
        purpose: Purpose = .general
    ) throws -> StorageAdapter {
        let password = passwordOverride ?? connection.id.flatMap { try? credentials.loadPassword(for: $0) }

        switch connection.type {
        case .local:
            let config = connection.decodeConfig(LocalConfig.self) ?? LocalConfig()
            if let bookmark = config.bookmarkData, let adapter = LocalAdapter(bookmarkData: bookmark) {
                return adapter
            }
            if let path = config.path, !path.isEmpty {
                return LocalAdapter(root: URL(fileURLWithPath: path))
            }
            return LocalAdapter()

        case .webdav:
            guard let config = connection.decodeConfig(WebDAVConfig.self) else {
                throw StorageError.invalidConfig("WebDAV 配置缺失")
            }
            // 内外网双地址：配置了合法内网地址时启用路由适配器（内网优先、失败回退外网），
            // 否则退化为单地址适配器。
            // 内网探测用 5s 短超时：外网环境下快速失败回退，而不是每个目录页都干等 30s
            //（配合 RoutedWebDAVAdapter 的进程级冷却，见 TODO 324）。
            let internalURL = config.internalBaseURL?.trimmingCharacters(in: .whitespaces) ?? ""
            if !internalURL.isEmpty {
                var internalConfig = config
                internalConfig.baseURL = internalURL
                if let internalAdapter = try? WebDAVAdapter(
                    config: internalConfig,
                    password: password,
                    session: purpose.webdavSession,
                    timeoutInterval: 5
                ) {
                    let externalAdapter = try WebDAVAdapter(
                        config: config, password: password, session: purpose.webdavSession
                    )
                    return RoutedWebDAVAdapter(internalAdapter: internalAdapter, externalAdapter: externalAdapter)
                }
            }
            return try WebDAVAdapter(config: config, password: password, session: purpose.webdavSession)

        case .smb:
            guard let config = connection.decodeConfig(SMBConfig.self) else {
                throw StorageError.invalidConfig("SMB 配置缺失")
            }
            return try SMBAdapter(config: config, password: password)

        // 预留：FTP / SFTP / NFS —— 实现 StorageAdapter 协议即可接入，核心层无需改动
        case .ftp, .sftp, .nfs:
            throw StorageError.unsupportedProtocol(connection.type.rawValue.uppercased())
        }
    }
}
