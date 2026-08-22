import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/api/feed_api.dart';
import 'package:myhub_flutter/core/models/feed.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 动态列表状态：分页数据 + 加载标记 + 当前阅读索引。
class FeedListState {
  const FeedListState({
    this.items = const [],
    this.cursorId = 0,
    this.hasMore = true,
    this.loading = false,
    this.loadingMore = false,
    this.currentIndex = 0,
  });

  final List<FeedItem> items;
  final int cursorId;
  final bool hasMore;
  final bool loading;
  final bool loadingMore;

  /// 当前正在阅读的动态下标（0 起），用于单条沉浸式浏览。
  final int currentIndex;

  FeedListState copyWith({
    List<FeedItem>? items,
    int? cursorId,
    bool? hasMore,
    bool? loading,
    bool? loadingMore,
    int? currentIndex,
  }) {
    return FeedListState(
      items: items ?? this.items,
      cursorId: cursorId ?? this.cursorId,
      hasMore: hasMore ?? this.hasMore,
      loading: loading ?? this.loading,
      loadingMore: loadingMore ?? this.loadingMore,
      currentIndex: currentIndex ?? this.currentIndex,
    );
  }
}

/// 动态数据管理：列表分页（无限滚动）、下拉刷新、全部已读。
final feedListProvider = NotifierProvider<FeedListNotifier, FeedListState>(
  FeedListNotifier.new,
);

class FeedListNotifier extends Notifier<FeedListState> {
  static const _kLastReadIdKey = 'feed.last_read_id';

  FeedApi get _api => ref.read(feedApiProvider);

  @override
  FeedListState build() {
    // 初始状态：空列表，首次进入由屏幕调用 refresh() 拉取。
    return const FeedListState();
  }

  /// 下拉刷新 / 首次加载：拉取最新一页，并恢复到上次阅读的动态。
  Future<void> refresh() async {
    if (state.loading) return;
    state = state.copyWith(loading: true);
    try {
      final page = await _api.listFeed(limit: 20);
      // 恢复阅读进度：以稳定的 item id 定位上次阅读的动态（找不到则回到最新）。
      final lastReadId = await _loadLastReadId();
      var index = 0;
      if (lastReadId > 0) {
        final i = page.items.indexWhere((it) => it.id == lastReadId);
        if (i >= 0) index = i;
      }
      state = FeedListState(
        items: page.items,
        cursorId: page.cursorId,
        hasMore: page.hasMore,
        loading: false,
        currentIndex: index,
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

  /// 切换当前阅读的动态并持久化进度（记录稳定 item id）。
  Future<void> setCurrentIndex(int index) async {
    if (index == state.currentIndex) return;
    state = state.copyWith(currentIndex: index);
    if (index >= 0 && index < state.items.length) {
      await _saveLastReadId(state.items[index].id);
    }
  }

  Future<int> _loadLastReadId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_kLastReadIdKey) ?? 0;
  }

  Future<void> _saveLastReadId(int id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kLastReadIdKey, id);
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
