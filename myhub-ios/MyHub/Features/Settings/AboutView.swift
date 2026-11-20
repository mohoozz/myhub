import SwiftUI
import UIKit

/// 关于页：版本、开源许可、存储用量、运行日志、应用图标
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
        License(name: "UnrarKit", detail: "rar / cbr 解析"),
        License(name: "GRDB.swift", detail: "SQLite 结构化存储 · MIT"),
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

/// 日志查看：崩溃日志（完整调用栈）+ 运行日志，可分别分享
struct LogView: View {
    private enum ShareTarget: Identifiable {
        case runtime, crash

        var id: Int {
            switch self {
            case .runtime: return 0
            case .crash: return 1
            }
        }

        var url: URL {
            switch self {
            case .runtime: return AppLogger.shared.url
            case .crash: return CrashReporter.fileURL
            }
        }
    }

    @State private var content = ""
    @State private var crashContent = ""
    @State private var shareTarget: ShareTarget?
    @State private var confirmClear = false
    /// 详细日志：debug 级（按压层、逐页缓存、逐请求）是否也落盘，默认关闭
    @State private var verbose = AppLogger.shared.isVerboseLogging

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !crashContent.isEmpty {
                    Text("崩溃日志（crash.log）")
                        .font(.caption.bold())
                        .foregroundStyle(AppColors.textSecondary)
                    logText(crashContent)
                }
                Text("运行日志")
                    .font(.caption.bold())
                    .foregroundStyle(AppColors.textSecondary)
                logText(content.isEmpty ? "暂无日志" : content)
            }
            .padding()
        }
        .background(AppColors.pageBackground)
        .navigationTitle("运行日志")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    Menu {
                        Toggle("详细日志（含 debug）", isOn: $verbose)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    Menu {
                        Button("分享运行日志") { shareTarget = .runtime }
                            .disabled(content.isEmpty)
                        Button("分享崩溃日志") { shareTarget = .crash }
                            .disabled(crashContent.isEmpty)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Button { confirmClear = true } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(content.isEmpty)
                }
            }
        }
        .onChange(of: verbose) { newValue in
            AppLogger.shared.isVerboseLogging = newValue
            AppLogger.shared.log(
                newValue ? "已开启详细日志（debug 落盘）" : "已关闭详细日志（仅 info 及以上落盘）",
                module: "app"
            )
        }
        .onAppear(perform: reload)
        .sheet(item: $shareTarget) { target in
            ActivityView(url: target.url)
        }
        .alert("清空日志", isPresented: $confirmClear) {
            Button("清空", role: .destructive) {
                AppLogger.shared.clear()
                content = ""
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅清空运行日志，崩溃日志会保留")
        }
    }

    private func logText(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .foregroundStyle(AppColors.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reload() {
        content = AppLogger.shared.tail()
        // 崩溃记录可能累计很长，界面只显示最近的 400 行
        let crash = CrashReporter.logText()
        crashContent = crash.isEmpty
            ? ""
            : crash.components(separatedBy: "\n").suffix(400).joined(separator: "\n")
    }
}
