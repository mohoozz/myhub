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
    /// 设备可用空间（提示上限是否超出）
    @State private var availableBytes: Int64 = 0

    /// 可选容量档位（MB）：512MB ~ 32GB
    private static let baseLimitOptions = [512, 1024, 2048, 4096, 8192, 12288, 16384, 24576, 32768]

    /// 已存配置可能不在档位内（旧版本 / 导入的配置），补进列表，避免选择器显示空白
    private var limitOptions: [Int] {
        Self.baseLimitOptions.contains(totalLimitMB)
            ? Self.baseLimitOptions
            : (Self.baseLimitOptions + [totalLimitMB]).sorted()
    }

    private var totalSize: Int64 { sizes.values.reduce(0, +) }

    /// 上限超出设备可用空间（仅在拿到可用空间后判断）
    private var exceedsAvailable: Bool {
        availableBytes > 0 && Int64(totalLimitMB) * 1024 * 1024 > availableBytes
    }

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
                        // 已用 / 分区配额（各分区之和 = 容量上限；超额只回收本分区）
                        Text(
                            "\(DisplayFormatters.size(sizes[partition] ?? 0))"
                            + " / \(DisplayFormatters.size(CacheManager.shared.limitBytes(for: partition)))"
                        )
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
                    ForEach(limitOptions, id: \.self) { mb in
                        Text(DisplayFormatters.size(Int64(mb) * 1024 * 1024)).tag(mb)
                    }
                }
                Toggle("内容缓存本地化", isOn: $contentCachingEnabled)
            } header: {
                Text("缓存策略")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("每个分类超出自己的配额时，只按 LRU 淘汰本分类最久未使用的缓存，不会动其它分类；开启本地化后，漫画/小说/视频/音频的缓存保存在本地，下次打开无需重新加载。")
                    if availableBytes > 0 {
                        Text("设备可用空间约 \(DisplayFormatters.size(availableBytes))。")
                    }
                    if exceedsAvailable {
                        Text("上限已超过设备可用空间：配额只是允许占用的上限，实际写满设备前会被系统清理，建议调小或先清理缓存。")
                            .foregroundStyle(.orange)
                    }
                }
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
        .alert(
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
        .alert("清空全部缓存", isPresented: $confirmClearAll) {
            Button("清空", role: .destructive) {
                try? CacheManager.shared.clearAll()
                AppLogger.shared.log("已清空全部缓存")
                reload()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清空全部分区缓存（当前共 \(DisplayFormatters.size(totalSize))），不影响阅读进度与收藏。")
        }
        .onChange(of: totalLimitMB) { newValue in
            let grew = newValue > AppSettings.Cache.totalLimitMB
            AppSettings.Cache.totalLimitMB = newValue
            guard !grew else { return }   // 调大无需回收，只等 UI 刷新配额
            // 上限调小后立即按新配额回收（不等下次写入），随后刷新各行占用
            Task {
                await Task.detached(priority: .utility) {
                    CacheManager.shared.evictAllPartitions()
                }.value
                reload()
            }
        }
        .onChange(of: contentCachingEnabled) { AppSettings.Cache.contentCachingEnabled = $0 }
        .onChange(of: trashRetentionDays) { AppSettings.Trash.retentionDays = $0 }
    }

    private func reload() {
        var result: [CacheManager.Partition: Int64] = [:]
        for partition in CacheManager.Partition.allCases {
            result[partition] = CacheManager.shared.size(of: partition)
        }
        sizes = result
        availableBytes = availableDiskBytes()
    }

    /// 设备可用空间（`.volumeAvailableCapacityForImportantUsage` 为系统建议给 App 用的可用量）
    private func availableDiskBytes() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
