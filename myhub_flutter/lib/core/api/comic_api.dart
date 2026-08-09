import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/api/api_client.dart';
import 'package:myhub_flutter/core/api/dio_client.dart';
import 'package:myhub_flutter/core/settings/server_config_provider.dart';

final comicApiProvider = Provider<ComicApi>(
  (ref) => ComicApi(
    ref.watch(dioProvider),
    baseUrl: ref.watch(apiBaseUrlProvider),
  ),
);

/// 漫画阅读接口封装。
class ComicApi extends ApiClient {
  ComicApi(super.dio, {required this.baseUrl});

  /// 当前生效的服务器主机地址。
  final String baseUrl;

  /// 漫画识别。返回 {is_comic, reason}。
  Future<Map<String, dynamic>> detect(int sourceId, String path) async {
    try {
      final res = await dio.get<Map<String, dynamic>>(
        '/reader/comic/detect',
        queryParameters: {'source': sourceId, 'path': path},
      );
      return unwrap(res) as Map<String, dynamic>;
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 手动覆盖漫画标记。
  Future<void> override(int sourceId, String path, bool isComic) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '/reader/comic/override',
        data: {'source': sourceId, 'path': path, 'is_comic': isComic},
      );
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 漫画页列表。返回 {pages, total}。
  Future<Map<String, dynamic>> pages(int sourceId, String path) async {
    try {
      final res = await dio.get<Map<String, dynamic>>(
        '/reader/comic/pages',
        queryParameters: {'source': sourceId, 'path': path},
      );
      return unwrap(res) as Map<String, dynamic>;
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 单页图片字节。返回 (bytes, contentType)。
  Future<(Uint8List, String)> page(int sourceId, String path, int n) async {
    try {
      final res = await dio.get<List<int>>(
        '/reader/comic/page',
        queryParameters: {'source': sourceId, 'path': path, 'n': n},
        options: Options(responseType: ResponseType.bytes),
      );
      return (
        Uint8List.fromList(res.data ?? const []),
        res.headers.value(Headers.contentTypeHeader) ?? 'image/jpeg',
      );
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 单页图片完整 URL（供 CachedNetworkImage 等直接加载，需自带 JWT 头）。
  /// 页码 [n] 从 0 开始，与 pages() 返回的 index 对应。
  String pageUrl(int sourceId, String path, int n) {
    return '$baseUrl/api/reader/comic/page'
        '?source=$sourceId&path=${Uri.encodeComponent(path)}&n=$n';
  }

  /// 压缩包文件树。返回 {entries, total}。
  Future<Map<String, dynamic>> archiveTree(int sourceId, String path) async {
    try {
      final res = await dio.get<Map<String, dynamic>>(
        '/reader/archive/tree',
        queryParameters: {'source': sourceId, 'path': path},
      );
      return unwrap(res) as Map<String, dynamic>;
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 解出压缩包内单个文件。返回 (bytes, contentType)。
  Future<(Uint8List, String)> archiveFile(
    int sourceId,
    String path,
    String entry,
  ) async {
    try {
      final res = await dio.get<List<int>>(
        '/reader/archive/file',
        queryParameters: {'source': sourceId, 'path': path, 'entry': entry},
        options: Options(responseType: ResponseType.bytes),
      );
      return (
        Uint8List.fromList(res.data ?? const []),
        res.headers.value(Headers.contentTypeHeader) ?? 'application/octet-stream',
      );
    } catch (e) {
      rethrowAsApi(e);
    }
  }
}
