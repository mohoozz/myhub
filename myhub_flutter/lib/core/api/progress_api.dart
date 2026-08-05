import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/api/api_client.dart';
import 'package:myhub_flutter/core/api/dio_client.dart';

final progressApiProvider = Provider<ProgressApi>(
  (ref) => ProgressApi(ref.watch(dioProvider)),
);

/// 阅读/播放进度接口封装。
class ProgressApi extends ApiClient {
  ProgressApi(super.dio);

  /// 全部进度（按更新时间降序）。
  Future<List<dynamic>> list() async {
    try {
      final res = await dio.get<Map<String, dynamic>>('/progress');
      return (unwrap(res) as List<dynamic>?) ?? [];
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 保存/更新进度（upsert）。
  ///
  /// [progressJson] 为各类型专属进度数据（章节号、播放秒数、漫画页码等）。
  Future<void> save({
    required int sourceId,
    required String filePath,
    required String mediaType,
    String? title,
    String? cover,
    String? progressJson,
    double? percent,
    bool? finished,
  }) async {
    try {
      final res = await dio.put<Map<String, dynamic>>(
        '/progress',
        data: {
          'source_id': sourceId,
          'file_path': filePath,
          'media_type': mediaType,
          if (title != null) 'title': title,
          if (cover != null) 'cover': cover,
          if (progressJson != null) 'progress_json': progressJson,
          if (percent != null) 'percent': percent,
          if (finished != null) 'finished': finished,
        },
      );
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 标记已读完。
  Future<void> markFinished(int sourceId, String filePath) async {
    try {
      final res = await dio.delete<Map<String, dynamic>>(
        '/progress',
        data: {'source_id': sourceId, 'file_path': filePath},
      );
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }
}
