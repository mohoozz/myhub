import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/api/feed_api.dart';
import 'package:myhub_flutter/core/models/feed.dart';
import 'package:myhub_flutter/features/feed/providers/feed_provider.dart';
import 'package:myhub_flutter/features/feed/widgets/feed_detail_card.dart';
import 'package:myhub_flutter/features/feed/widgets/feed_paged_viewer.dart';
import 'package:myhub_flutter/features/feed/widgets/subscriptions_sheet.dart';
import 'package:myhub_flutter/features/feed/widgets/watch_later_sheet.dart';
import 'package:myhub_flutter/shared/utils/top_snack_bar.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

/// 动态流页面（M5）：单条沉浸式垂直翻页浏览，上/下方向键、滚轮、
/// 手势、悬浮按钮均可切换，并记录阅读进度（下次进入恢复到上次阅读的动态）。
class FeedScreen extends ConsumerStatefulWidget {
  const FeedScreen({super.key});

  @override
  ConsumerState<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends ConsumerState<FeedScreen> {
  @override
  void initState() {
    super.initState();
    // 首次进入拉取列表（内部会恢复阅读进度）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(feedListProvider.notifier).refresh();
    });
  }

  /// 点击卡片：跳转原站（B站/抖音有反爬，无法内嵌播放，走系统浏览器）。
  Future<void> _openItem(FeedItem item) async {
    if (item.url.isEmpty) return;
    final uri = Uri.tryParse(item.url);
    if (uri == null) return;
    try {
      await launcher.launchUrl(
        uri,
        mode: launcher.LaunchMode.externalApplication,
      );
    } catch (e) {
      if (mounted) showTopSnackBar(context, '打开失败：$e');
    }
  }

  /// 书签点击：收录 / 取消稍后观看。
  Future<void> _toggleBookmark(FeedItem item) async {
    final api = ref.read(feedApiProvider);
    final current = ref.read(watchLaterProvider).valueOrNull ?? const [];
    final exists = current.any(
      (w) => w.platform == item.platform && w.contentId == item.contentId,
    );
    try {
      if (exists) {
        await api.removeWatchLater(item.platform, item.contentId);
        if (mounted) showTopSnackBar(context, '已移出稍后观看');
      } else {
        await api.addWatchLater(item.platform, item.contentId);
        if (mounted) showTopSnackBar(context, '已加入稍后观看');
      }
      ref.invalidate(watchLaterProvider);
    } catch (e) {
      if (mounted) showTopSnackBar(context, '操作失败：$e');
    }
  }

  /// 全部标为已读。
  Future<void> _markAllRead() async {
    try {
      await ref.read(feedListProvider.notifier).markAllRead();
      if (mounted) showTopSnackBar(context, '已全部标为已读');
    } catch (e) {
      if (mounted) showTopSnackBar(context, '操作失败：$e');
    }
  }

  /// 手动触发抓取。
  Future<void> _triggerFetch() async {
    try {
      await ref.read(feedApiProvider).fetch();
      if (mounted) showTopSnackBar(context, '已触发抓取');
      await ref.read(feedListProvider.notifier).refresh();
    } catch (e) {
      if (mounted) showTopSnackBar(context, '抓取失败：$e');
    }
  }

  void _showWatchLater() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const WatchLaterSheet(),
    );
  }

  void _showSubscriptions() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const SubscriptionsSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(feedListProvider);
    final watchLaterCount = ref.watch(watchLaterCountProvider);

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(7, 8, 7, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(theme, watchLaterCount),
              const SizedBox(height: 8),
              Expanded(child: _buildContent(theme, state)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, int watchLaterCount) {
    return Row(
      children: [
        Text(
          '动态',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const Spacer(),
        // 书签（稍后观看）图标 + 数量角标。
        IconButton(
          icon: Badge(
            isLabelVisible: watchLaterCount > 0,
            label: Text('$watchLaterCount'),
            child: const Icon(LucideIcons.bookmark, size: 16),
          ),
          onPressed: _showWatchLater,
          tooltip: '稍后观看',
          visualDensity: VisualDensity.compact,
        ),
        // 订阅源管理。
        IconButton(
          icon: const Icon(LucideIcons.rss, size: 16),
          onPressed: _showSubscriptions,
          tooltip: '订阅源管理',
          visualDensity: VisualDensity.compact,
        ),
        // 手动触发抓取。
        IconButton(
          icon: const Icon(LucideIcons.refreshCw, size: 16),
          onPressed: _triggerFetch,
          tooltip: '手动抓取',
          visualDensity: VisualDensity.compact,
        ),
        // 全部标为已读。
        IconButton(
          icon: const Icon(LucideIcons.checkCheck, size: 16),
          onPressed: _markAllRead,
          tooltip: '全部标为已读',
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }

  Widget _buildContent(ThemeData theme, FeedListState state) {
    if (state.loading && state.items.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (state.items.isEmpty) {
      return const _EmptyView();
    }

    final watchLater = ref.watch(watchLaterProvider).valueOrNull ?? const [];
    final bookmarkedKeys = {
      for (final w in watchLater) '${w.platform}|${w.contentId}',
    };

    return FeedPagedViewer(
      itemCount: state.items.length,
      initialIndex: state.currentIndex.clamp(0, state.items.length - 1),
      onIndexChanged: (index) {
        ref.read(feedListProvider.notifier).setCurrentIndex(index);
      },
      onReachEnd: () {
        ref.read(feedListProvider.notifier).loadMore();
      },
      itemBuilder: (context, index) {
        final item = state.items[index];
        return FeedDetailCard(
          item: item,
          bookmarked: bookmarkedKeys.contains(
            '${item.platform}|${item.contentId}',
          ),
          onOpen: () => _openItem(item),
          onToggleBookmark: () => _toggleBookmark(item),
        );
      },
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return ListView(
      children: [
        const SizedBox(height: 120),
        Icon(
          LucideIcons.zap,
          size: 40,
          color: colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 10),
        Text(
          '暂无动态，点击右上角「订阅源」添加或「刷新」抓取',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
