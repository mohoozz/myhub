import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:myhub_flutter/core/utils/jwt_utils.dart';

/// 安全存储中的 Token 键（与 dio_client 拦截器共用）。
const String kAccessTokenKey = 'access_token';

/// 认证状态。
enum AuthStatus {
  /// 启动初期，本地 Token 尚未读取完成。
  unknown,

  /// 已登录（本地存在 Token）。
  authenticated,

  /// 未登录。
  unauthenticated,
}

/// 全局认证状态。
class AuthState {
  const AuthState({required this.status, this.username});

  final AuthStatus status;

  /// 当前登录用户名（未登录为 null）。
  final String? username;

  bool get isAuthenticated => status == AuthStatus.authenticated;
}

/// 全局认证状态管理。
///
/// 启动时从 `flutter_secure_storage` 读取 Token 恢复登录状态；
/// 登录/登出由认证模块（第 3 章）调用 [AuthStateNotifier.markAuthenticated] /
/// [AuthStateNotifier.markLoggedOut] 更新，路由守卫监听本状态自动跳转。
final authStateProvider = NotifierProvider<AuthStateNotifier, AuthState>(
  AuthStateNotifier.new,
);

class AuthStateNotifier extends Notifier<AuthState> {
  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  @override
  AuthState build() {
    _restore();
    return const AuthState(status: AuthStatus.unknown);
  }

  Future<void> _restore() async {
    final token = await _storage.read(key: kAccessTokenKey);
    if (token == null || token.isEmpty) {
      state = const AuthState(status: AuthStatus.unauthenticated);
      return;
    }
    // Token 有效性检查：本地解析 exp，过期直接清除
    if (JwtUtils.isExpired(token)) {
      await _storage.delete(key: kAccessTokenKey);
      state = const AuthState(status: AuthStatus.unauthenticated);
      return;
    }
    state = const AuthState(status: AuthStatus.authenticated);
  }

  /// 标记已登录（登录成功后调用）。
  void markAuthenticated(String username) {
    state = AuthState(status: AuthStatus.authenticated, username: username);
  }

  /// 标记登出：清除本地 Token 并置为未登录。
  Future<void> markLoggedOut() async {
    await _storage.delete(key: kAccessTokenKey);
    state = const AuthState(status: AuthStatus.unauthenticated);
  }
}
