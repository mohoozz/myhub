import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/api/auth_api.dart';
import 'package:myhub_flutter/core/settings/server_config_provider.dart';
import 'package:myhub_flutter/shared/providers/auth_state_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 当前登录用户头像的完整 URL（未设置为 null）。
///
/// 头像存储在服务端（`PUT /api/auth/avatar` 上传，`GET /api/auth/avatar`
/// 按 JWT 读取），URL 带 `?v=` 版本号用于刷新缓存。本地 SharedPreferences
/// 按用户名缓存最近一次 URL：启动时先用缓存秒显，已登录时再请求
/// `/auth/me` 同步服务端最新头像（离线则沿用缓存）。
final avatarProvider = NotifierProvider<AvatarNotifier, String?>(
  AvatarNotifier.new,
);

class AvatarNotifier extends Notifier<String?> {
  static const _kKeyPrefix = 'profile.avatar_url.';

  /// 仅在同步上下文中使用（build / 方法首行）。
  String get _username => ref.read(authStateProvider).username ?? 'guest';

  @override
  String? build() {
    // 登录用户变化时重建，重新恢复对应用户的头像
    ref.watch(authStateProvider);
    _restore();
    return null;
  }

  Future<void> _restore() async {
    // ref 只能在首个 await 之前使用（此后 provider 可能已过期重建）
    final username = _username;
    final authed = ref.read(authStateProvider).isAuthenticated;
    final api = ref.read(authApiProvider);
    final key = '$_kKeyPrefix$username';
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(key);
    if (cached != null) {
      state = _absolute(cached);
    }
    // 已登录时同步服务端头像（覆盖本地缓存，实现跨设备一致）
    if (!authed) return;
    try {
      final me = await api.me();
      final url = me['avatar_url'] as String?;
      state = url != null ? _absolute(url) : null;
      if (url != null) {
        await prefs.setString(key, url);
      } else {
        await prefs.remove(key);
      }
    } catch (_) {
      // 离线或服务端异常时沿用本地缓存
    }
  }

  /// 上传并设置头像：图片直传服务端，返回的 URL 持久化到本地。
  Future<void> setAvatar(String sourcePath) async {
    final url = await ref.read(authApiProvider).uploadAvatar(sourcePath);
    state = _absolute(url);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_kKeyPrefix$_username', url);
  }

  String _absolute(String url) =>
      url.startsWith('http') ? url : '${ref.read(apiBaseUrlProvider)}$url';
}
