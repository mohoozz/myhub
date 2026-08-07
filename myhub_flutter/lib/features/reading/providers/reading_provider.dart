import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/models/reading_progress.dart';
import 'package:myhub_flutter/data/repositories/progress_repository.dart';

/// "正在阅读"页视图模式。
enum ReadingViewMode { grid, list }

/// "正在阅读"页视图模式（网格/列表）。
final readingViewModeProvider = StateProvider<ReadingViewMode>(
  (ref) => ReadingViewMode.grid,
);

/// "正在阅读"进度列表：全部条目（含已读完），按 updated_at 降序。
///
/// 数据源为本地 drift 缓存 + 后端合并（冲突以最新为准，F-502），
/// 离线时展示本地缓存记录。已读完记录保留显示，直到用户手动删除。
final readingListProvider =
    AsyncNotifierProvider<ReadingListNotifier, List<ReadingProgress>>(
  ReadingListNotifier.new,
);

class ReadingListNotifier extends AsyncNotifier<List<ReadingProgress>> {
  @override
  Future<List<ReadingProgress>> build() => _fetch();

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

  /// 下拉刷新。
  Future<void> refresh() async {
    state = await AsyncValue.guard(_fetch);
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
