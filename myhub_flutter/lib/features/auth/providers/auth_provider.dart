import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:myhub_flutter/core/api/auth_api.dart';
import 'package:myhub_flutter/shared/providers/auth_state_provider.dart';

/// 鉴权动作封装：登录 / 登出 / 修改密码。
final authProvider = Provider<AuthActions>(AuthActions.new);

class AuthActions {
  AuthActions(this._ref);

  final Ref _ref;
  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  AuthApi get _api => _ref.read(authApiProvider);

  /// 登录：成功写入 Token 并更新全局认证状态（路由守卫自动跳转）。
  /// 失败抛 [ApiException]，由界面层提示。
  Future<String> login(String username, String password) async {
    final token = await _api.login(username, password);
    await _storage.write(key: kAccessTokenKey, value: token);
    _ref.read(authStateProvider.notifier).markAuthenticated(username);
    return token;
  }

  /// 登出：清除本地 Token，路由守卫自动跳回登录页。
  Future<void> logout() {
    return _ref.read(authStateProvider.notifier).markLoggedOut();
  }

  /// 修改密码（需旧密码验证）。
  Future<void> changePassword(String oldPassword, String newPassword) {
    return _api.changePassword(oldPassword, newPassword);
  }
}
