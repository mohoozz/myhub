import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/api/api_client.dart';
import 'package:myhub_flutter/core/api/dio_client.dart';

final trashApiProvider = Provider<TrashApi>(
  (ref) => TrashApi(ref.watch(dioProvider)),
);

/// 回收站接口封装。
class TrashApi extends ApiClient {
  TrashApi(super.dio);

  /// 回收站列表（可按路径源过滤）。
  Future<List<dynamic>> list({int? sourceId}) async {
    try {
      final res = await dio.get<Map<String, dynamic>>(
        '/trash',
        queryParameters: {if (sourceId != null) 'source': sourceId},
      );
      return (unwrap(res) as List<dynamic>?) ?? [];
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 还原文件到原路径。
  Future<void> restore(int id) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '/trash/restore',
        data: {'id': id},
      );
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 彻底删除单个文件。
  Future<void> deleteOne(int id) async {
    try {
      final res = await dio.delete<Map<String, dynamic>>('/trash/$id');
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 清空回收站（可按路径源过滤）。
  Future<void> clear({int? sourceId}) async {
    try {
      final res = await dio.delete<Map<String, dynamic>>(
        '/trash',
        queryParameters: {if (sourceId != null) 'source': sourceId},
      );
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }
}
