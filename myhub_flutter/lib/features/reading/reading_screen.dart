import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/models/reading_progress.dart';
import 'package:myhub_flutter/features/reading/providers/reading_provider.dart';
import 'package:myhub_flutter/shared/utils/open_media.dart';
import 'package:myhub_flutter/shared/widgets/reading_card.dart';

/// "正在阅读"首页：全部未读完进度卡片网格，点击续读，长按标记已读完。
class ReadingScreen extends ConsumerWidget {
  const ReadingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final progressAsync = ref.watch(readingListProvider);

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    '正在阅读',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${progressAsync.valueOrNull?.length ?? 0} 项',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(LucideIcons.rotateCw, size: 16),
                    onPressed: () =>
                        ref.read(readingListProvider.notifier).refresh(),
                    tooltip: '刷新',
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () =>
                      ref.read(readingListProvider.notifier).refresh(),
                  child: progressAsync.when(
                    loading: () => const Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                    error: (err, _) => _ErrorView(
                      error: err,
                      onRetry: () =>
                          ref.read(readingListProvider.notifier).refresh(),
                    ),
                    data: (items) => items.isEmpty
                        ? const _EmptyView()
                        : _ProgressGrid(items: items),
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

class _ProgressGrid extends ConsumerWidget {
  const _ProgressGrid({required this.items});

  final List<ReadingProgress> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GridView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        childAspectRatio: 0.98,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final p = items[index];
        return ReadingCard(
          progress: p,
          onTap: () => _open(context, ref, p),
          onLongPress: () => _showActions(context, ref, p),
        );
      },
    );
  }

  /// 进入对应阅读器/播放器（进度由各页面自行恢复），返回后刷新列表。
  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    ReadingProgress p,
  ) async {
    await openMediaItem(
      context,
      ref,
      sourceId: p.sourceId,
      filePath: p.filePath,
      mediaType: p.mediaType,
    );
    if (!context.mounted) return;
    await ref.read(readingListProvider.notifier).refresh();
  }

  void _showActions(BuildContext context, WidgetRef ref, ReadingProgress p) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListTile(
          leading: const Icon(LucideIcons.check, size: 18),
          title: const Text('标记为已读完'),
          onTap: () async {
            Navigator.of(sheetContext).pop();
            try {
              await ref
                  .read(readingListProvider.notifier)
                  .markFinished(p.sourceId, p.filePath);
            } catch (e) {
              if (!context.mounted) return;
              ScaffoldMessenger.of(context)
                ..clearSnackBars()
                ..showSnackBar(SnackBar(content: Text('操作失败：$e')));
            }
          },
        ),
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    // 空状态也保持可滚动，保证下拉刷新可用
    return ListView(
      children: [
        const SizedBox(height: 120),
        Icon(LucideIcons.bookOpen, size: 40, color: colorScheme.onSurfaceVariant),
        const SizedBox(height: 10),
        Text(
          '还没有阅读记录，去浏览页看看吧',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      children: [
        const SizedBox(height: 120),
        Center(
          child: Column(
            children: [
              Text(
                '加载失败：$error',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
            ],
          ),
        ),
      ],
    );
  }
}
