import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:myhub_flutter/core/api/api_exception.dart';
import 'package:myhub_flutter/core/config/env.dart';
import 'package:myhub_flutter/shared/providers/auth_state_provider.dart';

/// Shared [Dio] instance for the whole app.
final dioProvider = Provider<Dio>(
  (ref) => DioClient.create(
    // 401 → 清除登录状态，路由守卫自动跳回登录页
    onUnauthorized: () =>
        ref.read(authStateProvider.notifier).markLoggedOut(),
  ),
);

/// Factory for the pre-configured [Dio] singleton.
abstract final class DioClient {
  static Dio create({Future<void> Function()? onUnauthorized}) {
    final dio = Dio(
      BaseOptions(
        // Env.apiBaseUrl 为主机地址（如 http://127.0.0.1:8080），
        // 后端所有业务接口统一挂在 /api 前缀下。
        baseUrl: '${Env.apiBaseUrl}/api',
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(seconds: 30),
        contentType: Headers.jsonContentType,
        responseType: ResponseType.json,
      ),
    );
    dio.interceptors.addAll([
      _JwtAuthInterceptor(),
      _ErrorInterceptor(onUnauthorized: onUnauthorized),
      if (kDebugMode)
        LogInterceptor(
          requestBody: true,
          responseBody: false, // 响应体可能很大（章节内容/图片），仅记录请求
          logPrint: (obj) => debugPrint('[dio] $obj'),
        ),
    ]);
    return dio;
  }
}

/// Attaches the persisted JWT access token to outgoing requests.
class _JwtAuthInterceptor extends Interceptor {
  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final token = await _storage.read(key: kAccessTokenKey);
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }
}

/// Normalizes backend error responses into [ApiException]，
/// and signs the user out on 401 responses.
class _ErrorInterceptor extends Interceptor {
  _ErrorInterceptor({this.onUnauthorized});

  final Future<void> Function()? onUnauthorized;

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.response?.statusCode == 401) {
      // 登录接口自身的 401 也会走到这里；此时本就未登录，清理无副作用
      onUnauthorized?.call();
    }
    handler.next(DioException(
      requestOptions: err.requestOptions,
      response: err.response,
      type: err.type,
      error: ApiException.fromDio(err),
    ));
  }
}
