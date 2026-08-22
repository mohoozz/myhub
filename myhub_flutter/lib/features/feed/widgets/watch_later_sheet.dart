import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/api/feed_api.dart';
import 'package:myhub_flutter/core/models/feed.dart';
import 'package:myhub_flutter/features/feed/providers/feed_provider.dart';
import 'package:myhub_flutter/shared/utils/top_snack_bar.dart';

/// 稍后观看列表（底部抽屉）。
///
/// 由顶栏书签角标点击唤起；支持单条移除与跳转原站播放。
class WatchLaterSheet extends ConsumerWidget {
  const WatchLaterSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(watchLaterProvider);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Text(
                  '稍后观看',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${async.valueOrNull?.length ?? 0} 项',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: async.when(
              loading: () => const SizedBox(
                height: 160,
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
              error: (err, _) => Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '加载失败：$err',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
              data: (list) {
                if (list.isEmpty) {
                  return SizedBox(
                    height: 160,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            LucideIcons.bookmark,
                            size: 32,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '还没有稍后观看的内容',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                return ListView.separated(
                  shrinkWrap: true,
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final w = list[index];
                    return _WatchLaterTile(
                      entry: w,
                      onRemove: () => _remove(context, ref, w),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _remove(BuildContext context, WidgetRef ref, WatchLater w) async {
    final api = ref.read(feedApiProvider);
    try {
      await api.removeWatchLater(w.platform, w.contentId);
      ref.invalidate(watchLaterProvider);
      if (context.mounted) showTopSnackBar(context, '已移出稍后观看');
    } catch (e) {
      if (context.mounted) showTopSnackBar(context, '操作失败：$e');
    }
  }
}

class _WatchLaterTile extends StatelessWidget {
  const _WatchLaterTile({required this.entry, required this.onRemove});

  final WatchLater entry;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = entry.item;
    final title = item == null
        ? entry.contentId
        : (item.title.isEmpty ? item.description : item.title);

    return ListTile(
      leading: item?.cover.isNotEmpty == true
          ? ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.network(
                item!.cover,
                width: 48,
                height: 36,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const Icon(
                  LucideIcons.image,
                  size: 20,
                ),
              ),
            )
          : const Icon(LucideIcons.bookmark, size: 20),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: item?.author.isNotEmpty == true
          ? Text(
              item!.author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall,
            )
          : null,
      trailing: IconButton(
        icon: const Icon(LucideIcons.x, size: 16),
        onPressed: onRemove,
        tooltip: '移出稍后观看',
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
