import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 登录凭证本地记忆：记住上一次登录的用户名（与密码）。
///
/// * 用户名保存在 [SharedPreferences]（非敏感数据）；
/// * 密码保存在 [FlutterSecureStorage]（敏感数据，系统级安全存储）；
/// * 「是否记住密码」开关保存在 [SharedPreferences]。
///
/// 仅在用户勾选「记住密码」时才持久化密码；否则只记用户名，避免明文残留。
final loginCredentialsProvider =
    NotifierProvider<LoginCredentialsNotifier, LoginCredentials>(
  LoginCredentialsNotifier.new,
);

/// 记住的登录凭证。
class LoginCredentials {
  const LoginCredentials({this.username = '', this.password = '', this.remember = false});

  /// 记住的用户名。
  final String username;

  /// 记住的密码（仅在 [remember] 为 true 时有效）。
  final String password;

  /// 是否勾选「记住密码」。
  final bool remember;
}

class LoginCredentialsNotifier extends Notifier<LoginCredentials> {
  /// 用户名存储键。
  static const _kUsernameKey = 'login.remember_username';

  /// 「记住密码」开关存储键。
  static const _kRememberKey = 'login.remember_password';

  /// 密码安全存储键。
  static const _kPasswordKey = 'login.remember_password_value';

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  @override
  LoginCredentials build() {
    _restore();
    return const LoginCredentials();
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString(_kUsernameKey) ?? '';
    final remember = prefs.getBool(_kRememberKey) ?? false;
    final password = remember
        ? (await _storage.read(key: _kPasswordKey) ?? '')
        : '';
    state = LoginCredentials(
      username: username,
      password: password,
      remember: remember,
    );
  }

  /// 保存记住的凭证。仅在 [remember] 为 true 时写入密码，否则清除密码。
  Future<void> save({
    required String username,
    required String password,
    required bool remember,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUsernameKey, username);
    await prefs.setBool(_kRememberKey, remember);
    if (remember && password.isNotEmpty) {
      await _storage.write(key: _kPasswordKey, value: password);
    } else {
      await _storage.delete(key: _kPasswordKey);
    }
    state = LoginCredentials(
      username: username,
      password: remember ? password : '',
      remember: remember,
    );
  }

  /// 仅更新「记住密码」开关（用户点击复选框时调用），不清空其它数据。
  Future<void> setRemember(bool remember) async {
    final current = state;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kRememberKey, remember);
    state = current.copyWith(remember: remember);
  }

  /// 清除所有记住的凭证。
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kUsernameKey);
    await prefs.remove(_kRememberKey);
    await _storage.delete(key: _kPasswordKey);
    state = const LoginCredentials();
  }
}

extension on LoginCredentials {
  LoginCredentials copyWith({bool? remember}) {
    return LoginCredentials(
      username: username,
      password: password,
      remember: remember ?? this.remember,
    );
  }
}
