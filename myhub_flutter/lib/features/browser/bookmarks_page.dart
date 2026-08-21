import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:myhub_flutter/features/browser/browser_provider.dart';
import 'package:myhub_flutter/features/browser/widgets/shortcut_dialogs.dart'
    show showBookmarkDialog;

/// 书签管理页（F-603）：列表 + 搜索 + 编辑（标题/URL）+ 删除。
class BookmarksPage extends ConsumerStatefulWidget {
  const BookmarksPage({super.key});

  @override
  ConsumerState<BookmarksPage> createState() => _BookmarksPageState();
}

class _BookmarksPageState extends ConsumerState<BookmarksPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final bookmarksAsync = ref.watch(bookmarksProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('书签'),
        actions: [
          IconButton(
            onPressed: _addBookmark,
            icon: const Icon(LucideIcons.plus),
            tooltip: '添加书签',
          ),
        ],
      ),
      body: Column(
        children: [
          // 搜索框
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              onChanged: (v) => setState(() => _query = v.trim()),
              decoration: InputDecoration(
                hintText: '搜索书签',
                prefixIcon: const Icon(LucideIcons.search, size: 18),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
          Expanded(
            child: bookmarksAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, _) =>
                  _ErrorState(onRetry: () => ref.invalidate(bookmarksProvider)),
              data: (items) {
                final filtered = _query.isEmpty
                    ? items
                    : items
                          .where(
                            (b) =>
                                b.title.contains(_query) ||
                                b.url.contains(_query),
                          )
                          .toList();
                if (filtered.isEmpty) {
                  return const Center(child: Text('暂无书签'));
                }
                return ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, index) =>
                      _BookmarkTile(item: filtered[index]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _addBookmark() {
    showBookmarkDialog(
      context,
      title: '添加书签',
      onSave: (title, url) async {
        await ref.read(bookmarksNotifierProvider.notifier).add(title, url);
      },
    );
  }
}

class _BookmarkTile extends ConsumerWidget {
  const _BookmarkTile({required this.item});

  final BookmarkItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return ListTile(
      leading: _favicon(colorScheme),
      title: Text(
        item.title.isEmpty ? item.host : item.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: colorScheme.onSurface,
        ),
      ),
      subtitle: Text(
        item.url,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: PopupMenuButton<String>(
        icon: const Icon(LucideIcons.moreVertical, size: 18),
        onSelected: (value) {
          switch (value) {
            case 'edit':
              showBookmarkDialog(
                context,
                title: '编辑书签',
                initialTitle: item.title,
                initialUrl: item.url,
                onSave: (title, url) async {
                  await ref
                      .read(bookmarksNotifierProvider.notifier)
                      .update(item.id, title: title, url: url);
                },
              );
            case 'delete':
              unawaited(
                ref.read(bookmarksNotifierProvider.notifier).remove(item.id),
              );
          }
        },
        itemBuilder: (context) => [
          const PopupMenuItem(value: 'edit', child: Text('编辑')),
          const PopupMenuItem(value: 'delete', child: Text('删除')),
        ],
      ),
    );
  }

  Widget _favicon(ColorScheme colorScheme) {
    if (item.favicon.isNotEmpty) {
      return Image.network(
        item.favicon,
        width: 20,
        height: 20,
        errorBuilder: (_, __, ___) => Icon(
          LucideIcons.globe,
          size: 20,
          color: colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Icon(
      LucideIcons.globe,
      size: 20,
      color: colorScheme.onSurfaceVariant,
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.wifiOff,
            size: 32,
            color: colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
