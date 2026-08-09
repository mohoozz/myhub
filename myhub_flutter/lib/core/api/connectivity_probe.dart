import 'package:dio/dio.dart';

/// 服务器连通性探测。
///
/// 对 `$baseUrl/api/health` 发起一次轻量 GET，仅当返回的是 myhub-server 的健康响应时
/// 视为连通（避免把端口上其他 HTTP 服务误判为可用）。
///
/// 成功返回 `null`；失败返回可读的错误原因（连接超时、拒绝、DNS 解析失败、非 myhub
/// 服务等）。
///
/// [probeServer] 使用独立的 [Dio] 实例（短超时、无鉴权/错误拦截），不会影响主
/// [dioProvider] 共享实例。
Future<String?> probeServer(
  String baseUrl, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final url = baseUrl.trim();
  if (url.isEmpty) return '地址为空';
  final dio = Dio(
    BaseOptions(
      baseUrl: url,
      // 探测仍要尽快返回，但需给外网/慢网络留足余量，避免把“响应偏慢”误判为连接失败
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: timeout,
      sendTimeout: timeout,
    ),
  );
  try {
    final res = await dio.get<Map<String, dynamic>>('/api/health');
    if (res.statusCode != 200) return '服务器返回状态码 ${res.statusCode}';
    // 后端统一响应结构：{ "code": 0, "data": {...}, "message": "" }
    // 服务信息在 data 字段内部，code 为 0 表示成功。
    final body = res.data;
    if (body == null || body['code'] != 0) return '服务状态异常';
    final data = body['data'];
    if (data is! Map || data['status'] != 'ok') return '服务状态异常';
    if (data['service'] != 'myhub-server') return '该地址不是 myhub 服务器';
    return null;
  } on DioException catch (e) {
    return _describe(e);
  } catch (e) {
    return e.toString();
  }
  // 注意：这里不调用 dio.close(force: true)。
  // 该临时实例仅在本次探测中使用，请求已 await 完成，交给 GC 回收即可；
  // 强制关闭会在 Dio 5 中取消/中断底层连接，可能把成功请求误报为“连接被拒绝”。
}

/// 将 [DioException] 转成可读的错误原因。
String _describe(DioException e) {
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
      return '连接超时';
    case DioExceptionType.sendTimeout:
      return '发送超时';
    case DioExceptionType.receiveTimeout:
      return '接收超时';
    case DioExceptionType.badResponse:
      return '服务器响应异常（${e.response?.statusCode}）';
    case DioExceptionType.connectionError:
      return '连接被拒绝';
    case DioExceptionType.unknown:
      return e.message ?? '未知错误';
    default:
      return e.message ?? '请求失败';
  }
}
