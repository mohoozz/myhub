import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:myhub_flutter/core/api/api_exception.dart';
import 'package:myhub_flutter/core/settings/server_config_provider.dart';
import 'package:myhub_flutter/shared/providers/auth_state_provider.dart';

/// Shared [Dio] instance for the whole app.
///
/// 监听服务器配置：用户切换服务器地址时重建 Dio，使后续请求发往新服务器。
final dioProvider = Provider<Dio>(
  (ref) {
    // watch 服务器地址：变化时本 provider 重建，Dio 也随之重建
    final baseUrl = ref.watch(apiBaseUrlProvider);
    return DioClient.create(
      baseUrl: baseUrl,
      // 401 → 清除登录状态，路由守卫自动跳回登录页。
      // 仅当已登录时才登出：登录失败等未登录场景的 401 不应清状态
      onUnauthorized: () async {
        if (ref.read(authStateProvider).isAuthenticated) {
          await ref.read(authStateProvider.notifier).markLoggedOut();
        }
      },
    );
  },
);

/// Factory for the pre-configured [Dio] singleton.
abstract final class DioClient {
  static Dio create({
    required String baseUrl,
    Future<void> Function()? onUnauthorized,
  }) {
    final dio = Dio(
      BaseOptions(
        // baseUrl 为主机地址（如 http://127.0.0.1:8080），
        // 后端所有业务接口统一挂在 /api 前缀下。
        baseUrl: '$baseUrl/api',
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
    // 登录接口自身的 401 说明凭证错误，由界面提示，不触发全局登出；
    // 其余接口的 401 视为 Token 失效/过期，通知回调登出
    if (err.response?.statusCode == 401 &&
        !_isLoginRequest(err.requestOptions)) {
      onUnauthorized?.call();
    }
    handler.next(DioException(
      requestOptions: err.requestOptions,
      response: err.response,
      type: err.type,
      error: ApiException.fromDio(err),
    ));
  }

  /// 是否为登录接口请求（其 401 是凭证错误，不触发登出）。
  static bool _isLoginRequest(RequestOptions options) {
    return options.path.endsWith('/auth/login');
  }
}
