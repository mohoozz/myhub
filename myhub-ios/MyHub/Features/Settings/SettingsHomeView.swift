import SwiftUI
import UniformTypeIdentifiers

/// 设置首页（TODO §10，IOS-501 ~ 504）
struct SettingsHomeView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var browseDisplaySettings: BrowseDisplaySettings
    @AppStorage("ui.liquidGlassMode") private var liquidGlassMode = true
    @State private var shareURL: URL?
    @State private var showImporter = false
    @State private var notice: Notice?

    private struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var body: some View {
        NavigationStack {
            settingsList
        }
    }

    private var settingsList: some View {
        List {
            Section("通用") {
                NavigationLink { ConnectionListView() } label: {
                    Label("连接源管理", systemImage: "externaldrive.connected.to.line.below")
                }
                Picker(selection: themeModeBinding) {
                    ForEach(AppThemeMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                } label: {
                    Label("外观", systemImage: "circle.lefthalf.filled")
                }
            }

            Section("显示") {
                Picker(selection: $browseDisplaySettings.fileNameLines) {
                    ForEach(1...5, id: \.self) { lines in
                        Text("\(lines) 行").tag(lines)
                    }
                } label: {
                    Label("文件名行数", systemImage: "text.alignleft")
                }
                Toggle(isOn: $liquidGlassMode) {
                    Label("液体玻璃模式", systemImage: "circle.hexagongrid")
                }
            }

            Section("阅读与播放") {
                NavigationLink { ReaderPreferencesView() } label: {
                    Label("阅读器偏好", systemImage: "book")
                }
                NavigationLink { PlayerPreferencesView() } label: {
                    Label("播放器偏好", systemImage: "play.rectangle")
                }
            }

            Section("存储") {
                NavigationLink { CacheSettingsView() } label: {
                    Label("缓存与存储", systemImage: "internaldrive")
                }
                NavigationLink { TrashConnectionListView() } label: {
                    Label("回收站", systemImage: "trash")
                }
            }

            Section {
                Button { exportConfig() } label: {
                    Label("导出配置", systemImage: "square.and.arrow.up")
                        .foregroundStyle(AppColors.textPrimary)
                }
                Button { showImporter = true } label: {
                    Label("导入配置", systemImage: "square.and.arrow.down")
                        .foregroundStyle(AppColors.textPrimary)
                }
            } header: {
                Text("数据")
            } footer: {
                Text("导出内容为连接源与偏好设置快照，不含明文密码；导入后需重新录入密码。")
            }

            Section("安全") {
                NavigationLink { SecuritySettingsView() } label: {
                    Label("应用锁与凭据", systemImage: "lock.shield")
                }
            }

            Section {
                NavigationLink { AboutView() } label: {
                    Label("关于 MyHub", systemImage: "info.circle")
                }
            }
        }
        .leadingNavTitle("设置")
        .tint(AppColors.primary)
        .sheet(isPresented: shareSheetBinding) {
            if let shareURL {
                ActivityView(url: shareURL)
                    .onDisappear { try? FileManager.default.removeItem(at: shareURL) }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            importConfig(result)
        }
        .alert(notice?.title ?? "", isPresented: noticeBinding, presenting: notice) { _ in
            Button("好", role: .cancel) {}
        } message: { item in
            Text(item.message)
        }
    }

    private var shareSheetBinding: Binding<Bool> {
        Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )
    }

    private var noticeBinding: Binding<Bool> {
        Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )
    }

    private var themeModeBinding: Binding<AppThemeMode> {
        Binding(
            get: { themeManager.mode },
            set: { themeManager.mode = $0 }
        )
    }

    private func exportConfig() {
        do {
            shareURL = try ConfigTransfer().export()
            AppLogger.shared.log("配置导出成功")
        } catch {
            notice = Notice(title: "导出失败", message: error.localizedDescription)
        }
    }

    private func importConfig(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            notice = Notice(title: "导入失败", message: error.localizedDescription)
        case .success(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let summary = try ConfigTransfer().import(from: url)
                AppLogger.shared.log("配置导入成功：新增连接源 \(summary.insertedConnections) 个，更新 \(summary.updatedConnections) 个")
                notice = Notice(
                    title: "导入完成",
                    message: "新增连接源 \(summary.insertedConnections) 个，更新 \(summary.updatedConnections) 个；偏好设置已应用，密码需重新录入。"
                )
            } catch {
                notice = Notice(title: "导入失败", message: error.localizedDescription)
            }
        }
    }
}
