import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/models/reading_progress.dart';
import 'package:myhub_flutter/data/repositories/progress_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "正在阅读"页视图模式。
enum ReadingViewMode { grid, list }

/// "正在阅读"页视图模式（网格/列表），持久化到 SharedPreferences，
/// 重启应用后沿用上次的选择（iOS / PC 通用）。
final readingViewModeProvider =
    NotifierProvider<ReadingViewModeNotifier, ReadingViewMode>(
  ReadingViewModeNotifier.new,
);

class ReadingViewModeNotifier extends Notifier<ReadingViewMode> {
  static const _kKey = 'reading.view_mode';

  /// 标记用户已显式修改（防止异步恢复覆盖新值）。
  var _dirty = false;

  @override
  ReadingViewMode build() {
    _dirty = false;
    _restore();
    return ReadingViewMode.grid;
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    if (_dirty) return;
    state = ReadingViewMode.values.asNameMap()[prefs.getString(_kKey)] ??
        ReadingViewMode.grid;
  }

  /// 切换网格/列表并持久化。
  Future<void> toggle() async {
    _dirty = true;
    final next = state == ReadingViewMode.grid
        ? ReadingViewMode.list
        : ReadingViewMode.grid;
    state = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kKey, next.name);
  }
}

/// "正在阅读"进度列表：全部条目（含已读完），按 updated_at 降序。
///
/// 数据源为本地 drift 缓存 + 后端合并（冲突以最新为准，F-502），
/// 离线时展示本地缓存记录。已读完记录保留显示，直到用户手动删除。
final readingListProvider =
    AsyncNotifierProvider<ReadingListNotifier, List<ReadingProgress>>(
  ReadingListNotifier.new,
);

class ReadingListNotifier extends AsyncNotifier<List<ReadingProgress>> {
  /// 自动刷新防抖定时器（合并短时间内的连续进度上报）。
  Timer? _refreshTimer;
  bool _refreshing = false;
  bool _refreshPending = false;

  @override
  Future<List<ReadingProgress>> build() {
    // 每次进度上报（ProgressRepository.save）后自动刷新列表：
    // 播放器等场景会周期性上报（如每 5 秒），防抖合并避免高频重复拉取。
    ref.listen(progressRevisionProvider, (_, __) => _scheduleAutoRefresh());
    ref.onDispose(() => _refreshTimer?.cancel());
    return _fetch();
  }

  ProgressRepository get _repo => ref.read(progressRepositoryProvider);

  Future<List<ReadingProgress>> _fetch() async {
    final items = await _repo.listMerged();
    items.sort((a, b) {
      final at = a.updatedAt;
      final bt = b.updatedAt;
      if (at == null && bt == null) return 0;
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
    return items;
  }

  /// 防抖调度自动刷新（每次进度上报后调用）。
  void _scheduleAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer(
      const Duration(seconds: 2),
      () => unawaited(refresh()),
    );
  }

  /// 下拉刷新 / 手动刷新。
  ///
  /// 重入保护：刷新进行期间的新请求不并发执行，标记排队、
  /// 本次完成后补跑一次，避免乱序覆盖最新数据。
  Future<void> refresh() async {
    if (_refreshing) {
      _refreshPending = true;
      return;
    }
    _refreshing = true;
    try {
      state = await AsyncValue.guard(_fetch);
    } finally {
      _refreshing = false;
      if (_refreshPending) {
        _refreshPending = false;
        await refresh();
      }
    }
  }

  /// 删除阅读记录（即时从列表移除；离线时本地标记待同步删除）。
  Future<void> delete(int sourceId, String filePath) async {
    await _repo.delete(sourceId, filePath);
    final current = state.valueOrNull;
    if (current != null) {
      state = AsyncData(
        current
            .where(
              (p) => !(p.sourceId == sourceId && p.filePath == filePath),
            )
            .toList(),
      );
    } else {
      await refresh();
    }
  }
}
