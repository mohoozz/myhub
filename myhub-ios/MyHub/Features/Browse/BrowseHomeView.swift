import SwiftUI

/// 文件浏览主页（TODO §3.1，IOS-102）：
/// 连接源选择器（启用状态 / 绿·红点）+ 目录导航栈（NavigationStack 自带左侧边缘交互式 pop 返回上一级）。
/// 处理「定位到原路径」（BrowseLocator）：重建目录栈直达目标所在目录，
/// 目录页自取全局高亮状态完成滚动定位 + 呼吸灯高亮约 10s。
struct BrowseHomeView: View {
    @EnvironmentObject private var store: ConnectionStore
    @EnvironmentObject private var locator: BrowseLocator
    @EnvironmentObject private var router: AppRouter

    @State private var navPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navPath) {
            sourceList
                .navigationDestination(for: BrowseLocation.self) { location in
                    if let connection = connection(for: location.connectionID) {
                        BrowseDirectoryView(
                            connection: connection,
                            path: location.path,
                            navPath: $navPath,
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
        .onAppear {
            store.reload()
            // 兜底：定位请求可能在浏览页挂载 / 导航栈就绪前就已发出（onChange 不会对已存在的值触发）
            if let request = locator.request { handleLocate(request) }
        }
        .onChange(of: locator.request) { request in
            if let request { handleLocate(request) }
        }
        .onChange(of: router.reselectRequest) { request in
            guard request?.tab == .browse else { return }
            handleReselect()
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
        .leadingNavTitle("浏览")
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
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppColors.cardBorder, lineWidth: 1)   // 白底主界面下卡片描边界定（TODO 376）
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(SelectableCellStyle())
    }

    /// 连接状态点（绿/红，复用连接测试体系）；成功后旁侧显示（内网）/（外网）路径提示。
    /// 仅首次自动测试；点击状态点可手动重新测试（不进入目录）
    @ViewBuilder
    private func statusDot(_ connection: Connection) -> some View {
        let state = connection.id.flatMap { store.testStates[$0] } ?? .unknown
        HStack(spacing: 4) {
            Group {
                switch state {
                case .testing: ProgressView().controlSize(.mini)
                case .success: Circle().fill(.green)
                case .failure: Circle().fill(.red)
                case .unknown: Circle().fill(.gray.opacity(0.4))
                }
            }
            .frame(width: 10, height: 10)
            if let badge = state.routeBadge {
                Text(badge)
                    .font(.caption2)
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
        .contentShape(Rectangle())
        .highPriorityGesture(TapGesture().onEnded {
            Task { await store.test(connection) }
        })
        .accessibilityHint("点击重新测试连接")
        .task { await store.testIfNeeded(connection) }
    }

    // MARK: - 导航

    private func connection(for id: Int64) -> Connection? {
        store.connections.first { $0.id == id }
    }

    /// 进入连接源：每次从第一级目录（根）开始，不恢复上次浏览目录
    private func openConnection(_ connection: Connection) {
        guard let id = connection.id else { return }
        navPath = NavigationPath(locations(to: "/", connectionID: id))
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

    // MARK: - 重复点击「浏览」页签：回到路径源选择（起始界面）

    /// 底栏再次点击已选中的「浏览」图标：清空目录导航栈，回到连接源（路径源）选择列表。
    /// 已在起始界面时不做处理（保留原地无变化），避免无意义的状态变更。
    private func handleReselect() {
        guard !navPath.isEmpty else { return }
        navPath = NavigationPath()
    }

    // MARK: - 定位到原路径（重建目录栈；滚动定位与呼吸灯由 BrowseLocator + 目录页完成）

    private func handleLocate(_ request: BrowseLocator.Request) {
        defer { locator.consume() }
        guard connection(for: request.connectionID) != nil else { return }
        // 重建导航栈：从源根逐级到目标文件所在目录（目录页据此滚动定位并呼吸灯高亮）
        let parent = StoragePath.parent(of: request.filePath)
        navPath = NavigationPath(locations(to: parent, connectionID: request.connectionID))
    }
}
