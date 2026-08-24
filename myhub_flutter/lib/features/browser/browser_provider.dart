import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/api/browser_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 单个浏览器标签的运行时状态。
///
/// 注意：不含 [InAppWebViewController]（原生句柄不宜跨 widget 生命周期
/// 共享），仅承载"该标签当前在哪个 URL / 什么标题"这类可序列化状态，
/// 供地址栏、标签条与历史上报读取。
@immutable
class BrowserTabState {
  const BrowserTabState({
    required this.id,
    this.url = '',
    this.title = '',
    this.faviconUrl = '',
    this.loading = false,
    this.incognito = false,
    this.navSeq = 0,
  });

  final int id;

  /// 当前 URL（起始页为 '' 表示 new tab）。
  final String url;

  /// 页面标题（空则回退域名）。
  final String title;

  /// favicon 地址。
  final String faviconUrl;

  /// 是否正在加载。
  final bool loading;

  /// 是否无痕（不记录历史）。
  final bool incognito;

  /// 外部导航命令序号：仅地址栏提交等显式导航递增；页面内跳转
  /// （点击链接）URL 变化但不递增，[BrowserView] 据此区分是否需
  /// 主动 loadUrl，避免重复加载打断 WebView 导航历史栈。
  final int navSeq;

  BrowserTabState copyWith({
    String? url,
    String? title,
    String? faviconUrl,
    bool? loading,
    bool? incognito,
    int? navSeq,
  }) {
    return BrowserTabState(
      id: id,
      url: url ?? this.url,
      title: title ?? this.title,
      faviconUrl: faviconUrl ?? this.faviconUrl,
      loading: loading ?? this.loading,
      incognito: incognito ?? this.incognito,
      navSeq: navSeq ?? this.navSeq,
    );
  }

  /// 序列化（会话持久化用；loading/navSeq 为运行时字段，不落盘）。
  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'title': title,
        'favicon': faviconUrl,
        'incognito': incognito,
      };

  /// 反序列化恢复会话。
  factory BrowserTabState.fromJson(Map<String, dynamic> json) {
    return BrowserTabState(
      id: json['id'] as int? ?? 0,
      url: json['url'] as String? ?? '',
      title: json['title'] as String? ?? '',
      faviconUrl: json['favicon'] as String? ?? '',
      incognito: json['incognito'] as bool? ?? false,
    );
  }

  /// 是否为新建标签（未加载任何页面）。
  bool get isNewTab => url.isEmpty;

  /// 当前页域名（无 host 返回空串）。
  String get host {
    final uri = Uri.tryParse(url);
    return uri?.host ?? '';
  }
}

/// 标签会话全局状态：多个标签 + 当前激活标签索引。
///
/// 13.3 阶段建立会话骨架（支持 [target=_blank]/[window.open] 开新标签、
/// 键盘快捷键 Ctrl+T/W、无痕标签跳过历史），
/// 13.4 补充 Chrome 风格标签条与 iOS 标签管理页，以及"关闭其他/全部"。
///
/// 13.6 会话持久化：标签列表（跳过无痕）与激活标签写入 SharedPreferences，
/// 启动时恢复上次打开的页面，避免每次打开 app 都从零开始。
class BrowserTabsNotifier extends Notifier<List<BrowserTabState>> {
  /// 会话持久化 key。
  static const _kSessionKey = 'browser_tabs_session';

  int _nextId = 1;

  /// 恢复完成前用户是否已操作（若已操作则放弃恢复，避免覆盖）。
  bool _dirty = false;

  Timer? _saveDebounce;

  @override
  List<BrowserTabState> build() {
    // 状态变化即防抖保存会话；Provider 销毁（应用退出）时兜底 flush。
    listenSelf((_, __) => _scheduleSave());
    ref.onDispose(_flushSave);
    // 启动后异步恢复上次会话（恢复期间用户已操作则放弃）。
    Future.microtask(_restore);
    return [BrowserTabState(id: _nextId++)];
  }

  /// 当前激活标签（索引越界回退到末位）。
  BrowserTabState? get active => state.isEmpty ? null : state[_activeIndexSafe];

  int get _activeIndexSafe {
    final idx = ref.read(activeBrowserTabIndexProvider);
    return (idx >= 0 && idx < state.length) ? idx : state.length - 1;
  }

  // ---------- 会话持久化 ----------

  /// 恢复上次关闭时打开的标签（跳过无痕标签）。
  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSessionKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final tabs = [
        for (final e in data['tabs'] as List<dynamic>? ?? const <dynamic>[])
          if (e is Map<String, dynamic>) BrowserTabState.fromJson(e),
      ];
      if (_dirty || tabs.isEmpty) return;
      var maxId = 0;
      for (final t in tabs) {
        if (t.id > maxId) maxId = t.id;
      }
      _nextId = maxId + 1;
      state = tabs;
      final activeId = data['activeId'] as int?;
      final idx =
          activeId == null ? 0 : tabs.indexWhere((t) => t.id == activeId);
      ref.read(activeBrowserTabIndexProvider.notifier).state = idx >= 0 ? idx : 0;
    } catch (_) {
      // 会话数据损坏：静默放弃，从新标签开始
    }
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), _flushSave);
  }

  Future<void> _flushSave() async {
    _saveDebounce?.cancel();
    _saveDebounce = null;
    // 无痕标签不落盘；激活标签为无痕时回退到最后一个保留标签
    final tabs = state.where((t) => !t.incognito).toList();
    final activeTab = state.isEmpty ? null : state[_activeIndexSafe];
    final activeId = activeTab?.incognito == true
        ? (tabs.isEmpty ? null : tabs.last.id)
        : activeTab?.id;
    final payload = jsonEncode({
      'version': 1,
      'tabs': [for (final t in tabs) t.toJson()],
      'activeId': activeId,
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSessionKey, payload);
  }

  // ---------- 标签操作 ----------

  /// 新建标签并激活。
  BrowserTabState newTab({bool incognito = false}) {
    _dirty = true;
    final tab = BrowserTabState(id: _nextId++, incognito: incognito);
    state = [...state, tab];
    ref.read(activeBrowserTabIndexProvider.notifier).state = state.length - 1;
    return tab;
  }

  /// 关闭指定 id 的标签；若关闭的是激活标签则切换相邻标签。
  void closeTab(int id) {
    _dirty = true;
    final idx = state.indexWhere((t) => t.id == id);
    if (idx < 0) return;
    final next = [...state]..removeAt(idx);
    if (next.isEmpty) {
      next.add(BrowserTabState(id: _nextId++));
    }
    final cur = _activeIndexSafe;
    int newActive;
    if (cur >= next.length) {
      newActive = next.length - 1;
    } else if (cur > idx) {
      newActive = cur - 1;
    } else if (cur == idx) {
      newActive = idx < next.length ? idx : next.length - 1;
    } else {
      newActive = cur;
    }
    state = next;
    ref.read(activeBrowserTabIndexProvider.notifier).state = newActive;
  }

  /// 切换激活标签。
  void activate(int id) {
    _dirty = true;
    final idx = state.indexWhere((t) => t.id == id);
    if (idx >= 0) {
      ref.read(activeBrowserTabIndexProvider.notifier).state = idx;
    }
  }

  /// 关闭除 [keepId] 之外的所有标签。
  void closeOthers(int keepId) {
    _dirty = true;
    final idx = state.indexWhere((t) => t.id == keepId);
    if (idx < 0) return;
    final next = [state[idx]];
    state = next;
    ref.read(activeBrowserTabIndexProvider.notifier).state = 0;
  }

  /// 关闭全部标签，并创建一个新的空白标签。
  void closeAll() {
    _dirty = true;
    state = [BrowserTabState(id: _nextId++)];
    ref.read(activeBrowserTabIndexProvider.notifier).state = 0;
  }

  /// 更新某标签的运行时状态（URL / 标题 / favicon / loading）。
  void update(int id, BrowserTabState Function(BrowserTabState) fn) {
    _dirty = true;
    final idx = state.indexWhere((t) => t.id == id);
    if (idx < 0) return;
    final next = [...state];
    next[idx] = fn(next[idx]);
    state = next;
  }
}

/// 标签会话全局持有：切页签不销毁（13.4 依赖）。
final browserTabsProvider =
    NotifierProvider<BrowserTabsNotifier, List<BrowserTabState>>(
      BrowserTabsNotifier.new,
    );

/// 当前激活标签索引（独立 state，切换时触发依赖重建）。
final activeBrowserTabIndexProvider = StateProvider<int>((ref) => 0);

/// 当前激活标签。
final activeBrowserTabProvider = Provider<BrowserTabState?>((ref) {
  final tabs = ref.watch(browserTabsProvider);
  final idx = ref.watch(activeBrowserTabIndexProvider);
  return (idx >= 0 && idx < tabs.length) ? tabs[idx] : null;
});

/// 历史上报节流器：页面加载完成（onLoadStop）后收集，按时间窗口
/// 批量 POST /api/browser/history，避免频繁请求。
///
/// 无痕标签、起始页（about:blank / 空 URL）跳过。
class HistoryReporter {
  HistoryReporter(this._ref, {this.flushInterval = const Duration(seconds: 3)});

  final Ref _ref;
  final Duration flushInterval;

  final List<Map<String, dynamic>> _pending = [];
  bool _flushing = false;

  /// 记录一次页面访问（节流批量上报）。
  void report({
    required String url,
    required String title,
    String favicon = '',
  }) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return;
    }
    _pending.add({'title': title, 'url': url, 'favicon': favicon});
    _scheduleFlush();
  }

  void _scheduleFlush() {
    if (_flushing) return;
    _flushing = true;
    Future<void>.delayed(flushInterval, _flush).ignore();
  }

  Future<void> _flush() async {
    _flushing = false;
    if (_pending.isEmpty) return;
    final items = [..._pending];
    _pending.clear();
    try {
      await _ref.read(browserApiProvider).reportHistory(items);
    } catch (_) {
      // 历史上报失败静默：不打断浏览；下一轮 flush 不会重发已丢弃条目
      // （历史丢失可接受，F-601 仅要求节流上报）。
    }
  }

  /// 应用退出/标签关闭前兜底刷出剩余条目。
  Future<void> flushNow() => _flush();
}

final historyReporterProvider = Provider<HistoryReporter>((ref) {
  final reporter = HistoryReporter(ref);
  ref.onDispose(reporter.flushNow);
  return reporter;
});

// ---------- 快捷入口（F-602） ----------

/// 快捷入口条目。
@immutable
class ShortcutItem {
  const ShortcutItem({
    required this.id,
    required this.title,
    required this.url,
    required this.sortOrder,
  });

  final int id;
  final String title;
  final String url;
  final int sortOrder;

  /// 从后端返回的 JSON 构造。
  factory ShortcutItem.fromJson(Map<String, dynamic> json) {
    return ShortcutItem(
      id: json['id'] as int,
      title: json['title'] as String? ?? '',
      url: json['url'] as String? ?? '',
      sortOrder: json['sort_order'] as int? ?? 0,
    );
  }

  /// 当前页域名。
  String get host {
    final uri = Uri.tryParse(url);
    return uri?.host ?? '';
  }

  /// favicon 服务地址（Google s2，公开可用）。
  String get faviconUrl =>
      'https://www.google.com/s2/favicons?domain=$host&sz=64';
}

/// 快捷入口列表异步状态（AsyncValue 承载加载/错误/数据）。
final shortcutsProvider = FutureProvider<List<ShortcutItem>>((ref) async {
  final list = await ref.watch(browserApiProvider).listShortcuts();
  return list.map(ShortcutItem.fromJson).toList();
});

/// 快捷入口写操作：增删改重排，操作后刷新列表。
class ShortcutsNotifier extends Notifier<AsyncValue<List<ShortcutItem>>> {
  @override
  AsyncValue<List<ShortcutItem>> build() => const AsyncValue.loading();

  Future<void> _reload() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      final list = await ref.read(browserApiProvider).listShortcuts();
      return list.map(ShortcutItem.fromJson).toList();
    });
  }

  /// 添加（URL 唯一，重复抛 409）。
  Future<void> add(String title, String url) async {
    await ref.read(browserApiProvider).addShortcut(title, url);
    await _reload();
  }

  /// 更新标题 / URL。
  Future<void> update(int id, {String? title, String? url}) async {
    await ref
        .read(browserApiProvider)
        .updateShortcut(id: id, title: title, url: url);
    await _reload();
  }

  /// 删除。
  Future<void> remove(int id) async {
    await ref.read(browserApiProvider).removeShortcut(id);
    await _reload();
  }

  /// 拖拽重排（ids 顺序即新 sort_order）。
  Future<void> reorder(List<int> ids) async {
    await ref.read(browserApiProvider).reorderShortcuts(ids);
    await _reload();
  }
}

final shortcutsNotifierProvider =
    NotifierProvider<ShortcutsNotifier, AsyncValue<List<ShortcutItem>>>(
      ShortcutsNotifier.new,
    );

// ---------- 书签（F-603） ----------

/// 书签条目。
@immutable
class BookmarkItem {
  const BookmarkItem({
    required this.id,
    required this.title,
    required this.url,
    required this.favicon,
  });

  final int id;
  final String title;
  final String url;
  final String favicon;

  factory BookmarkItem.fromJson(Map<String, dynamic> json) {
    return BookmarkItem(
      id: json['id'] as int,
      title: json['title'] as String? ?? '',
      url: json['url'] as String? ?? '',
      favicon: json['favicon'] as String? ?? '',
    );
  }

  /// 当前页域名。
  String get host {
    final uri = Uri.tryParse(url);
    return uri?.host ?? '';
  }
}

/// 书签列表异步状态。
final bookmarksProvider = FutureProvider<List<BookmarkItem>>((ref) async {
  final list = await ref.watch(browserApiProvider).listBookmarks();
  return list
      .map((e) => BookmarkItem.fromJson(e as Map<String, dynamic>))
      .toList();
});

/// 书签写操作：添加/更新/删除，操作后刷新列表。
class BookmarksNotifier extends Notifier<AsyncValue<List<BookmarkItem>>> {
  @override
  AsyncValue<List<BookmarkItem>> build() => const AsyncValue.loading();

  Future<void> _reload() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      final list = await ref.read(browserApiProvider).listBookmarks();
      return list
          .map((e) => BookmarkItem.fromJson(e as Map<String, dynamic>))
          .toList();
    });
  }

  /// 添加（URL 唯一，幂等）。
  Future<void> add(String title, String url, {String favicon = ''}) async {
    await ref
        .read(browserApiProvider)
        .addBookmark(title, url, favicon: favicon);
    await _reload();
  }

  /// 更新标题 / URL。
  Future<void> update(int id, {String? title, String? url}) async {
    await ref
        .read(browserApiProvider)
        .updateBookmark(id: id, title: title, url: url);
    await _reload();
  }

  /// 删除（按 id）。
  Future<void> remove(int id) async {
    await ref.read(browserApiProvider).removeBookmark(id: id);
    await _reload();
  }
}

final bookmarksNotifierProvider =
    NotifierProvider<BookmarksNotifier, AsyncValue<List<BookmarkItem>>>(
      BookmarksNotifier.new,
    );

// ---------- 历史（F-603） ----------

/// 历史条目。
@immutable
class HistoryItem {
  const HistoryItem({
    required this.id,
    required this.title,
    required this.url,
    required this.favicon,
    required this.visitedAt,
  });

  final int id;
  final String title;
  final String url;
  final String favicon;
  final DateTime visitedAt;

  factory HistoryItem.fromJson(Map<String, dynamic> json) {
    return HistoryItem(
      id: json['id'] as int,
      title: json['title'] as String? ?? '',
      url: json['url'] as String? ?? '',
      favicon: json['favicon'] as String? ?? '',
      visitedAt:
          DateTime.tryParse(json['visited_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  /// 当前页域名。
  String get host {
    final uri = Uri.tryParse(url);
    return uri?.host ?? '';
  }
}

/// 历史列表状态（分页加载）。
class HistoryNotifier extends Notifier<AsyncValue<List<HistoryItem>>> {
  @override
  AsyncValue<List<HistoryItem>> build() => const AsyncValue.loading();

  String? _nextCursor;
  bool _hasMore = true;
  bool _loading = false;

  /// 首次加载 / 刷新。
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    _nextCursor = null;
    _hasMore = true;
    await _loadMore();
  }

  /// 加载下一页（游标分页）。
  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    _loading = true;
    final current = state.valueOrNull ?? const <HistoryItem>[];
    state = AsyncValue.data(current);
    try {
      final data = await ref
          .read(browserApiProvider)
          .listHistory(cursor: _nextCursor, limit: 50);
      final list = (data['list'] as List<dynamic>? ?? const [])
          .map((e) => HistoryItem.fromJson(e as Map<String, dynamic>))
          .toList();
      final nextCursor = data['next_cursor'] as String? ?? '';
      _nextCursor = nextCursor.isEmpty ? null : nextCursor;
      _hasMore = nextCursor.isNotEmpty;
      state = AsyncValue.data([...current, ...list]);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    } finally {
      _loading = false;
    }
  }

  /// 加载更多（供滚动到底触发）。
  Future<void> loadMore() => _loadMore();

  /// 单条删除。
  Future<void> remove(int id) async {
    await ref.read(browserApiProvider).deleteHistory(id);
    final current = state.valueOrNull ?? const <HistoryItem>[];
    state = AsyncValue.data(current.where((e) => e.id != id).toList());
  }

  /// 清空全部。
  Future<void> clear() async {
    await ref.read(browserApiProvider).clearHistory();
    state = const AsyncValue.data([]);
    _hasMore = false;
  }
}

final historyProvider =
    NotifierProvider<HistoryNotifier, AsyncValue<List<HistoryItem>>>(
      HistoryNotifier.new,
    );
