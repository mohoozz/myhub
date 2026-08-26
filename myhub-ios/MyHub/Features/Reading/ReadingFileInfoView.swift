import SwiftUI

/// 阅读记录「属性」弹层（长按菜单 → 属性，TODO §7）：
/// 展示标题、路径源、路径、类型，以及大小/修改时间（现场 stat，源不可用时降级提示）、
/// 阅读进度与最近阅读时间。
struct ReadingFileInfoView: View {
    let record: ReadingProgress
    let connection: Connection?
    let adapter: StorageAdapter?

    @Environment(\.dismiss) private var dismiss
    @State private var entry: FileEntry?   // 现场 stat 结果（nil = 加载中 / 源不可用）
    @State private var loadFailed = false

    var body: some View {
        NavigationStack {
            List {
                Section("基本信息") {
                    row("标题", title)
                    row("类型", record.mediaType.label)
                    if let name = connection?.name, !name.isEmpty {
                        row("路径源", name)
                    }
                    row("路径", record.filePath)
                }
                Section("文件") {
                    if let entry {
                        row("大小", DisplayFormatters.size(entry.size))
                        row("修改时间", DisplayFormatters.modTime(entry.modTime))
                    } else {
                        row("大小", loadFailed ? "源不可用，无法获取" : "加载中…")
                    }
                }
                Section("阅读进度") {
                    row("进度", record.finished ? finishedText : percentText)
                    row("最近阅读", DisplayFormatters.relative(record.updatedAt))
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("属性")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task(id: record.id) { await loadEntry() }
        }
        .presentationDetents([.medium, .large])
    }

    private var title: String {
        record.title.isEmpty ? StoragePath.fileName(of: record.filePath) : record.title
    }

    /// 已读完文案：视频「已看完」/ 音频「已听完」/ 漫画·小说「已读完」（默认「已读完」）
    private var finishedText: String {
        switch record.mediaType {
        case .video: return "已看完"
        case .audio: return "已听完"
        default: return "已读完"
        }
    }

    private var percentText: String {
        "\(Int((min(1, max(0, record.percent)) * 100).rounded()))%"
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .foregroundStyle(AppColors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func loadEntry() async {
        guard let adapter else {
            loadFailed = true
            return
        }
        do {
            entry = try await adapter.stat(record.filePath)
        } catch {
            loadFailed = true
        }
    }
}
