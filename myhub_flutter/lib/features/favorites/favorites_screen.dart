import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/models/favorite.dart';
import 'package:myhub_flutter/features/favorites/providers/favorite_provider.dart';
import 'package:myhub_flutter/shared/utils/format.dart';

/// 收藏页：星标文件/文件夹，网格/列表切换，点星即时取消收藏。
class FavoritesScreen extends ConsumerStatefulWidget {
  const FavoritesScreen({super.key});

  @override
  ConsumerState<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends ConsumerState<FavoritesScreen> {
  bool _grid = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final favoritesAsync = ref.watch(favoriteListProvider);

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    '我的收藏',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(LucideIcons.rotateCw, size: 16),
                    onPressed: () =>
                        ref.read(favoriteListProvider.notifier).refresh(),
                    tooltip: '刷新',
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    icon: const Icon(LucideIcons.layoutGrid, size: 16),
                    color: _grid ? colorScheme.primary : null,
                    onPressed: () => setState(() => _grid = true),
                    tooltip: '网格视图',
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    icon: const Icon(LucideIcons.list, size: 16),
                    color: !_grid ? colorScheme.primary : null,
                    onPressed: () => setState(() => _grid = false),
                    tooltip: '列表视图',
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: theme.cardTheme.color,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: favoritesAsync.when(
                    loading: () => const Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                    error: (err, _) => Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '加载失败：$err',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.error,
                            ),
                          ),
                          const SizedBox(height: 8),
                          FilledButton.tonal(
                            onPressed: () => ref
                                .read(favoriteListProvider.notifier)
                                .refresh(),
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                    data: (items) {
                      if (items.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                LucideIcons.star,
                                size: 40,
                                color: colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(height: 10),
                              Text(
                                '暂无收藏',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        );
                      }
                      return IndexedStack(
                        index: _grid ? 0 : 1,
                        children: [
                          _FavoriteGrid(items: items),
                          _FavoriteList(items: items),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

IconData _iconOf(Favorite f) {
  if (f.mediaType == 'dir') return LucideIcons.folder;
  return switch (f.mediaType) {
    'video' => LucideIcons.film,
    'audio' => LucideIcons.music,
    'novel' => LucideIcons.bookOpen,
    'comic' => LucideIcons.images,
    'image' => LucideIcons.image,
    'archive' => LucideIcons.package,
    _ => LucideIcons.file,
  };
}

class _FavoriteList extends ConsumerWidget {
  const _FavoriteList({required this.items});

  final List<Favorite> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 54),
      itemBuilder: (context, index) {
        final f = items[index];
        return InkWell(
          onTap: () => _openItem(context, f),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(
                  _iconOf(f),
                  size: 20,
                  color: f.mediaType == 'dir'
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 4,
                  child: Text(
                    f.filePath.split('/').last,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    f.mediaType == 'dir' ? '-' : formatBytes(f.size),
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                _StarButton(favorite: f),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _FavoriteGrid extends ConsumerWidget {
  const _FavoriteGrid({required this.items});

  final List<Favorite> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 140,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.95,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final f = items[index];
        return InkWell(
          onTap: () => _openItem(context, f),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.cardTheme.color,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.colorScheme.outline,
                width: 0.5,
              ),
            ),
            child: Stack(
              children: [
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _iconOf(f),
                        size: 36,
                        color: f.mediaType == 'dir'
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        f.filePath.split('/').last,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  child: _StarButton(favorite: f),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 实心星标：点击取消收藏（即时移除）。
class _StarButton extends ConsumerWidget {
  const _StarButton({required this.favorite});

  final Favorite favorite;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton(
      iconSize: 15,
      visualDensity: VisualDensity.compact,
      tooltip: '取消收藏',
      icon: Icon(LucideIcons.star, color: Theme.of(context).colorScheme.primary),
      onPressed: () => ref
          .read(favoriteListProvider.notifier)
          .remove(favorite.sourceId, favorite.filePath),
    );
  }
}

/// 点击条目：TODO(5/6 章) 按类型进入播放器/阅读器。
void _openItem(BuildContext context, Favorite f) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text('打开 ${f.filePath.split('/').last}')));
}
