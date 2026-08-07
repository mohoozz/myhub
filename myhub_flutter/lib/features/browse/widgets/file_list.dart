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
    this.onLongPressMenu,
    this.highlightPath,
    this.highlightKey,
    this.onLongPress,
    super.key,
  });

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

  /// 长按（桌面端非多选时进入多选；多选时切换选中；移动端非多选为 null）。
  final ValueChanged<FileItem>? onLongPress;

  /// 移动端长按（非多选模式）呼出与右键相同的上下文菜单。
  final void Function(FileItem item, Offset position)? onLongPressMenu;

  /// 已收藏键集合（"sourceId|path"）。
  final Set<String> favoritePaths;

  /// 当前路径源 ID（收藏键前缀）。
  final int? favoriteSourceId;

  /// 星标点击（收藏/取消收藏）。
  final ValueChanged<FileItem>? onToggleFavorite;

  /// 右键呼出上下文菜单（桌面端），携带点击全局坐标。
  final void Function(FileItem item, Offset position)? onShowMenu;

  /// 高亮定位文件路径：匹配项显示高亮边框。
  final String? highlightPath;

  /// 高亮项的 GlobalKey（供上层滚动定位）。
  final GlobalKey? highlightKey;

  @override
  Widget build(BuildContext context) {
    final list = ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: items.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 54),
      itemBuilder: (context, index) {
        final item = items[index];
        final highlighted = highlightPath != null && item.path == highlightPath;
        Widget row = _FileRow(
          item: item,
          coverSourceId: favoriteSourceId,
          selectionMode: selectionMode,
          selected: selectedPaths.contains(item.path),
          highlighted: highlighted,
          favorited: favoritePaths.contains('$favoriteSourceId|${item.path}'),
          onTap: () =>
              selectionMode ? onToggleSelect?.call(item) : onOpen(item),
          onLongPress: onLongPress == null ? null : () => onLongPress!(item),
          onToggleFavorite: onToggleFavorite == null
              ? null
              : () => onToggleFavorite!(item),
          onSecondaryTapUp: onShowMenu == null
              ? null
              : (d) => onShowMenu!(item, d.globalPosition),
          onLongPressMenu: onLongPressMenu == null
              ? null
              : (d) => onLongPressMenu!(item, d.globalPosition),
        );
        if (highlighted && highlightKey != null) {
          row = KeyedSubtree(key: highlightKey, child: row);
        }
        return row;
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
    this.highlighted = false,
    this.onToggleFavorite,
    this.onSecondaryTapUp,
    this.onLongPressMenu,
  });

  final FileItem item;

  /// 当前路径源 ID（封面缩略图加载用）。
  final int? coverSourceId;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selectionMode;
  final bool selected;
  final bool favorited;

  /// 高亮定位提示（来自"正在阅读"页跳转）。
  final bool highlighted;
  final VoidCallback? onToggleFavorite;
  final GestureTapUpCallback? onSecondaryTapUp;

  /// 移动端长按（非多选模式）呼出上下文菜单，携带按下位置。
  final GestureLongPressStartCallback? onLongPressMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    // 外层处理移动端长按弹菜单：该手势仅在桌面端长按（进入多选）为空时注册，
    // 与内层 InkWell 的长按手势互斥，不会同时响应。
    return GestureDetector(
      onLongPressStart: onLongPressMenu,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTapUp: onSecondaryTapUp,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? colorScheme.primary.withValues(alpha: 0.08)
                : null,
            border: highlighted
                ? Border.all(color: colorScheme.primary, width: 1.6)
                : null,
          ),
          child: Row(
            children: [
              if (selectionMode)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Icon(
                    selected ? LucideIcons.circleCheck : LucideIcons.circle,
                    size: 18,
                    color: selected
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
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
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: highlighted ? colorScheme.primary : null,
                    fontWeight: highlighted ? FontWeight.w600 : null,
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  item.isDir ? '-' : formatBytes(item.size),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 11,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  formatModTime(item.modTime),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 11,
                    color: colorScheme.onSurfaceVariant,
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
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                ),
                onPressed: onToggleFavorite,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
