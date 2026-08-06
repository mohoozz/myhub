import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/features/browse/widgets/file_cover.dart';
import 'package:myhub_flutter/shared/utils/format.dart';

/// 文件列表视图。
class FileListView extends StatelessWidget {
  const FileListView({
    required this.items,
    required this.onOpen,
    this.onRefresh,
    this.selectionMode = false,
    this.selectedPaths = const {},
    this.onToggleSelect,
    this.favoritePaths = const {},
    this.favoriteSourceId,
    this.onToggleFavorite,
    this.onShowMenu,
    ValueChanged<FileItem>? onLongPress,
    super.key,
  }) : onLongPress = onLongPress ?? onToggleSelect;

  final List<FileItem> items;

  /// 点击条目：目录进入，文件打开（由上层决定行为）。
  final ValueChanged<FileItem> onOpen;

  /// 下拉刷新回调（为空则不可下拉）。
  final Future<void> Function()? onRefresh;

  /// 多选模式。
  final bool selectionMode;

  /// 已选中路径集合。
  final Set<String> selectedPaths;

  /// 切换选中（点击或长按）。
  final ValueChanged<FileItem>? onToggleSelect;

  /// 长按（默认等同切换选中）。
  final ValueChanged<FileItem>? onLongPress;

  /// 已收藏键集合（"sourceId|path"）。
  final Set<String> favoritePaths;

  /// 当前路径源 ID（收藏键前缀）。
  final int? favoriteSourceId;

  /// 星标点击（收藏/取消收藏）。
  final ValueChanged<FileItem>? onToggleFavorite;

  /// 右键呼出上下文菜单（桌面端），携带点击全局坐标。
  final void Function(FileItem item, Offset position)? onShowMenu;

  @override
  Widget build(BuildContext context) {
    final list = ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: items.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 54),
      itemBuilder: (context, index) {
        final item = items[index];
        return _FileRow(
          item: item,
          coverSourceId: favoriteSourceId,
          selectionMode: selectionMode,
          selected: selectedPaths.contains(item.path),
          favorited:
              favoritePaths.contains('$favoriteSourceId|${item.path}'),
          onTap: () =>
              selectionMode ? onToggleSelect?.call(item) : onOpen(item),
          onLongPress: () => onLongPress?.call(item),
          onToggleFavorite: onToggleFavorite == null
              ? null
              : () => onToggleFavorite!(item),
          onSecondaryTapUp: onShowMenu == null
              ? null
              : (d) => onShowMenu!(item, d.globalPosition),
        );
      },
    );
    if (onRefresh == null) return list;
    return RefreshIndicator(onRefresh: onRefresh!, child: list);
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.item,
    required this.coverSourceId,
    required this.onTap,
    required this.onLongPress,
    required this.selectionMode,
    required this.selected,
    required this.favorited,
    this.onToggleFavorite,
    this.onSecondaryTapUp,
  });

  final FileItem item;

  /// 当前路径源 ID（封面缩略图加载用）。
  final int? coverSourceId;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool selectionMode;
  final bool selected;
  final bool favorited;
  final VoidCallback? onToggleFavorite;
  final GestureTapUpCallback? onSecondaryTapUp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTapUp: onSecondaryTapUp,
      child: Container(
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.08)
            : null,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            if (selectionMode)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Icon(
                  selected ? LucideIcons.circleCheck : LucideIcons.circle,
                  size: 18,
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            SizedBox(
              width: 32,
              height: 32,
              child: FileCover(
                item: item,
                sourceId: coverSourceId,
                iconSize: 20,
                borderRadius: 6,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 4,
              child: Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                item.isDir ? '-' : formatBytes(item.size),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 11,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                formatModTime(item.modTime),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 11,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            IconButton(
              iconSize: 15,
              visualDensity: VisualDensity.compact,
              tooltip: favorited ? '取消收藏' : '收藏',
              icon: Icon(
                LucideIcons.star,
                color: favorited
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              onPressed: onToggleFavorite,
            ),
          ],
        ),
      ),
    );
  }
}
