import SwiftUI

/// 缓存与存储（TODO §10 / IOS-504 + IOS-605）：
/// 分类占用查看 + 单项/全部清理 + 容量上限 + 内容缓存本地化开关 + 回收站保留天数
struct CacheSettingsView: View {
    @State private var sizes: [CacheManager.Partition: Int64] = [:]
    @State private var totalLimitMB = AppSettings.Cache.totalLimitMB
    @State private var contentCachingEnabled = AppSettings.Cache.contentCachingEnabled
    @State private var trashRetentionDays = AppSettings.Trash.retentionDays
    @State private var clearing: CacheManager.Partition?
    @State private var confirmClearAll = false

    private static let limitOptions = [512, 1024, 2048, 4096, 8192]

    private var totalSize: Int64 { sizes.values.reduce(0, +) }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("总计")
                    Spacer()
                    Text(DisplayFormatters.size(totalSize))
                        .foregroundStyle(AppColors.textSecondary)
                }
                ForEach(CacheManager.Partition.allCases, id: \.self) { partition in
                    HStack {
                        Text(partition.displayName)
                        Spacer()
                        Text(DisplayFormatters.size(sizes[partition] ?? 0))
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { clearing = partition }
                }
                Button("清空全部缓存", role: .destructive) { confirmClearAll = true }
            } header: {
                Text("缓存占用")
            } footer: {
                Text("点击某类缓存可单独清理；缓存均可重建，清理不影响阅读进度与收藏。")
            }

            Section {
                Picker("容量上限", selection: $totalLimitMB) {
                    ForEach(Self.limitOptions, id: \.self) { mb in
                        Text(DisplayFormatters.size(Int64(mb) * 1024 * 1024)).tag(mb)
                    }
                }
                Toggle("内容缓存本地化", isOn: $contentCachingEnabled)
            } header: {
                Text("缓存策略")
            } footer: {
                Text("媒体分片超出容量上限时按 LRU 自动淘汰；开启本地化后，漫画/视频/音频/小说在使用时产生的缓存保存在本地，下次打开无需重新加载。")
            }

            Section {
                Stepper("保留 \(trashRetentionDays) 天", value: $trashRetentionDays, in: 1...90)
            } header: {
                Text("回收站")
            } footer: {
                Text("超过保留天数的回收站内容会在进入回收站页面时自动清理。")
            }
        }
        .navigationTitle("缓存与存储")
        .tint(AppColors.primary)
        .onAppear(perform: reload)
        .confirmationDialog(
            "清理缓存",
            isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } }),
            presenting: clearing
        ) { partition in
            Button("清理「\(partition.displayName)」", role: .destructive) {
                try? CacheManager.shared.clear(partition)
                AppLogger.shared.log("已清理缓存：\(partition.displayName)")
                clearing = nil
                reload()
            }
            Button("取消", role: .cancel) { clearing = nil }
        } message: { partition in
            Text("将清空\(partition.displayName)（当前 \(DisplayFormatters.size(sizes[partition] ?? 0))），缓存可重建。")
        }
        .confirmationDialog("清空全部缓存", isPresented: $confirmClearAll, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                try? CacheManager.shared.clearAll()
                AppLogger.shared.log("已清空全部缓存")
                reload()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清空全部分区缓存（当前共 \(DisplayFormatters.size(totalSize))），不影响阅读进度与收藏。")
        }
        .onChange(of: totalLimitMB) { AppSettings.Cache.totalLimitMB = $0 }
        .onChange(of: contentCachingEnabled) { AppSettings.Cache.contentCachingEnabled = $0 }
        .onChange(of: trashRetentionDays) { AppSettings.Trash.retentionDays = $0 }
    }

    private func reload() {
        var result: [CacheManager.Partition: Int64] = [:]
        for partition in CacheManager.Partition.allCases {
            result[partition] = CacheManager.shared.size(of: partition)
        }
        sizes = result
    }
}
