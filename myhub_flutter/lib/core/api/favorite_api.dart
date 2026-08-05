import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/api/api_client.dart';
import 'package:myhub_flutter/core/api/dio_client.dart';

final favoriteApiProvider = Provider<FavoriteApi>(
  (ref) => FavoriteApi(ref.watch(dioProvider)),
);

/// 收藏接口封装。
class FavoriteApi extends ApiClient {
  FavoriteApi(super.dio);

  /// 收藏列表（分页）。返回 {list, total, page, page_size}。
  Future<Map<String, dynamic>> list({int page = 1, int pageSize = 50}) async {
    try {
      final res = await dio.get<Map<String, dynamic>>(
        '/favorites',
        queryParameters: {'page': page, 'page_size': pageSize},
      );
      return unwrap(res) as Map<String, dynamic>;
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 添加收藏。
  Future<Map<String, dynamic>> add(int sourceId, String filePath) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '/favorites',
        data: {'source_id': sourceId, 'file_path': filePath},
      );
      return unwrap(res) as Map<String, dynamic>;
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 取消收藏。
  Future<void> remove(int sourceId, String filePath) async {
    try {
      final res = await dio.delete<Map<String, dynamic>>(
        '/favorites',
        data: {'source_id': sourceId, 'file_path': filePath},
      );
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }
}
