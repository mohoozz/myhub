import Foundation

/// 存储条目（《需求分析文档》§4.4）；Codable 供目录结果本地缓存（DirectoryCache）
struct FileEntry: Codable, Sendable {
    let name: String
    let path: String          // 连接内虚拟绝对路径（以 "/" 开头）
    let isDir: Bool
    let size: Int64
    let modTime: Date
    let ext: String
}

/// 存储层错误
enum StorageError: Error, LocalizedError {
    case invalidPath(String)
    case invalidConfig(String)
    case notFound(String)
    case http(status: Int, message: String?)
    case authenticationFailed
    case unsupportedProtocol(String)
    /// 离线模式：请求的内容未缓存（已缓存内容无网络播放/阅读，IOS-605）
    case offline(String)
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let path): return "无效路径：\(path)"
        case .invalidConfig(let message): return "连接配置无效：\(message)"
        case .notFound(let path): return "路径不存在：\(path)"
        case .http(let status, let message):
            return "HTTP \(status)\(message.map { "（\($0)）" } ?? "")"
        case .authenticationFailed: return "认证失败，请检查用户名与密码"
        case .unsupportedProtocol(let name): return "暂不支持 \(name) 协议（预留扩展）"
        case .offline(let name): return "离线模式：\(name)未缓存，无法加载"
        case .underlying(let error): return error.localizedDescription
        }
    }
}

/// 虚拟路径工具：统一以 "/" 开头、无尾部 "/"（根为 "/"），并折叠 "." / ".."
enum StoragePath {
    static func normalize(_ path: String) -> String {
        var components: [String] = []
        for part in path.split(separator: "/") {
            let component = String(part)
            switch component {
            case "", ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    static func joining(_ base: String, _ name: String) -> String {
        let base = normalize(base)
        return (base == "/" ? "/" : base + "/") + name
    }

    static func fileName(of path: String) -> String {
        normalize(path).split(separator: "/").last.map(String.init) ?? "/"
    }

    static func parent(of path: String) -> String {
        let normalized = normalize(path)
        guard let index = normalized.lastIndex(of: "/"), index != normalized.startIndex else { return "/" }
        return String(normalized[..<index])
    }

    static func ext(of path: String) -> String {
        let name = fileName(of: path)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }
}

/// 存储适配器协议（IOS-101）。
/// 实现：LocalAdapter / WebDAVAdapter / SMBAdapter（可扩展 FTP/SFTP/NFS）。
protocol StorageAdapter {
    func list(_ dir: String) async throws -> [FileEntry]
    func stat(_ path: String) async throws -> FileEntry
    /// 支持 Range 的流式读取，供播放器/阅读器按需拉取
    func readStream(_ path: String, range: Range<Int64>?) async throws -> AsyncThrowingStream<Data, Error>
    func writeStream(_ path: String, data: AsyncThrowingStream<Data, Error>) async throws
    func move(_ src: String, _ dest: String) async throws
    func copy(_ src: String, _ dest: String) async throws
    func delete(_ path: String) async throws
    func mkdir(_ path: String) async throws
    /// 连接测试：成功正常返回，失败抛错（列表绿/红点、表单内外网提示）
    func testConnection() async throws
}
