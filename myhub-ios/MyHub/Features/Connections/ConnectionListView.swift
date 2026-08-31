import SwiftUI

extension ConnectionType {
    var displayName: String {
        switch self {
        case .local: return "本地"
        case .webdav: return "WebDAV"
        case .smb: return "SMB"
        case .ftp: return "FTP（预留）"
        case .sftp: return "SFTP（预留）"
        case .nfs: return "NFS（预留）"
        }
    }

    var symbol: String {
        switch self {
        case .local: return "internaldrive"
        case .webdav: return "globe"
        case .smb: return "network"
        case .ftp, .sftp: return "arrow.up.arrow.down.circle"
        case .nfs: return "externaldrive"
        }
    }

    /// 表单可选类型（预留协议不出现）
    static var supportedCases: [ConnectionType] { [.local, .webdav, .smb] }
}

/// 连接源管理（IOS-101）：列表（类型图标/挂载点/开关）、测试状态绿/红点、删除确认
struct ConnectionListView: View {
    @EnvironmentObject private var store: ConnectionStore
    @State private var editing: EditingContext?
    @State private var deleting: Connection?

    private struct EditingContext: Identifiable {
        let id = UUID()
        var connection: Connection
        var isNew: Bool
    }

    var body: some View {
        List {
            ForEach(store.connections) { connection in
                row(connection)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editing = EditingContext(connection: connection, isNew: false)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { deleting = connection } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }
        }
        .overlay { emptyState }
        .navigationTitle("连接源")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editing = EditingContext(connection: .empty(), isNew: true)
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $editing) { context in
            ConnectionFormView(store: store, connection: context.connection, isNew: context.isNew)
        }
        .alert(
            "删除连接源",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { connection in
            Button("删除", role: .destructive) {
                store.delete(connection)
                deleting = nil
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { connection in
            Text("将删除「\(connection.name)」及其本地凭据，远端文件不受影响。")
        }
        .onAppear { store.reload() }
    }

    private func row(_ connection: Connection) -> some View {
        HStack(spacing: 12) {
            Image(systemName: connection.type.symbol)
                .font(.title3)
                .foregroundStyle(AppColors.primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name)
                    .font(.body)
                    .foregroundStyle(AppColors.textPrimary)
                Text(connection.type.displayName)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }
            Spacer()
            statusDot(connection)
            Toggle("", isOn: Binding(
                get: { connection.enabled },
                set: { store.setEnabled(connection, $0) }
            ))
            .labelsHidden()
        }
    }

    /// 测试状态点：正常绿点 / 异常红点 / 测试中转圈（仅首次自动测试）；
    /// 成功后旁侧显示（内网）/（外网）实际生效路径提示；点击状态点可手动重新测试
    @ViewBuilder
    private func statusDot(_ connection: Connection) -> some View {
        let state = connection.id.flatMap { store.testStates[$0] } ?? .unknown
        Button {
            Task { await store.test(connection) }
        } label: {
            HStack(spacing: 4) {
                Group {
                    switch state {
                    case .testing:
                        ProgressView().controlSize(.mini)
                    case .success:
                        Circle().fill(.green)
                    case .failure:
                        Circle().fill(.red)
                    case .unknown:
                        Circle().fill(.gray.opacity(0.4))
                    }
                }
                .frame(width: 10, height: 10)
                if let badge = state.routeBadge {
                    Text(badge)
                        .font(.caption2)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("点击重新测试连接")
        .task { await store.testIfNeeded(connection) }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.connections.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("还没有连接源，点右上角 + 添加")
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
    }
}

extension Connection {
    static func empty(type: ConnectionType = .webdav) -> Connection {
        Connection(
            id: nil, name: "", type: type, configJSON: "{}",
            mountPoint: "", enabled: true, createdAt: Date()
        )
    }
}
