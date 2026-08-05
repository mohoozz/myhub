import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/api/favorite_api.dart';
import 'package:myhub_flutter/core/models/favorite.dart';

/// 收藏列表（页大小 200，一次取全，前端分页/筛选）。
final favoriteListProvider =
    AsyncNotifierProvider<FavoriteListNotifier, List<Favorite>>(
  FavoriteListNotifier.new,
);

class FavoriteListNotifier extends AsyncNotifier<List<Favorite>> {
  @override
  Future<List<Favorite>> build() => _fetch();

  FavoriteApi get _api => ref.read(favoriteApiProvider);

  Future<List<Favorite>> _fetch() async {
    final data = await _api.list(pageSize: 200);
    final raw = (data['list'] as List<dynamic>?) ?? [];
    return raw
        .map((e) => Favorite.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> refresh() async {
    state = await AsyncValue.guard(_fetch);
  }

  /// 收藏/取消收藏切换（浏览页星标、收藏页共用，天然双向同步）。
  Future<void> toggle(int sourceId, String filePath) async {
    final key = '$sourceId|$filePath';
    final current = state.valueOrNull ?? [];
    if (current.any((f) => '${f.sourceId}|${f.filePath}' == key)) {
      await _api.remove(sourceId, filePath);
    } else {
      await _api.add(sourceId, filePath);
    }
    await refresh();
  }

  /// 取消收藏（收藏页星标点击即时移除）。
  Future<void> remove(int sourceId, String filePath) async {
    await _api.remove(sourceId, filePath);
    final current = state.valueOrNull;
    if (current != null) {
      state = AsyncData(
        current
            .where((f) => !(f.sourceId == sourceId && f.filePath == filePath))
            .toList(),
      );
    } else {
      await refresh();
    }
  }
}

/// 收藏路径集合（"sourceId|path"），供浏览页星标快速判定。
final favoritePathsProvider = Provider<Set<String>>((ref) {
  final list = ref.watch(favoriteListProvider).valueOrNull;
  if (list == null) return const {};
  return list.map((f) => '${f.sourceId}|${f.filePath}').toSet();
});
