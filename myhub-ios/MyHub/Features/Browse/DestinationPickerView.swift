import SwiftUI

/// 移动/复制目标目录选择器（IOS-104）：可切换连接源（同源走适配器 move/copy，跨源由调用方流式中转）。
///
/// 改版（对齐浏览页列表观感，原型见 `prototype/move-destination-picker-options.html` 方案 B 变体）：
/// - 导航栏只留居中标题：「取消」下沉到底部操作栏，右上角不再放「新建文件夹 / 选择此处」；
/// - 顶部改为可点击面包屑，任意层级直达（长路径横向滚动，当前层级高亮）；
/// - 列表行高 72pt（图标 44pt + 上下 14pt），首行固定「上一级」，回到根目录即隐藏；
/// - 底部为毛玻璃悬浮三键栏：取消 / 新建文件夹 / 移动到此，外壳与浏览页多选操作栏
///   （`BrowseDirectoryView.selectionBar`）同款：14pt 圆角 + `.ultraThinMaterial` + 1pt 描边 + 阴影。
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

    /// 底部操作栏为列表预留的高度（栏本体由 overlay 绘制，与多选操作栏同一套做法）：
    /// 栏高 56（8+8 内边距 + 24 图标槽 + 3 间距 + caption2）+ 8 底部间距 + 4 呼吸位
    private static let actionBarReserve: CGFloat = 76

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
                if connections.count > 1 {
                    connectionMenu
                }
                breadcrumbBar
                content
            }
            .background(AppColors.pageBackground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // 操作栏用 overlay 浮在列表之上（栏后内容可继续滚动），预留高度放在列表尾部
            .overlay(alignment: .bottom) { actionBar }
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

    // MARK: - 连接源切换

    private var connectionMenu: some View {
        HStack {
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
                .padding(.vertical, 6)
                .background(AppColors.highlightBackground)
                .clipShape(Capsule())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    // MARK: - 面包屑（任意层级直达）

    /// 路径层级：根固定显示「根目录」，其余按 / 切分逐级累计
    private var segments: [PathSegment] {
        var result = [PathSegment(name: "根目录", path: "/")]
        var acc = ""
        for component in StoragePath.normalize(path).split(separator: "/") {
            let name = String(component)
            acc += "/" + name
            result.append(PathSegment(name: name, path: acc))
        }
        return result
    }

    private var breadcrumbBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    // 注：不用 `Array(enumerated())` + `id: \.element.path`——Swift 不支持指向元组元素的 KeyPath
                    ForEach(segments, id: \.path) { segment in
                        if segment.path != "/" {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(AppColors.textSecondary.opacity(0.5))
                        }
                        crumbChip(segment, isLast: segment.path == StoragePath.normalize(path))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.hidden)
            // 进入深层目录后把当前层级滚到可见处（长路径不会被截断）
            .onChange(of: path) { _ in
                guard let last = segments.last else { return }
                withAnimation(.appQuick) { proxy.scrollTo(last.path, anchor: .trailing) }
            }
        }
    }

    private func crumbChip(_ segment: PathSegment, isLast: Bool) -> some View {
        Button {
            guard segment.path != path else { return }
            path = segment.path
        } label: {
            Text(segment.name)
                .font(.system(size: 12.5, weight: isLast ? .semibold : .regular))
                .foregroundStyle(isLast ? AppColors.textPrimary : AppColors.primary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isLast ? AppColors.highlightBackground : AppColors.fieldFill)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .id(segment.path)
    }

    // MARK: - 目录列表

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack {
                Spacer()
                ProgressView("正在加载…")
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if let error {
            VStack {
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
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // 「上一级」只在非根目录出现：手指可达区，单手握持也能回退（副标题写明回到哪）
                    if path != "/" {
                        pickerRow(
                            title: "上一级",
                            subtitle: "回到 \(parentName)",
                            symbol: "arrow.up",
                            tint: AppColors.textSecondary,
                            fill: AppColors.fieldFill,
                            showsSeparator: !dirs.isEmpty
                        ) {
                            path = StoragePath.parent(of: path)
                        }
                    }
                    ForEach(dirs, id: \.path) { dir in
                        pickerRow(
                            title: dir.name,
                            subtitle: "文件夹",
                            symbol: "folder.fill",
                            tint: AppColors.primary,
                            fill: AppColors.highlightBackground,
                            showsSeparator: dir.path != dirs.last?.path
                        ) {
                            path = dir.path
                        }
                    }
                    if dirs.isEmpty {
                        Text("此目录下没有子文件夹")
                            .font(.system(size: 12.5))
                            .foregroundStyle(AppColors.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 28)
                    }
                    // 底部操作栏的预留高度：让最后一行能滚到栏上方
                    Color.clear.frame(height: Self.actionBarReserve)
                }
            }
        }
    }

    private var parentName: String {
        let parent = StoragePath.parent(of: path)
        return parent == "/" ? "根目录" : StoragePath.fileName(of: parent)
    }

    private func pickerRow(
        title: String,
        subtitle: String,
        symbol: String,
        tint: Color,
        fill: Color,
        showsSeparator: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(fill)
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: symbol)
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(tint)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary.opacity(0.6))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)          // 44 + 14 × 2 = 72pt 行高
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                // 分隔线左端对齐文字起点，不再通栏
                if showsSeparator {
                    Rectangle()
                        .fill(AppColors.separator)
                        .frame(height: 0.5)
                        .padding(.leading, 72)
                }
            }
        }
        .buttonStyle(PickerRowButtonStyle())
    }

    // MARK: - 底部操作栏（毛玻璃悬浮三键）

    /// 确认键文案随动作变化：移动/复制共用同一个选择器
    private var confirmTitle: String {
        title.hasPrefix("复制") ? "复制到此" : "移动到此"
    }

    private var confirmSymbol: String {
        title.hasPrefix("复制") ? "doc.on.doc" : "arrow.right.doc.on.clipboard"
    }

    private var actionBar: some View {
        HStack(spacing: 0) {
            barButton("取消", symbol: "xmark", color: AppColors.textSecondary) {
                dismiss()
            }
            barButton("新建文件夹", symbol: "folder.badge.plus", color: AppColors.primary) {
                newFolderName = ""
                showNewFolder = true
            }
            barButton(
                confirmTitle, symbol: confirmSymbol, color: AppColors.primary,
                enabled: connection != nil
            ) {
                guard let connection else { return }
                onPick(connection, path)
                dismiss()
            }
        }
        .padding(.vertical, 8)
        // 与多选操作栏同款外壳：毛玻璃填充 + 裁切 + 1pt 描边 + 阴影
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppColors.cardBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// 操作栏按钮：图标在上、caption2 文字在下（与多选操作栏 `selectionButton` 同款）
    private func barButton(
        _ title: String,
        symbol: String,
        color: Color,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                // 固定图标槽高度：各 SF Symbol 固有尺寸不同，不统一会文字/图标错位
                Image(systemName: symbol)
                    .font(.body)
                    .frame(height: 24)
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .foregroundStyle(enabled ? color : AppColors.textSecondary.opacity(0.5))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - 数据

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

/// 面包屑层级（根固定为「根目录」）
private struct PathSegment {
    let name: String
    let path: String
}

/// 目录行按压反馈：按下时铺一层主色浅底（`List` 默认高亮在 ScrollView 里没有，需自绘）
private struct PickerRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? AppColors.highlightBackground.opacity(0.7) : Color.clear)
    }
}
