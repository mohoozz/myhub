import 'dart:convert';

/// 流媒体 URL 构造（直链供播放器/浏览器使用，鉴权头由播放器另行附带）。
///
/// 与后端 /api/stream/*rest 单通配分发保持一致：
/// * 原始流：/api/stream/{sourceId}/{path}
/// * HLS：/api/stream/hls/{id}/playlist.m3u8 与 /api/stream/hls/{id}/segment/{n}.ts
///   （id = base64url("sourceId|path")，无 padding，与后端 ParseHLSSessionID 对应）
/// * 字幕：/api/stream/subtitle?source=&path=
abstract final class StreamApi {
  /// 原始流地址（支持 Range）。
  ///
  /// [baseUrl] 为当前生效的服务器主机地址（见 `apiBaseUrlProvider`）。
  /// 逐段百分号编码：文件名中的 `#`（片段分隔符）、`?`、`%`、空格等
  /// 字符必须转义，否则路径会被截断或解析错误（`Uri.encodeFull` 不够）。
  static String streamUrl(int sourceId, String path, {required String baseUrl}) {
    final encoded = path.split('/').map(Uri.encodeComponent).join('/');
    return '$baseUrl/api/stream/$sourceId$encoded';
  }

  /// HLS 播放列表地址。
  static String hlsPlaylistUrl(int sourceId, String path,
      {required String baseUrl}) {
    return '$baseUrl/api/stream/hls/${hlsSessionId(sourceId, path)}/playlist.m3u8';
  }

  /// HLS 分片地址（segName 形如 seg_00000.ts）。
  static String hlsSegmentUrl(int sourceId, String path, String segName,
      {required String baseUrl}) {
    return '$baseUrl/api/stream/hls/${hlsSessionId(sourceId, path)}/segment/$segName';
  }

  /// 字幕转换地址（srt/ass → vtt）。
  static String subtitleUrl(int sourceId, String path,
      {required String baseUrl}) {
    return '$baseUrl/api/stream/subtitle?source=$sourceId&path=${Uri.encodeComponent(path)}';
  }

  /// 视频编码探测地址（返回 {"codec": "hevc"}，播放前决定硬解/软解）。
  static String probeUrl(int sourceId, String path,
      {required String baseUrl}) {
    return '$baseUrl/api/stream/probe?source=$sourceId&path=${Uri.encodeComponent(path)}';
  }

  /// 计算 HLS 会话 ID：base64url("sourceId|path")，去掉 padding。
  static String hlsSessionId(int sourceId, String path) {
    return base64UrlEncode(utf8.encode('$sourceId|$path'))
        .replaceAll('=', '');
  }
}
