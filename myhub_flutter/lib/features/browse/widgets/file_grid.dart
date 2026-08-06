import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/features/browse/widgets/file_cover.dart';
import 'package:myhub_flutter/shared/utils/format.dart';

/// 文件网格视图。
class FileGridView extends StatelessWidget {
  const FileGridView({
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
    this.onParentTap,
    ValueChanged<FileItem>? onLongPress,
    super.key,
  }) : onLongPress = onLongPress ?? onToggleSelect;

  final List<FileItem> items;
  final ValueChanged<FileItem> onOpen;
  final Future<void> Function()? onRefresh;
  final bool selectionMode;
  final Set<String> selectedPaths;
  final ValueChanged<FileItem>? onToggleSelect;
  final ValueChanged<FileItem>? onLongPress;
  final Set<String> favoritePaths;
  final int? favoriteSourceId;
  final ValueChanged<FileItem>? onToggleFavorite;

  /// 右键呼出上下文菜单（桌面端），携带点击全局坐标。
  final void Function(FileItem item, Offset position)? onShowMenu;

  /// 非空时在网格首位插入 ".." 返回上级卡片。
  final VoidCallback? onParentTap;

  @override
  Widget build(BuildContext context) {
    final grid = GridView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 140,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.95,
      ),
      itemCount: items.length + (onParentTap == null ? 0 : 1),
      itemBuilder: (context, index) {
        if (onParentTap != null) {
          if (index == 0) return _ParentCard(onTap: onParentTap!);
          index--;
        }
        final item = items[index];
        return _FileCard(
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
    if (onRefresh == null) return grid;
    return RefreshIndicator(onRefresh: onRefresh!, child: grid);
  }
}

/// ".." 返回上级卡片（网格首位）。
class _ParentCard extends StatelessWidget {
  const _ParentCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: theme.cardTheme.color,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                LucideIcons.folderUp,
                size: 36,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 10),
              Text('..', style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
              Text(
                '返回上级',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 10,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FileCard extends StatelessWidget {
  const _FileCard({
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
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: theme.cardTheme.color,
          borderRadius: BorderRadius.circular(12),
          border: selected
              ? Border.all(color: theme.colorScheme.primary, width: 1.5)
              : null,
        ),
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Expanded(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 72),
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: FileCover(
                            item: item,
                            sourceId: coverSourceId,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    item.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.isDir ? '文件夹' : formatBytes(item.size),
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 10,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (selectionMode)
              Positioned(
                top: 0,
                right: 0,
                child: Icon(
                  selected ? LucideIcons.circleCheck : LucideIcons.circle,
                  size: 18,
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              Positioned(
                top: 0,
                right: 0,
                child: GestureDetector(
                  onTap: onToggleFavorite,
                  child: Icon(
                    LucideIcons.star,
                    size: 15,
                    color: favorited
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
