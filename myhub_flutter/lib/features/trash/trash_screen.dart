import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/models/trash_item.dart';
import 'package:myhub_flutter/features/trash/providers/trash_provider.dart';
import 'package:myhub_flutter/shared/utils/format.dart';

/// 回收站页（pushed outside the navigation shell）。
/// 左滑还原，右滑彻底删除（二次确认），顶栏清空。
class TrashScreen extends ConsumerWidget {
  const TrashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final itemsAsync = ref.watch(trashListProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('回收站'),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.trash2, size: 18),
            tooltip: '清空回收站',
            onPressed: () => _confirmClear(context, ref),
          ),
        ],
      ),
      body: itemsAsync.when(
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
                  color: theme.colorScheme.error,
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: () => ref.read(trashListProvider.notifier).refresh(),
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
                    LucideIcons.trash2,
                    size: 40,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '回收站为空',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () => ref.read(trashListProvider.notifier).refresh(),
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) =>
                  _TrashRow(item: items[index]),
            ),
          );
        },
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空回收站'),
        content: const Text('所有文件将被彻底删除，不可恢复。确定清空吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ref.read(trashListProvider.notifier).clear();
    }
  }
}

class _TrashRow extends ConsumerWidget {
  const _TrashRow({required this.item});

  final TrashItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final notifier = ref.read(trashListProvider.notifier);

    return Dismissible(
      key: ValueKey('trash-${item.id}'),
      // 左滑（endToStart）彻底删除需确认；右滑还原直接执行
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.endToStart) {
          return showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('彻底删除'),
              content: Text('「${item.originalPath}」将被永久删除，不可恢复。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('删除'),
                ),
              ],
            ),
          );
        }
        return true;
      },
      onDismissed: (direction) async {
        try {
          if (direction == DismissDirection.endToStart) {
            await notifier.purge(item.id);
          } else {
            await notifier.restore(item.id);
          }
        } catch (e) {
          await notifier.refresh();
          if (context.mounted) {
            ScaffoldMessenger.of(context)
              ..clearSnackBars()
              ..showSnackBar(SnackBar(content: Text('操作失败：$e')));
          }
        }
      },
      background: Container(
        color: theme.colorScheme.primary,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20),
        child: const Icon(LucideIcons.undo2, color: Colors.white, size: 20),
      ),
      secondaryBackground: Container(
        color: theme.colorScheme.error,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(LucideIcons.trash2, color: Colors.white, size: 20),
      ),
      child: ListTile(
        dense: true,
        leading: Icon(
          LucideIcons.file,
          size: 20,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        title: Text(
          item.originalPath.split('/').last,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall,
        ),
        subtitle: Text(
          '${item.originalPath} · ${formatBytes(item.size)} · ${formatModTime(item.deletedAt)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 11,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
