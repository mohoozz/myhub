import SwiftUI

/// 移动/复制目标目录选择器（IOS-104）：可切换连接源（同源走适配器 move/copy，跨源由调用方流式中转）。
struct DestinationPickerView: View {
    let title: String                  // 「移动到」「复制到」
    let connections: [Connection]      // 已启用连接源
    let initialConnectionID: Int64
    let onPick: (Connection, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var connection: Connection?
    @State private var path: String = "/"
    @State private var dirs: [FileEntry] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var newFolderName = ""
    @State private var showNewFolder = false

    init(
        title: String,
        connections: [Connection],
        initialConnectionID: Int64,
        onPick: @escaping (Connection, String) -> Void
    ) {
        self.title = title
        self.connections = connections
        self.initialConnectionID = initialConnectionID
        self.onPick = onPick
        _connection = State(initialValue: connections.first { $0.id == initialConnectionID } ?? connections.first)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 连接源切换
                if connections.count > 1 {
                    Menu {
                        ForEach(connections) { item in
                            Button {
                                switchConnection(item)
                            } label: {
                                Label(item.name, systemImage: item.type.symbol)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: connection?.type.symbol ?? "externaldrive")
                            Text(connection?.name ?? "选择连接源")
                                .font(.subheadline.weight(.medium))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                        }
                        .foregroundStyle(AppColors.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(AppColors.highlightBackground)
                        .clipShape(Capsule())
                    }
                    .padding(.vertical, 8)
                }

                // 当前路径
                HStack(spacing: 6) {
                    if path != "/" {
                        Button {
                            path = StoragePath.parent(of: path)
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.pressScale)
                    }
                    Text(path == "/" ? "根目录" : path)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)

                Divider().overlay(AppColors.separator)

                // 目录列表
                content
            }
            .background(AppColors.pageBackground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        newFolderName = ""
                        showNewFolder = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    Button("选择此处") {
                        if let connection { onPick(connection, path) }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .alert("新建文件夹", isPresented: $showNewFolder) {
                TextField("文件夹名称", text: $newFolderName)
                Button("创建") { Task { await createFolder() } }
                Button("取消", role: .cancel) {}
            }
            .task(id: reloadToken) { await load() }
        }
    }

    private var reloadToken: String {
        "\(connection?.id ?? -1)|\(path)"
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            Spacer()
            ProgressView("正在加载…")
            Spacer()
        } else if let error {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
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
            Spacer()
        } else if dirs.isEmpty {
            Spacer()
            Text("无子文件夹")
                .foregroundStyle(AppColors.textSecondary)
            Spacer()
        } else {
            List(dirs, id: \.path) { dir in
                Button {
                    path = dir.path
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(AppColors.primary)
                        Text(dir.name)
                            .foregroundStyle(AppColors.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
                .listRowBackground(AppColors.cardBackground)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func switchConnection(_ item: Connection) {
        guard item.id != connection?.id else { return }
        connection = item
        path = "/"
    }

    private func load() async {
        guard let connection, let adapter = try? AdapterFactory.makeAdapter(for: connection) else {
            error = "连接不可用"
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            dirs = try await adapter.list(path)
                .filter(\.isDir)
                .sorted { $0.name.naturalCompare($1.name) == .orderedAscending }
        } catch {
            dirs = []
            self.error = error.localizedDescription
        }
    }

    private func createFolder() async {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard let connection, !name.isEmpty,
              !name.contains("/"),
              let adapter = try? AdapterFactory.makeAdapter(for: connection) else { return }
        do {
            try await adapter.mkdir(StoragePath.joining(path, name))
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
