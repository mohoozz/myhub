import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:myhub_flutter/features/browser/browser_provider.dart';

/// 历史管理页（F-603）：按日分组、搜索、单条删除、清空。
class HistoryPage extends ConsumerStatefulWidget {
  const HistoryPage({super.key});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<HistoryPage> {
  String _query = '';
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // 首次加载
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(historyProvider.notifier).refresh();
    });
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      unawaited(ref.read(historyProvider.notifier).loadMore());
    }
  }

  @override
  Widget build(BuildContext context) {
    final historyAsync = ref.watch(historyProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('历史记录'),
        actions: [
          IconButton(
            onPressed: _confirmClear,
            icon: const Icon(LucideIcons.trash2),
            tooltip: '清空历史',
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              onChanged: (v) => setState(() => _query = v.trim()),
              decoration: InputDecoration(
                hintText: '搜索历史',
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
            child: historyAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, _) => _ErrorState(
                onRetry: () => ref.read(historyProvider.notifier).refresh(),
              ),
              data: (items) {
                final filtered = _query.isEmpty
                    ? items
                    : items
                          .where(
                            (h) =>
                                h.title.contains(_query) ||
                                h.url.contains(_query),
                          )
                          .toList();
                if (filtered.isEmpty) {
                  return const Center(child: Text('暂无历史记录'));
                }
                return _buildGroupedList(filtered);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupedList(List<HistoryItem> items) {
    // 按日分组（yyyy-MM-dd），保持原有降序
    final grouped = <String, List<HistoryItem>>{};
    for (final item in items) {
      final key = DateFormat('yyyy-MM-dd').format(item.visitedAt);
      grouped.putIfAbsent(key, () => []).add(item);
    }

    final entries = grouped.entries.toList();
    return ListView.builder(
      controller: _scrollController,
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return _HistoryGroup(dateLabel: entry.key, items: entry.value);
      },
    );
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(LucideIcons.trash2),
        title: const Text('清空历史记录'),
        content: const Text('确定清空全部浏览历史吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(historyProvider.notifier).clear();
    }
  }
}

/// 按日分组的历史条目块。
class _HistoryGroup extends ConsumerWidget {
  const _HistoryGroup({required this.dateLabel, required this.items});

  final String dateLabel;
  final List<HistoryItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            _formatDateLabel(dateLabel),
            style: theme.textTheme.labelMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        for (final item in items) _HistoryTile(item: item),
      ],
    );
  }

  String _formatDateLabel(String ymd) {
    final now = DateTime.now();
    final today = DateFormat('yyyy-MM-dd').format(now);
    final yesterday = DateFormat(
      'yyyy-MM-dd',
    ).format(now.subtract(const Duration(days: 1)));
    if (ymd == today) return '今天';
    if (ymd == yesterday) return '昨天';
    return ymd;
  }
}

class _HistoryTile extends ConsumerWidget {
  const _HistoryTile({required this.item});

  final HistoryItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return ListTile(
      dense: true,
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
      trailing: IconButton(
        onPressed: () =>
            unawaited(ref.read(historyProvider.notifier).remove(item.id)),
        icon: const Icon(LucideIcons.x, size: 16),
        visualDensity: VisualDensity.compact,
        tooltip: '删除',
      ),
    );
  }

  Widget _favicon(ColorScheme colorScheme) {
    if (item.favicon.isNotEmpty) {
      return Image.network(
        item.favicon,
        width: 18,
        height: 18,
        errorBuilder: (_, __, ___) => Icon(
          LucideIcons.globe,
          size: 18,
          color: colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Icon(
      LucideIcons.globe,
      size: 18,
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
