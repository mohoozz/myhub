import Foundation
import AMSMB2

/// SMB2/3 适配器（AMSMB2 / libsmb2）：账号 / 访客 / 域，原生分块流式读取
final class SMBAdapter: StorageAdapter {
    private let config: SMBConfig
    private let client: SMB2Manager?

    init(config: SMBConfig, password: String?) throws {
        guard !config.host.isEmpty, !config.share.isEmpty else {
            throw StorageError.invalidConfig("SMB 需填写服务器与共享名")
        }
        guard let url = URL(string: "smb://\(config.host)") else {
            throw StorageError.invalidConfig("服务器地址无法解析：\(config.host)")
        }
        // 访客：不传凭据（libsmb2 默认 guest 匿名）；账号：user/password，域单独传递
        let credential: URLCredential? = {
            guard !config.guest, let username = config.username, !username.isEmpty else { return nil }
            return URLCredential(user: username, password: password ?? "", persistence: .forSession)
        }()
        guard let client = SMB2Manager(url: url, domain: config.domain ?? "", credential: credential) else {
            throw StorageError.invalidConfig("SMB 客户端初始化失败")
        }
        self.config = config
        self.client = client
    }

    deinit {
        client?.disconnectShare()
    }

    /// AMSMB2 内部对连接请求排队，重复调用幂等
    private func connected() async throws -> SMB2Manager {
        guard let client else { throw StorageError.invalidConfig("SMB 客户端未初始化") }
        try await client.connectShare(name: config.share)
        return client
    }

    // MARK: - StorageAdapter

    func list(_ dir: String) async throws -> [FileEntry] {
        let client = try await connected()
        let normalized = StoragePath.normalize(dir)
        let items = try await client.contentsOfDirectory(atPath: normalized)
        var result: [FileEntry] = []
        for item in items {
            guard let name = item[.nameKey] as? String, !name.hasPrefix(".") else { continue }
            let isDir = (item[.fileResourceTypeKey] as? URLFileResourceType) == .directory
            result.append(FileEntry(
                name: name,
                path: StoragePath.joining(normalized, name),
                isDir: isDir,
                size: (item[.fileSizeKey] as? Int64) ?? 0,
                modTime: item[.contentModificationDateKey] as? Date ?? .distantPast,
                ext: isDir ? "" : StoragePath.ext(of: name)
            ))
        }
        return result
    }

    func stat(_ path: String) async throws -> FileEntry {
        let client = try await connected()
        let normalized = StoragePath.normalize(path)
        do {
            let item = try await client.attributesOfItem(atPath: normalized)
            let isDir = (item[.fileResourceTypeKey] as? URLFileResourceType) == .directory
            return FileEntry(
                name: item[.nameKey] as? String ?? StoragePath.fileName(of: normalized),
                path: normalized,
                isDir: isDir,
                size: (item[.fileSizeKey] as? Int64) ?? 0,
                modTime: item[.contentModificationDateKey] as? Date ?? .distantPast,
                ext: isDir ? "" : StoragePath.ext(of: normalized)
            )
        } catch {
            throw StorageError.notFound(path)
        }
    }

    /// AMSMB2 原生分块 AsyncThrowingStream（optimizedReadSize 块，支持 Range / 拖动定位）
    func readStream(_ path: String, range: Range<Int64>?) async throws -> AsyncThrowingStream<Data, Error> {
        let client = try await connected()
        let normalized = StoragePath.normalize(path)
        if let range {
            return client.contents(atPath: normalized, range: range)
        }
        return client.contents(atPath: normalized, range: Range<UInt64>?.none)
    }

    func writeStream(_ path: String, data: AsyncThrowingStream<Data, Error>) async throws {
        let client = try await connected()
        try await client.write(stream: data, toPath: StoragePath.normalize(path), progress: nil)
    }

    func move(_ src: String, _ dest: String) async throws {
        let client = try await connected()
        try await client.moveItem(atPath: StoragePath.normalize(src), toPath: StoragePath.normalize(dest))
    }

    func copy(_ src: String, _ dest: String) async throws {
        let client = try await connected()
        try await client.copyItem(
            atPath: StoragePath.normalize(src),
            toPath: StoragePath.normalize(dest),
            recursive: true,
            progress: nil
        )
    }

    func delete(_ path: String) async throws {
        let client = try await connected()
        try await client.removeItem(atPath: StoragePath.normalize(path))
    }

    func mkdir(_ path: String) async throws {
        let client = try await connected()
        try await client.createDirectory(atPath: StoragePath.normalize(path))
    }

    func testConnection() async throws {
        let client = try await connected()
        try await client.echo()
    }
}
