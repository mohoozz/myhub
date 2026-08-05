import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/api/api_client.dart';
import 'package:myhub_flutter/core/api/dio_client.dart';

final readerApiProvider = Provider<ReaderApi>(
  (ref) => ReaderApi(ref.watch(dioProvider)),
);

/// 小说/EPUB 阅读接口封装。
class ReaderApi extends ApiClient {
  ReaderApi(super.dio);

  /// TXT 章节列表。返回 {ready, encoding, chapters, total}。
  Future<Map<String, dynamic>> novelChapters(int sourceId, String path) async {
    try {
      final res = await dio.get<Map<String, dynamic>>(
        '/reader/novel/chapters',
        queryParameters: {'source': sourceId, 'path': path},
      );
      return unwrap(res) as Map<String, dynamic>;
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// TXT 章节内容。返回 {ready, chapter, title, content, total}。
  Future<Map<String, dynamic>> novelContent(
    int sourceId,
    String path,
    int chapter,
  ) async {
    try {
      final res = await dio.get<Map<String, dynamic>>(
        '/reader/novel/content',
        queryParameters: {'source': sourceId, 'path': path, 'chapter': chapter},
      );
      return unwrap(res) as Map<String, dynamic>;
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// EPUB 元数据。返回 {title, author, cover_id, is_comic, toc}。
  Future<Map<String, dynamic>> epubMeta(int sourceId, String path) async {
    try {
      final res = await dio.get<Map<String, dynamic>>(
        '/reader/epub/meta',
        queryParameters: {'source': sourceId, 'path': path},
      );
      return unwrap(res) as Map<String, dynamic>;
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// EPUB 章节 HTML（原始字节，自行转字符串）。
  Future<Uint8List> epubChapter(int sourceId, String path, String id) async {
    return _getBytes('/reader/epub/chapter', sourceId, path, {'id': id});
  }

  /// EPUB 静态资源（图片/CSS）。返回 (bytes, contentType)。
  Future<(Uint8List, String)> epubResource(
    int sourceId,
    String path,
    String id,
  ) async {
    try {
      final res = await dio.get<List<int>>(
        '/reader/epub/resource',
        queryParameters: {'source': sourceId, 'path': path, 'id': id},
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

  Future<Uint8List> _getBytes(
    String url,
    int sourceId,
    String path,
    Map<String, dynamic> extraQuery,
  ) async {
    try {
      final res = await dio.get<List<int>>(
        url,
        queryParameters: {'source': sourceId, 'path': path, ...extraQuery},
        options: Options(responseType: ResponseType.bytes),
      );
      return Uint8List.fromList(res.data ?? const []);
    } catch (e) {
      rethrowAsApi(e);
    }
  }
}
