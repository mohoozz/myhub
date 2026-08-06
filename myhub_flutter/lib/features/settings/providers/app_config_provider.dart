import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/api/config_api.dart';

/// 服务端应用配置键（`GET/PUT /api/config` 持久化）。
abstract final class AppConfigKeys {
  /// 回收站保留天数（后端定时清理任务读取）。
  static const trashRetentionDays = 'trash.retention_days';

  /// 动态列表保留条数上限（M5 动态模块消费）。
  static const feedKeepCount = 'feed.keep_count';

  /// 动态抓取频率（分钟，M5 动态模块消费）。
  static const feedFetchIntervalMin = 'feed.fetch_interval_min';
}

/// 服务端应用配置（键值对），设置页读写。
final appConfigProvider =
    AsyncNotifierProvider<AppConfigNotifier, Map<String, String>>(
  AppConfigNotifier.new,
);

class AppConfigNotifier extends AsyncNotifier<Map<String, String>> {
  @override
  Future<Map<String, String>> build() => ref.read(configApiProvider).getAll();

  /// 读取单个配置（缺省返回 [fallback]）。
  String get(String key, String fallback) => state.valueOrNull?[key] ?? fallback;

  /// 更新单个配置：本地即时生效 + 远端持久化，失败回滚并抛错。
  Future<void> setValue(String key, String value) async {
    final previous = state.valueOrNull ?? const {};
    state = AsyncData({...previous, key: value});
    try {
      await ref.read(configApiProvider).batchUpdate({key: value});
    } catch (e) {
      state = AsyncData(previous);
      rethrow;
    }
  }
}
