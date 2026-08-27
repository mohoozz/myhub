import SwiftUI

/// 文本加载工具（txt 阅读 / txt 编辑共用）：流式读取 + 编码检测
enum TextFileLoader {
    /// 编辑上限 10MB
    static let editLimit: Int64 = 10 * 1024 * 1024
    /// 纯 txt 阅读器上限 4MB（超出截断提示；小说阅读器走字节级索引无此限制）。
    /// 阅读器用单个 SwiftUI Text 渲染全文，上限过大（如 50MB）会触发整段排版/文本选择索引，CPU/内存暴涨导致真机发热。
    static let readerLimit: Int64 = 4 * 1024 * 1024

    struct Loaded {
        var text: String
        var encoding: String.Encoding
        var encodingName: String
        var truncated: Bool
    }

    static func load(adapter: StorageAdapter, path: String, limit: Int64) async throws -> Loaded {
        // 只读取前 limit+1 字节即可判断是否截断；避免 range=nil 对 SMB 走「读到 EOF」整文件拉取导致大文件卡死
        let stream = try await adapter.readStream(path, range: 0..<(limit + 1))
        var data = Data()
        var truncated = false
        for try await chunk in stream {
            data.append(chunk)
        }
        if Int64(data.count) > limit {
            data = data.prefix(Int(limit))
            truncated = true
        }
        let result = TextEncodingDetector.decode(data)
        return Loaded(
            text: result.text,
            encoding: result.encoding,
            encodingName: result.encodingName,
            truncated: truncated
        )
    }
}
