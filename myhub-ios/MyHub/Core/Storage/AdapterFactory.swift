import Foundation

/// 适配器工厂：按 `Connection.type` 实例化（凭据自动从 Keychain 读取）
enum AdapterFactory {
    private static let credentials = CredentialStore()

    /// - Parameters:
    ///   - connection: 连接源记录
    ///   - passwordOverride: 表单「连接测试」时传入未保存的密码；nil 则读 Keychain
    static func makeAdapter(
        for connection: Connection,
        passwordOverride: String? = nil
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
            return try WebDAVAdapter(config: config, password: password)

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
