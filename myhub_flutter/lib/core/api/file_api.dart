import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/api/api_client.dart';
import 'package:myhub_flutter/core/api/dio_client.dart';
import 'package:myhub_flutter/core/settings/server_config_provider.dart';

final fileApiProvider = Provider<FileApi>(
  (ref) => FileApi(
    ref.watch(dioProvider),
    baseUrl: ref.watch(apiBaseUrlProvider),
  ),
);

/// 文件管理接口封装。
class FileApi extends ApiClient {
  FileApi(super.dio, {required this.baseUrl});

  /// 当前生效的服务器主机地址。
  final String baseUrl;

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

  /// 查询单个文件信息（名称/路径/大小/修改时间/媒体类型）。
  Future<Map<String, dynamic>> fileInfo(int sourceId, String path) async {
    try {
      final res = await dio.get<Map<String, dynamic>>(
        '/files/info',
        queryParameters: {'source': sourceId, 'path': path},
      );
      return (unwrap(res) as Map<String, dynamic>?) ?? <String, dynamic>{};
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

  /// 音视频缩略图 URL（音频提取内嵌专辑封面；需自行附带 Authorization 头加载）。
  String thumbnailUrl(int sourceId, String path) {
    return '$baseUrl/api/files/thumbnail?source=$sourceId&path=${Uri.encodeComponent(path)}';
  }

  /// 图片原图 URL（需自行附带 Authorization 头加载）。
  String imageUrl(int sourceId, String path) {
    return '$baseUrl/api/files/image?source=$sourceId&path=${Uri.encodeComponent(path)}';
  }

  /// 纯文本预览（不支持预览的文件经"纯文本"入口加载）。
  /// 返回 {name, size, content, truncated}；非文本文件后端返回 400。
  Future<Map<String, dynamic>> textPreview(int sourceId, String path) async {
    try {
      final res = await dio.get<Map<String, dynamic>>(
        '/files/text',
        queryParameters: {'source': sourceId, 'path': path},
      );
      return (unwrap(res) as Map<String, dynamic>?) ?? <String, dynamic>{};
    } catch (e) {
      rethrowAsApi(e);
    }
  }
}
