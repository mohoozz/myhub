import SwiftUI

/// 浏览页文件「属性」弹层（长按菜单 → 属性）
struct FileInfoView: View {
    let entry: FileEntry
    let connection: Connection?
    /// 展示用媒体类型（目录按「文件夹」显示，不参与判定）
    let mediaType: MediaType

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("基本信息") {
                    row("名称", displayName)
                    row("类型", entry.isDir ? "文件夹" : mediaType.label)
                    if let name = connection?.name, !name.isEmpty {
                        row("路径源", name)
                    }
                    row("路径", entry.path)
                }
                Section("文件") {
                    row("大小", entry.isDir ? "—" : DisplayFormatters.size(entry.size))
                    row("修改时间", modTimeText)
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
        }
        .presentationDetents([.medium, .large])
    }

    private var displayName: String {
        entry.name.isEmpty ? StoragePath.fileName(of: entry.path) : entry.name
    }

    private var modTimeText: String {
        let text = DisplayFormatters.modTime(entry.modTime)
        return text.isEmpty ? "—" : text
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
}
