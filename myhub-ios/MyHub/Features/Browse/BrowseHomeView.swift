import SwiftUI

/// 文件浏览主页（TODO §3.1，IOS-102）：
/// 连接源选择器（启用状态 / 绿·红点）+ 目录导航栈（NavigationStack 自带左侧边缘交互式 pop 返回上一级）。
/// 处理「定位到原路径」（BrowseLocator）：重建目录栈并呼吸灯高亮目标约 10s。
struct BrowseHomeView: View {
    @StateObject private var store = ConnectionStore()
    @EnvironmentObject private var locator: BrowseLocator

    @State private var navPath = NavigationPath()
    /// 定位高亮目标：连接 + 文件全路径
    @State private var highlight: (connectionID: Int64, path: String)?

    var body: some View {
        NavigationStack(path: $navPath) {
            sourceList
                .navigationDestination(for: BrowseLocation.self) { location in
                    if let connection = connection(for: location.connectionID) {
                        BrowseDirectoryView(
                            connection: connection,
                            path: location.path,
                            navPath: $navPath,
                            highlightPath: highlightTarget(in: location),
                            connections: store.connections.filter(\.enabled)
                        )
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text("连接源不可用（可能已被删除）")
                                .foregroundStyle(AppColors.textSecondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(AppColors.pageBackground)
                    }
                }
        }
        .onAppear { store.reload() }
        .onChange(of: locator.request) { request in
            if let request { handleLocate(request) }
        }
    }

    // MARK: - 连接源选择器

    private var sourceList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(store.connections.filter(\.enabled)) { connection in
                    sourceCard(connection)
                }
            }
            .padding(12)
        }
        .background(AppColors.pageBackground)
        .navigationTitle("浏览")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if store.connections.filter(\.enabled).isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "externaldrive.connected.to.line.below")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("暂无可用连接源")
                        .font(.headline)
                        .foregroundStyle(AppColors.textPrimary)
                    Text("请到「设置 → 连接源管理」添加本地 / WebDAV / SMB")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
        }
    }

    private func sourceCard(_ connection: Connection) -> some View {
        Button {
            openConnection(connection)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: connection.type.symbol)
                    .font(.title3)
                    .foregroundStyle(AppColors.primary)
                    .frame(width: 36, height: 36)
                    .background(AppColors.highlightBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(AppColors.textPrimary)
                    Text(connection.type.displayName)
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }
                Spacer()
                statusDot(connection)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }
            .padding(12)
            .background(AppColors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(SelectableCellStyle())
    }

    /// 连接状态点（绿/红，复用连接测试体系）
    @ViewBuilder
    private func statusDot(_ connection: Connection) -> some View {
        let state = connection.id.flatMap { store.testStates[$0] } ?? .unknown
        Group {
            switch state {
            case .testing: ProgressView().controlSize(.mini)
            case .success: Circle().fill(.green)
            case .failure: Circle().fill(.red)
            case .unknown: Circle().fill(.gray.opacity(0.4))
            }
        }
        .frame(width: 10, height: 10)
        .task { await store.testIfNeeded(connection) }
    }

    // MARK: - 导航

    private func connection(for id: Int64) -> Connection? {
        store.connections.first { $0.id == id }
    }

    /// 进入连接源：恢复最后浏览路径（路径显示偏好缓存）
    private func openConnection(_ connection: Connection) {
        guard let id = connection.id else { return }
        let target = StoragePath.normalize(AppSettings.Browse.lastPaths["\(id)"] ?? "/")
        navPath = NavigationPath(locations(to: target, connectionID: id))
    }

    /// 从连接根到目标路径的逐层导航位置（"/a/b" → ["/a", "/a/b"]）
    private func locations(to path: String, connectionID: Int64) -> [BrowseLocation] {
        var locations: [BrowseLocation] = []
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            locations.append(BrowseLocation(connectionID: connectionID, path: current))
        }
        if locations.isEmpty {
            locations.append(BrowseLocation(connectionID: connectionID, path: "/"))
        }
        return locations
    }

    // MARK: - 定位到原路径（呼吸灯高亮约 10s，不常亮）

    private func handleLocate(_ request: BrowseLocator.Request) {
        guard connection(for: request.connectionID) != nil else {
            locator.consume()
            return
        }
        let parent = StoragePath.parent(of: request.filePath)
        navPath = NavigationPath(locations(to: parent, connectionID: request.connectionID))
        withAnimation(.appQuick) { highlight = (request.connectionID, request.filePath) }
        locator.consume()

        // 约 10s 后淡出高亮（不常亮，IOS-704）
        let target = request.filePath
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard highlight?.path == target else { return }
            withAnimation(.appQuick) { highlight = nil }
        }
    }

    /// 仅目标文件所在目录那一层携带高亮路径
    private func highlightTarget(in location: BrowseLocation) -> String? {
        guard let highlight,
              highlight.connectionID == location.connectionID,
              StoragePath.parent(of: highlight.path) == StoragePath.normalize(location.path)
        else { return nil }
        return highlight.path
    }
}
