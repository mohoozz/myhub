import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/api/feed_api.dart';
import 'package:myhub_flutter/core/models/feed.dart';

/// 动态列表状态：分页数据 + 加载标记。
class FeedListState {
  const FeedListState({
    this.items = const [],
    this.cursorId = 0,
    this.hasMore = true,
    this.loading = false,
    this.loadingMore = false,
  });

  final List<FeedItem> items;
  final int cursorId;
  final bool hasMore;
  final bool loading;
  final bool loadingMore;

  FeedListState copyWith({
    List<FeedItem>? items,
    int? cursorId,
    bool? hasMore,
    bool? loading,
    bool? loadingMore,
  }) {
    return FeedListState(
      items: items ?? this.items,
      cursorId: cursorId ?? this.cursorId,
      hasMore: hasMore ?? this.hasMore,
      loading: loading ?? this.loading,
      loadingMore: loadingMore ?? this.loadingMore,
    );
  }
}

/// 动态数据管理：列表分页（无限滚动）、下拉刷新、全部已读。
final feedListProvider = NotifierProvider<FeedListNotifier, FeedListState>(
  FeedListNotifier.new,
);

class FeedListNotifier extends Notifier<FeedListState> {
  FeedApi get _api => ref.read(feedApiProvider);

  @override
  FeedListState build() {
    // 初始状态：空列表，首次进入由屏幕调用 refresh() 拉取。
    return const FeedListState();
  }

  /// 下拉刷新 / 首次加载：拉取最新一页。
  Future<void> refresh() async {
    if (state.loading) return;
    state = state.copyWith(loading: true);
    try {
      final page = await _api.listFeed(limit: 20);
      state = FeedListState(
        items: page.items,
        cursorId: page.cursorId,
        hasMore: page.hasMore,
        loading: false,
      );
    } catch (_) {
      state = state.copyWith(loading: false);
      rethrow;
    }
  }

  /// 触底加载更多：以当前最早条目 id 作为游标继续拉取。
  Future<void> loadMore() async {
    if (state.loadingMore || !state.hasMore || state.items.isEmpty) return;
    state = state.copyWith(loadingMore: true);
    try {
      final before = state.items.last.id;
      final page = await _api.listFeed(before: before, limit: 20);
      state = state.copyWith(
        items: [...state.items, ...page.items],
        hasMore: page.hasMore,
        loadingMore: false,
      );
    } catch (_) {
      state = state.copyWith(loadingMore: false);
      rethrow;
    }
  }

  /// 全部标为已读。
  Future<void> markAllRead() async {
    await _api.markAllRead();
    state = state.copyWith(cursorId: _maxItemId(state.items));
  }

  int _maxItemId(List<FeedItem> items) =>
      items.isEmpty ? 0 : items.first.id;
}

/// 已读游标（"已看到此处"锚点 id），首次进入时从后端读取。
final feedCursorProvider = FutureProvider<int>(
  (ref) => ref.read(feedApiProvider).getCursor(),
);

/// 稍后观看列表（含关联动态详情）。
final watchLaterProvider = FutureProvider<List<WatchLater>>(
  (ref) => ref.read(feedApiProvider).listWatchLater(),
);

/// 稍后观看数量（用于顶栏角标）。
final watchLaterCountProvider = Provider<int>((ref) {
  final list = ref.watch(watchLaterProvider).valueOrNull;
  return list?.length ?? 0;
});

/// 订阅源列表。
final feedSubscriptionsProvider = FutureProvider<List<FeedSubscription>>(
  (ref) => ref.read(feedApiProvider).listSubscriptions(),
);
