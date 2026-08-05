import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/api/api_client.dart';
import 'package:myhub_flutter/core/api/dio_client.dart';

final configApiProvider = Provider<ConfigApi>(
  (ref) => ConfigApi(ref.watch(dioProvider)),
);

/// 系统配置接口封装。
class ConfigApi extends ApiClient {
  ConfigApi(super.dio);

  /// 获取所有配置（键值对）。
  Future<Map<String, String>> getAll() async {
    try {
      final res = await dio.get<Map<String, dynamic>>('/config');
      final data = unwrap(res) as Map<String, dynamic>?;
      return data?.map((k, v) => MapEntry(k, v.toString())) ?? {};
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 批量更新配置。
  Future<void> batchUpdate(Map<String, String> configs) async {
    try {
      final res =
          await dio.put<Map<String, dynamic>>('/config', data: configs);
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }
}
