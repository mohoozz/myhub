import 'package:dio/dio.dart';

/// Business-level error mapped from the backend's unified error
/// envelope: `{ "code": int, "data": null, "message": string }`
/// (see myhub-server internal/handler/response.go).
class ApiException implements Exception {
  const ApiException({
    required this.code,
    required this.message,
    this.statusCode,
  });

  /// Business error code; equals the HTTP status code during scaffolding.
  final int code;

  /// Human-readable error message returned by the backend.
  final String message;

  /// HTTP status code, when a response was actually received.
  final int? statusCode;

  /// 从 DioException 归一化错误：优先取后端信封的 message。
  factory ApiException.fromDio(DioException err) {
    final response = err.response;
    if (response?.data is Map<String, dynamic>) {
      final body = response!.data as Map<String, dynamic>;
      final message = body['message'];
      if (message is String && message.isNotEmpty) {
        return ApiException(
          code: body['code'] as int? ?? response.statusCode ?? -1,
          message: message,
          statusCode: response.statusCode,
        );
      }
    }
    return ApiException(
      code: response?.statusCode ?? -1,
      message: switch (err.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout => '请求超时，请稍后重试',
        DioExceptionType.connectionError => '无法连接服务器',
        _ => '网络请求失败',
      },
      statusCode: response?.statusCode,
    );
  }

  @override
  String toString() =>
      'ApiException(code: $code, http: $statusCode): $message';
}
