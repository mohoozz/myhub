import SwiftUI

/// 点击/长按选中态高亮（IOS-702）：按压浅蓝高亮 + 缩放 0.975（与文件 cell 的按压表现对齐，TODO 375）。
/// 高亮以半透明 overlay 叠加，避免被卡片不透明背景遮住。
struct SelectableCellStyle: ButtonStyle {
    var cornerRadius: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(configuration.isPressed ? AppColors.primary.opacity(0.08) : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.appFast, value: configuration.isPressed)
    }
}

/// 漫画徽标
struct ComicBadge: View {
    var body: some View {
        Text("漫画")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(AppColors.primary)
            .clipShape(Capsule())
    }
}

/// 多选勾选标记（右上角）
struct SelectionCheckmark: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? AppColors.primary : Color.white)
            .background(Circle().fill(isSelected ? Color.white : Color.black.opacity(0.35)).padding(2))
            .padding(6)
    }
}

// MARK: - 网格单元格

/// 网格视图单元格：封面/图标、文件名、视频时长角标、漫画徽标。
/// 长按（iOS，底部抽屉）/ 指针右键（iPad/PC，锚点卡片）弹出操作菜单；多选经菜单「多选」或右上角「…」→「选择」进入。
struct FileGridCell: View {
    let entry: FileEntry
    let connection: Connection
    let adapter: StorageAdapter
    let siblings: [FileEntry]
    let highlighted: Bool
    let isSelecting: Bool
    let isSelected: Bool
    /// 阅读进度 0~1；nil 表示无历史记录
    let progress: Double?
    /// 是否正在（mini）播放器播放
    let isPlaying: Bool
    let menuItems: [PopupMenuItem]
    let onTap: () -> Void
    /// 目录层预判：epub 内容为图集型（漫画）时按漫画显示徽标（IOS-207 策略 5）
    var isComicEpub: Bool = false

    @State private var duration: Double?
    @EnvironmentObject private var browseDisplaySettings: BrowseDisplaySettings

    private var mediaType: MediaType {
        isComicEpub ? .comic : MediaType.detect(ext: entry.ext)
    }

    var body: some View {
        VStack(spacing: 6) {
            cover
            VStack(alignment: .center, spacing: 2) {
                Text(entry.name)
                    .font(.subheadline)
                    .fontWeight(isPlaying ? .semibold : .regular)
                    .foregroundStyle(isPlaying ? AppColors.primary : AppColors.textPrimary)
                    .lineLimit(browseDisplaySettings.fileNameLines, reservesSpace: true)
                    .multilineTextAlignment(.center)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(8)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppColors.cardBorder, lineWidth: 1)   // 白底主界面下卡片描边界定（TODO 376）
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .hoverEffect(.highlight)                // iPad/PC 指针 hover（自定义淡填充由高亮层统一渲染）
        .breathingHighlight(highlighted)        // 「定位到原路径」呼吸灯（约 10s，不常亮）
        // 点击 / 长按 / 指针右键弹出操作菜单；选中态浮起抬升（TODO 375 方案 D）
        .cellPressableMenu(
            selectedScale: 1.03,
            isSelected: isSelected,
            items: menuItems,
            onTap: onTap
        )
    }

    private var cover: some View {
        RemoteCoverImage(
            entry: entry, connection: connection, adapter: adapter,
            siblings: siblings, duration: $duration
        )
        .frame(maxWidth: .infinity)
        .aspectRatio(1.35, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .topLeading) {
            // 漫画徽标；多选态该角让给进度环/播放动画（右上角被勾选标记占用，TODO 371）
            if mediaType == .comic, !isSelecting {
                ComicBadge().padding(6)
            } else if isSelecting, hasStatus {
                statusBadge
            }
        }
        .overlay(alignment: .topTrailing) {
            if isSelecting {
                SelectionCheckmark(isSelected: isSelected)
            } else if hasStatus {
                statusBadge
            }
        }
    }

    /// 是否有需要展示的状态（正在播放 / 有阅读进度）
    private var hasStatus: Bool { isPlaying || progress != nil }

    /// 状态角标：正在播放动画 / 阅读进度环（深色圆底，覆盖在封面上）
    private var statusBadge: some View {
        FileStatusIndicator(progress: progress, isPlaying: isPlaying, size: 18)
            .padding(6)
            .background(
                Circle().fill(.black.opacity(0.35)).padding(2)
            )
    }

    private var caption: String {
        if entry.isDir {
            return "文件夹"
        }
        var parts: [String] = []
        if let duration { parts.append(DisplayFormatters.duration(duration)) }
        parts.append(DisplayFormatters.size(entry.size))
        return parts.joined(separator: " · ")
    }
}

// MARK: - 列表行

/// 列表视图行（与网格切换，IOS-102 新增列表视图）
struct FileListRow: View {
    let entry: FileEntry
    let connection: Connection
    let adapter: StorageAdapter
    let siblings: [FileEntry]
    let highlighted: Bool
    let isSelecting: Bool
    let isSelected: Bool
    /// 阅读进度 0~1；nil 表示无历史记录
    let progress: Double?
    /// 是否正在（mini）播放器播放
    let isPlaying: Bool
    let menuItems: [PopupMenuItem]
    let onTap: () -> Void
    /// 目录层预判：epub 内容为图集型（漫画）时按漫画显示徽标（IOS-207 策略 5）
    var isComicEpub: Bool = false

    @State private var duration: Double?
    @EnvironmentObject private var browseDisplaySettings: BrowseDisplaySettings

    private var mediaType: MediaType {
        isComicEpub ? .comic : MediaType.detect(ext: entry.ext)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                RemoteCoverImage(
                    entry: entry, connection: connection, adapter: adapter,
                    siblings: siblings, duration: $duration
                )
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if mediaType == .comic, !isSelecting {
                        ComicBadge().padding(3).scaleEffect(0.85, anchor: .topLeading)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name)
                        .font(.body.weight(isPlaying ? .bold : .semibold))
                        .foregroundStyle(isPlaying ? AppColors.primary : AppColors.textPrimary)
                        .lineLimit(browseDisplaySettings.fileNameLines)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 8)
                // 多选态仍保留进度环/播放动画（勾选标记并排在其右侧，TODO 371）
                if isPlaying || progress != nil {
                    FileStatusIndicator(progress: progress, isPlaying: isPlaying, size: 18)
                }
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? AppColors.primary : AppColors.textSecondary)
                } else if entry.isDir {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .hoverEffect(.highlight)
            .breathingHighlight(highlighted, cornerRadius: 0)
            // 通栏列表行：高亮块内缩 4/6 收边成悬浮片，选中浮起（TODO 375 方案 D）
            .cellPressableMenu(
                cornerRadius: 0,
                highlightInset: EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6),
                isSelected: isSelected,
                items: menuItems,
                onTap: onTap
            )
        }
    }

    private var caption: String {
        if entry.isDir {
            return "目录"
        }
        var parts = [mediaType.label]
        if let duration { parts.append(DisplayFormatters.duration(duration)) }
        parts.append(DisplayFormatters.size(entry.size))
        return parts.joined(separator: " · ")
    }
}
