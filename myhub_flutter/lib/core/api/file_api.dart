import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/api/api_client.dart';
import 'package:myhub_flutter/core/api/dio_client.dart';
import 'package:myhub_flutter/core/config/env.dart';

final fileApiProvider = Provider<FileApi>(
  (ref) => FileApi(ref.watch(dioProvider)),
);

/// 文件管理接口封装。
class FileApi extends ApiClient {
  FileApi(super.dio);

  /// 列目录（含媒体类型识别）。
  Future<List<dynamic>> listFiles(int sourceId, String path) async {
    try {
      final res = await dio.get<Map<String, dynamic>>(
        '/files',
        queryParameters: {'source': sourceId, 'path': path},
      );
      return (unwrap(res) as List<dynamic>?) ?? [];
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 新建文件夹。
  Future<void> mkdir(int sourceId, String path) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '/files/mkdir',
        data: {'source': sourceId, 'path': path},
      );
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 上传文件（multipart，字段名 files，支持多文件与进度回调）。
  ///
  /// [filePaths] 为本地文件绝对路径列表，文件名取路径最后一段。
  Future<List<dynamic>> uploadFiles(
    int sourceId,
    String dir,
    List<String> filePaths, {
    void Function(int sent, int total)? onProgress,
  }) async {
    try {
      final form = FormData();
      for (final p in filePaths) {
        form.files.add(MapEntry('files', await MultipartFile.fromFile(p)));
      }
      final res = await dio.post<Map<String, dynamic>>(
        '/files/upload',
        queryParameters: {'source': sourceId, 'path': dir},
        data: form,
        onSendProgress: onProgress,
      );
      final data = unwrap(res) as Map<String, dynamic>?;
      return (data?['uploaded'] as List<dynamic>?) ?? [];
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 重命名。
  Future<void> rename(int sourceId, String path, String newName) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '/files/rename',
        data: {'source': sourceId, 'path': path, 'new_name': newName},
      );
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 移动（同源或跨源中转）。
  Future<void> moveFiles(
    int sourceId,
    List<String> paths,
    String targetPath, {
    int? targetSource,
  }) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '/files/move',
        data: {
          'source': sourceId,
          'paths': paths,
          'target_path': targetPath,
          if (targetSource != null) 'target_source': targetSource,
        },
      );
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 复制（同源或跨源中转）。
  Future<void> copyFiles(
    int sourceId,
    List<String> paths,
    String targetPath, {
    int? targetSource,
  }) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '/files/copy',
        data: {
          'source': sourceId,
          'paths': paths,
          'target_path': targetPath,
          if (targetSource != null) 'target_source': targetSource,
        },
      );
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 删除入回收站。
  Future<void> deleteFiles(int sourceId, List<String> paths) async {
    try {
      final res = await dio.delete<Map<String, dynamic>>(
        '/files',
        data: {'source': sourceId, 'paths': paths},
      );
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 视频缩略图 URL（需自行附带 Authorization 头加载）。
  String thumbnailUrl(int sourceId, String path) {
    return '${Env.apiBaseUrl}/api/files/thumbnail?source=$sourceId&path=${Uri.encodeComponent(path)}';
  }
}
