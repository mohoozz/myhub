import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/api/source_api.dart';
import 'package:myhub_flutter/core/models/source.dart';

/// 路径源列表状态。
final sourceListProvider =
    AsyncNotifierProvider<SourceListNotifier, List<Source>>(
  SourceListNotifier.new,
);

/// 路径源表单数据（添加/编辑弹窗提交）。
class SourceFormData {
  const SourceFormData({
    required this.name,
    required this.type,
    this.mountPoint = '',
    this.webdavUrl = '',
    this.webdavUsername = '',
    this.webdavPassword = '',
    this.enabled = true,
  });

  final String name;
  final SourceType type;
  final String mountPoint;
  final String webdavUrl;
  final String webdavUsername;
  final String webdavPassword;
  final bool enabled;

  Map<String, dynamic> toPayload() {
    return {
      'name': name,
      'type': type.name, // 枚举名与后端 type 值一致（local/webdav/openlist）
      'mount_point': mountPoint,
      if (type == SourceType.webdav)
        'config_json': jsonEncode({
          'url': webdavUrl,
          'username': webdavUsername,
          'password': webdavPassword,
        })
      else
        'config_json': '',
      'enabled': enabled,
    };
  }
}

class SourceListNotifier extends AsyncNotifier<List<Source>> {
  @override
  Future<List<Source>> build() => _fetch();

  SourceApi get _api => ref.read(sourceApiProvider);

  Future<List<Source>> _fetch() async {
    final raw = await _api.list();
    return raw
        .map((e) => Source.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 重新拉取列表。
  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_fetch);
  }

  /// 添加路径源。
  Future<void> add(SourceFormData form) async {
    await _api.create(form.toPayload());
    await refresh();
  }

  /// 编辑路径源。
  Future<void> edit(int id, SourceFormData form) async {
    await _api.update(id, form.toPayload());
    await refresh();
  }

  /// 删除路径源。
  Future<void> remove(int id) async {
    await _api.delete(id);
    await refresh();
  }

  /// 启用/停用切换。
  Future<void> toggle(Source source, bool enabled) async {
    await _api.update(source.id, {
      'name': source.name,
      'type': source.type.name,
      'config_json': source.configJson,
      'mount_point': source.mountPoint,
      'enabled': enabled,
    });
    await refresh();
  }

  /// 连接测试：成功返回 null，失败返回错误信息。
  Future<String?> testConnection(int id) async {
    try {
      await _api.testConnection(id);
      return null;
    } catch (e) {
      return e.toString();
    }
  }
}

/// 浏览页当前选中的路径源（null = 未选，自动取列表第一个）。
final currentSourceProvider = StateProvider<Source?>((ref) => null);

/// 实际生效的当前路径源：手动选择优先，缺省取列表第一个可用源。
final effectiveSourceProvider = Provider<Source?>((ref) {
  final selected = ref.watch(currentSourceProvider);
  if (selected != null) return selected;
  final list = ref.watch(sourceListProvider).valueOrNull;
  if (list == null || list.isEmpty) return null;
  return list.firstWhere((s) => s.enabled, orElse: () => list.first);
});
