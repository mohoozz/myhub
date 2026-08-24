import 'dart:io';

import 'package:dio/dio.dart';
import 'package:myhub_flutter/core/api/api_exception.dart';
import 'package:myhub_flutter/core/api/stream_api.dart';
import 'package:path_provider/path_provider.dart';

/// 文件下载工具：把服务器上的文件保存到本地磁盘。
///
/// 下载走服务端已有的 `/api/stream/{sourceId}/{path}` 原始流接口
/// （全量 GET，JWT 鉴权头由 [Dio] 拦截器附带，支持任意文件类型）。
abstract final class DownloadSaver {
  /// 解析下载目标目录（不存在时自动创建）。
  ///
  /// * 桌面端（Windows/macOS/Linux）：系统「下载」目录；
  /// * 移动端（iOS/Android）：应用沙盒 Documents/Downloads，
  ///   iOS 上 Info.plist 已开启 UIFileSharingEnabled /
  ///   LSSupportsOpeningDocumentsInPlace，可在「文件」App 中查看。
  static Future<Directory> resolveDir() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final dir = await getDownloadsDirectory();
      if (dir != null) return dir;
    }
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}${Platform.pathSeparator}Downloads');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 计算不重名的目标文件路径（同名自动追加 " (n)"）。
  static Future<String> uniquePath(Directory dir, String fileName) async {
    final sep = Platform.pathSeparator;
    final base = '${dir.path}$sep$fileName';
    if (!await File(base).exists()) return base;
    final dot = fileName.lastIndexOf('.');
    final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
    final ext = dot > 0 ? fileName.substring(dot) : '';
    for (var i = 1; ; i++) {
      final candidate = '${dir.path}$sep$stem ($i)$ext';
      if (!await File(candidate).exists()) return candidate;
    }
  }

  /// 下载完成后的提示文案：iOS 沙盒路径对用户无意义，改指「文件」App。
  static String savedHint(String savedPath) {
    if (Platform.isIOS) {
      return '已保存到「文件」App 的 Myhub/Downloads';
    }
    return '已保存到 $savedPath';
  }
}

/// 下载远端文件到本地磁盘（流式写盘，避免大文件占满内存）。
///
/// [dio] 需已配置 JWT 鉴权拦截器（即 [dioProvider] 实例）。
/// 返回保存后的完整本地路径；失败时清理半成品文件并抛 [ApiException]。
Future<String> downloadRemoteFile({
  required Dio dio,
  required String baseUrl,
  required int sourceId,
  required String path,
  required String fileName,
  required Directory destDir,
  void Function(int received, int total)? onProgress,
}) async {
  String? destPath;
  try {
    final url = StreamApi.streamUrl(sourceId, path, baseUrl: baseUrl);
    final res = await dio.get<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        followRedirects: true,
        // 下载大文件耗时较长，放宽接收超时（默认 30s 会中断慢速下载）
        receiveTimeout: const Duration(minutes: 30),
      ),
    );
    final body = res.data;
    if (body == null) {
      throw const ApiException(code: -1, message: '下载失败：响应为空');
    }
    destPath = await DownloadSaver.uniquePath(destDir, fileName);
    final total = int.tryParse(
      res.headers.value(Headers.contentLengthHeader) ?? '',
    );
    final sink = File(destPath).openWrite();
    try {
      var received = 0;
      await for (final chunk in body.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total ?? received);
      }
    } finally {
      await sink.close();
    }
    return destPath;
  } catch (e) {
    // 失败时清理半成品文件，避免残留损坏文件
    if (destPath != null) {
      try {
        await File(destPath).delete();
      } catch (_) {}
    }
    if (e is DioException) {
      if (e.error is ApiException) throw e.error! as ApiException;
      throw ApiException.fromDio(e);
    }
    rethrow;
  }
}
