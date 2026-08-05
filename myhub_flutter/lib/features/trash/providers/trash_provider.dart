import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/api/trash_api.dart';
import 'package:myhub_flutter/core/models/trash_item.dart';

/// 回收站列表。
final trashListProvider =
    AsyncNotifierProvider<TrashListNotifier, List<TrashItem>>(
  TrashListNotifier.new,
);

class TrashListNotifier extends AsyncNotifier<List<TrashItem>> {
  @override
  Future<List<TrashItem>> build() => _fetch();

  TrashApi get _api => ref.read(trashApiProvider);

  Future<List<TrashItem>> _fetch() async {
    final raw = await _api.list();
    return raw
        .map((e) => TrashItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> refresh() async {
    state = await AsyncValue.guard(_fetch);
  }

  /// 还原到原路径。
  Future<void> restore(int id) async {
    await _api.restore(id);
    await refresh();
  }

  /// 彻底删除单个。
  Future<void> purge(int id) async {
    await _api.deleteOne(id);
    final current = state.valueOrNull;
    if (current != null) {
      state = AsyncData(current.where((e) => e.id != id).toList());
    } else {
      await refresh();
    }
  }

  /// 清空回收站。
  Future<void> clear() async {
    await _api.clear();
    state = const AsyncData([]);
  }
}
