import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/api/api_client.dart';
import 'package:myhub_flutter/core/api/dio_client.dart';

final sourceApiProvider = Provider<SourceApi>(
  (ref) => SourceApi(ref.watch(dioProvider)),
);

/// 路径源管理接口封装。
class SourceApi extends ApiClient {
  SourceApi(super.dio);

  /// 路径源列表。
  Future<List<dynamic>> list() async {
    try {
      final res = await dio.get<Map<String, dynamic>>('/sources');
      return (unwrap(res) as List<dynamic>?) ?? [];
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 单个路径源详情。
  Future<Map<String, dynamic>> get(int id) async {
    try {
      final res = await dio.get<Map<String, dynamic>>('/sources/$id');
      return unwrap(res) as Map<String, dynamic>;
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 创建路径源。payload 字段：name/type/config_json/mount_point/enabled。
  Future<Map<String, dynamic>> create(Map<String, dynamic> payload) async {
    try {
      final res =
          await dio.post<Map<String, dynamic>>('/sources', data: payload);
      return unwrap(res) as Map<String, dynamic>;
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 更新路径源。
  Future<Map<String, dynamic>> update(
    int id,
    Map<String, dynamic> payload,
  ) async {
    try {
      final res =
          await dio.put<Map<String, dynamic>>('/sources/$id', data: payload);
      return unwrap(res) as Map<String, dynamic>;
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 删除路径源。
  Future<void> delete(int id) async {
    try {
      final res = await dio.delete<Map<String, dynamic>>('/sources/$id');
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 连接测试：成功返回 true，失败抛 ApiException。
  Future<bool> testConnection(int id) async {
    try {
      final res = await dio.post<Map<String, dynamic>>('/sources/$id/test');
      unwrap(res);
      return true;
    } catch (e) {
      rethrowAsApi(e);
    }
  }
}
