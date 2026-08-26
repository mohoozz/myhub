import SwiftUI

/// 文本加载工具（纯文本查看 / txt 编辑共用）：流式读取 + 编码检测
enum TextFileLoader {
    /// 查看上限 4MB（超出截断提示）
    static let viewLimit: Int64 = 4 * 1024 * 1024
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

/// 纯文本查看（IOS-706）：独立界面，与小说阅读器区分；
/// 编码自动检测（UTF-8 / GBK / Big5 / UTF-16 LE/BE），文本可选择复制。
struct TextFileViewer: View {
    let entry: FileEntry
    let adapter: StorageAdapter

    @Environment(\.dismiss) private var dismiss
    @State private var loaded: TextFileLoader.Loaded?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let loaded {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if loaded.truncated {
                                Label("文件过大，仅显示前 4MB", systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Text(loaded.text)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(AppColors.textPrimary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(16)
                    }
                } else if let error {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(AppColors.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                } else {
                    ProgressView("正在加载…")
                }
            }
            .background(AppColors.pageBackground)
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if let loaded {
                        Text(loaded.encodingName)
                            .font(.caption)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
            }
        }
        .task {
            do {
                loaded = try await TextFileLoader.load(
                    adapter: adapter, path: entry.path, limit: TextFileLoader.viewLimit
                )
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
