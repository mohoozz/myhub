import SwiftUI

/// 回收站连接源选择页（IOS-106）：回收站为各挂载点下 `.trash` 目录
struct TrashConnectionListView: View {
    @StateObject private var store = ConnectionStore()

    var body: some View {
        List(store.connections.filter(\.enabled)) { connection in
            NavigationLink {
                TrashView(connection: connection)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: connection.type.symbol)
                        .foregroundStyle(AppColors.primary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connection.name)
                            .foregroundStyle(AppColors.textPrimary)
                        Text(connection.mountPoint)
                            .font(.caption)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
            }
        }
        .overlay {
            if store.connections.filter(\.enabled).isEmpty {
                Text("暂无可用连接源")
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
        .navigationTitle("回收站")
        .onAppear { store.reload() }
    }
}

/// 回收站页（IOS-106）：列表、滑动还原/彻底删除、清空、过期自动清理（默认 30 天）
struct TrashView: View {
    let connection: Connection

    @State private var items: [TrashItem] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var operationError: String?
    @State private var showClearConfirm = false
    @State private var cleanedCount = 0

    private var service: TrashService? { TrashService(connection: connection) }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("正在加载…")
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
                    Button("重试") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                        .tint(AppColors.primary)
                }
            } else if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "trash")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("回收站为空")
                        .foregroundStyle(AppColors.textSecondary)
                    if cleanedCount > 0 {
                        Text("已自动清理 \(cleanedCount) 个过期项目")
                            .font(.caption)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
            } else {
                List {
                    ForEach(items) { item in
                        row(item)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    Task { await deletePermanently(item) }
                                } label: {
                                    Label("彻底删除", systemImage: "trash.fill")
                                }
                                Button {
                                    Task { await restore(item) }
                                } label: {
                                    Label("还原", systemImage: "arrow.uturn.backward")
                                }
                                .tint(.green)
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("回收站 · \(connection.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("清空") { showClearConfirm = true }
                    .disabled(items.isEmpty)
            }
        }
        .confirmationDialog(
            "清空回收站",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("全部彻底删除", role: .destructive) {
                Task { await clear() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将彻底删除 \(items.count) 个项目，不可恢复。")
        }
        .alert("操作失败", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("知道了", role: .cancel) { operationError = nil }
        } message: {
            Text(operationError ?? "")
        }
        .task { await load() }
    }

    private func row(_ item: TrashItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.isDir ? "folder.fill" : "doc")
                .foregroundStyle(AppColors.primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.body)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                if let original = item.originalPath {
                    Text(original)
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                HStack(spacing: 8) {
                    if let deletedAt = item.deletedAt {
                        Text(DisplayFormatters.modTime(deletedAt))
                    }
                    if !item.isDir, item.size > 0 {
                        Text(DisplayFormatters.size(item.size))
                    }
                }
                .font(.caption)
                .foregroundStyle(AppColors.textSecondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 操作

    private func load() async {
        guard let service else {
            error = "连接不可用"
            isLoading = false
            return
        }
        isLoading = true
        error = nil
        // 过期自动清理（默认 30 天，AppSettings.Trash.retentionDays）
        cleanedCount = await service.cleanupExpired(retentionDays: AppSettings.Trash.retentionDays)
        do {
            items = try await service.listItems()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func restore(_ item: TrashItem) async {
        do {
            try await service?.restore(item)
            await reloadQuietly()
        } catch {
            operationError = "还原失败：\(error.localizedDescription)"
        }
    }

    private func deletePermanently(_ item: TrashItem) async {
        do {
            try await service?.deletePermanently(item)
            await reloadQuietly()
        } catch {
            operationError = "删除失败：\(error.localizedDescription)"
        }
    }

    private func clear() async {
        do {
            try await service?.clear()
            await reloadQuietly()
        } catch {
            operationError = "清空失败：\(error.localizedDescription)"
        }
    }

    private func reloadQuietly() async {
        items = (try? await service?.listItems()) ?? items
    }
}
