import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/features/browse/widgets/file_icon.dart';
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
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return _FileCard(
          item: item,
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
        );
      },
    );
    if (onRefresh == null) return grid;
    return RefreshIndicator(onRefresh: onRefresh!, child: grid);
  }
}

class _FileCard extends StatelessWidget {
  const _FileCard({
    required this.item,
    required this.onTap,
    required this.onLongPress,
    required this.selectionMode,
    required this.selected,
    required this.favorited,
    this.onToggleFavorite,
  });

  final FileItem item;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool selectionMode;
  final bool selected;
  final bool favorited;
  final VoidCallback? onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
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
                  Icon(
                    fileIconOf(item),
                    size: 36,
                    color: fileIconColorOf(context, item),
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
