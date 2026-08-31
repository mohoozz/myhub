import SwiftUI
import UIKit

/// 关于页（TODO §10）：版本、开源许可、存储用量、运行日志、应用图标
struct AboutView: View {
    @State private var cacheSize: Int64 = 0

    private struct License: Identifiable {
        let id = UUID()
        let name: String
        let detail: String
    }

    private static let licenses: [License] = [
        License(name: "AMSMB2", detail: "SMB2/3 直连（基于 libsmb2）· MIT"),
        License(name: "VLCKit (MobileVLCKit)", detail: "全格式软解兜底 · LGPL"),
        License(name: "ZIPFoundation", detail: "zip / cbz / epub 解包 · MIT"),
        License(name: "UnrarKit", detail: "rar / cbr 解析"),
        License(name: "GRDB.swift", detail: "SQLite 结构化存储 · MIT"),
        License(name: "Nuke", detail: "图片加载与缓存 · MIT"),
    ]

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    }

    private var appIcon: UIImage? {
        if let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String],
           let name = files.last,
           let image = UIImage(named: name) {
            return image
        }
        return UIImage(named: "AppIcon")
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    if let appIcon {
                        Image(uiImage: appIcon)
                            .resizable()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MyHub")
                            .font(.title3.bold())
                        Text("版本 \(version)（\(build)）")
                            .font(.subheadline)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("存储") {
                NavigationLink {
                    CacheSettingsView()
                } label: {
                    HStack {
                        Label("缓存占用", systemImage: "internaldrive")
                        Spacer()
                        Text(DisplayFormatters.size(cacheSize))
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
                NavigationLink { LogView() } label: {
                    Label("运行日志", systemImage: "doc.text")
                }
            }

            Section("开源许可") {
                ForEach(Self.licenses) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
            }

            Section {
                Text("纯本地化应用：所有数据保存在本设备，不上传任何用户内容。")
                    .font(.footnote)
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
        .navigationTitle("关于")
        .tint(AppColors.primary)
        .onAppear { cacheSize = CacheManager.shared.totalSize() }
    }
}

/// 运行日志查看（AppLogger 文件日志：查看 / 分享 / 清空）
struct LogView: View {
    @State private var content = ""
    @State private var showShare = false
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            Text(content.isEmpty ? "暂无日志" : content)
                .font(.caption.monospaced())
                .foregroundStyle(AppColors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .background(AppColors.pageBackground)
        .navigationTitle("运行日志")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    Button { showShare = true } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(content.isEmpty)
                    Button { confirmClear = true } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(content.isEmpty)
                }
            }
        }
        .onAppear { content = AppLogger.shared.tail() }
        .sheet(isPresented: $showShare) {
            ActivityView(url: AppLogger.shared.url)
        }
        .alert("清空日志", isPresented: $confirmClear) {
            Button("清空", role: .destructive) {
                AppLogger.shared.clear()
                content = ""
            }
            Button("取消", role: .cancel) {}
        }
    }
}
