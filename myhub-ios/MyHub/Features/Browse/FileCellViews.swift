import SwiftUI

/// 点击/长按选中态高亮（IOS-702）：按压浅蓝高亮 + 缩放 0.97（参考正在阅读列表高亮）。
/// 高亮以半透明 overlay 叠加，避免被卡片不透明背景遮住。
struct SelectableCellStyle: ButtonStyle {
    var cornerRadius: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(configuration.isPressed ? AppColors.primary.opacity(0.12) : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.appFast, value: configuration.isPressed)
    }
}

/// 视频时长角标（黑底白字胶囊）
struct DurationBadge: View {
    let seconds: Double

    var body: some View {
        Text(DisplayFormatters.duration(seconds))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.65))
            .clipShape(Capsule())
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

/// 网格视图单元格：封面/图标、文件名、文件夹子项数、视频时长角标、漫画徽标。
/// iOS 长按进入多选模式（非仅弹菜单）；指针右键（iPad/PC）弹圆角操作菜单。
struct FileGridCell: View {
    let entry: FileEntry
    let connection: Connection
    let adapter: StorageAdapter
    let siblings: [FileEntry]
    let childCount: Int?
    let highlighted: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let menuItems: [PopupMenuItem]
    let onTap: () -> Void
    let onLongPress: () -> Void

    @State private var duration: Double?
    @State private var hovering = false

    private var mediaType: MediaType { MediaType.detect(ext: entry.ext) }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                cover
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(AppColors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(SelectableCellStyle())
        .onHover { hovering = $0 }              // iPad/PC 指针 hover 高亮（IOS-702）
        .hoverEffect(.highlight)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hovering ? AppColors.primary.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? AppColors.primary : Color.clear, lineWidth: 2)
        )
        .breathingHighlight(highlighted)        // 「定位到原路径」呼吸灯（约 10s，不常亮）
        .popupSecondaryMenu(menuItems)          // 指针右键菜单；长按进入多选
        .onLongPressGesture(minimumDuration: 0.5, perform: onLongPress)
    }

    private var cover: some View {
        RemoteCoverImage(
            entry: entry, connection: connection, adapter: adapter,
            siblings: siblings, duration: $duration
        )
        .aspectRatio(1.35, contentMode: .fit)
        .background(AppColors.highlightBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if let duration, !isSelecting {
                DurationBadge(seconds: duration).padding(6)
            }
        }
        .overlay(alignment: .topLeading) {
            if mediaType == .comic, !isSelecting {
                ComicBadge().padding(6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isSelecting {
                SelectionCheckmark(isSelected: isSelected)
            }
        }
    }

    private var caption: String {
        if entry.isDir {
            return childCount.map { "\($0) 项" } ?? "文件夹"
        }
        let time = DisplayFormatters.modTime(entry.modTime)
        return time.isEmpty
            ? DisplayFormatters.size(entry.size)
            : "\(DisplayFormatters.size(entry.size)) · \(time)"
    }
}

// MARK: - 列表行

/// 列表视图行（与网格切换，IOS-102 新增列表视图）
struct FileListRow: View {
    let entry: FileEntry
    let connection: Connection
    let adapter: StorageAdapter
    let siblings: [FileEntry]
    let childCount: Int?
    let highlighted: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let menuItems: [PopupMenuItem]
    let onTap: () -> Void
    let onLongPress: () -> Void

    @State private var duration: Double?
    @State private var hovering = false

    private var mediaType: MediaType { MediaType.detect(ext: entry.ext) }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                RemoteCoverImage(
                    entry: entry, connection: connection, adapter: adapter,
                    siblings: siblings, duration: $duration
                )
                .frame(width: 52, height: 52)
                .background(AppColors.highlightBackground.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if let duration, !isSelecting {
                        DurationBadge(seconds: duration)
                            .padding(3)
                            .scaleEffect(0.85, anchor: .bottomTrailing)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if mediaType == .comic, !isSelecting {
                        ComicBadge().padding(3).scaleEffect(0.85, anchor: .topLeading)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name)
                        .font(.body)
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
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
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(AppColors.cardBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(SelectableCellStyle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .hoverEffect(.highlight)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovering ? AppColors.primary.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? AppColors.primary : Color.clear, lineWidth: 2)
        )
        .breathingHighlight(highlighted, cornerRadius: 10)
        .popupSecondaryMenu(menuItems)
        .onLongPressGesture(minimumDuration: 0.5, perform: onLongPress)
    }

    private var caption: String {
        if entry.isDir {
            return childCount.map { "\($0) 项" } ?? "文件夹"
        }
        let time = DisplayFormatters.modTime(entry.modTime)
        return time.isEmpty
            ? DisplayFormatters.size(entry.size)
            : "\(DisplayFormatters.size(entry.size)) · \(time)"
    }
}
