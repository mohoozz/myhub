import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主题模式状态管理。
///
/// 功能：
/// * 亮/暗/跟随系统三态切换（跟随系统由 Flutter `ThemeMode.system` 内部
///   监听 `PlatformDispatcher.onPlatformBrightnessChanged` 实现）；
/// * 持久化到 `SharedPreferences`（启动时自动恢复）；
/// * 默认跟随系统。
final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  static const String _prefsKey = 'theme_mode';

  /// 标记用户已显式修改（防止异步恢复覆盖新值）。
  var _dirty = false;

  @override
  ThemeMode build() {
    _restore();
    return ThemeMode.system;
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    if (_dirty) return;
    final saved = prefs.getString(_prefsKey);
    final restored = switch (saved) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    if (restored != state) {
      state = restored;
    }
  }

  /// 设置主题模式并持久化。
  Future<void> setMode(ThemeMode mode) async {
    _dirty = true;
    if (mode == state) return;
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, mode.name);
  }

  /// 亮/暗切换（侧边栏按钮）。当前亮色 → 暗色，否则 → 亮色。
  Future<void> toggle(Brightness currentBrightness) {
    return setMode(
      currentBrightness == Brightness.dark ? ThemeMode.light : ThemeMode.dark,
    );
  }
}

/// 沉浸式场景标记（播放器/阅读器等纯黑沉浸页）。
///
/// 置为 `true` 时 [effectiveThemeModeProvider] 强制返回暗色，
/// 退出沉浸页时应恢复为 `false`。
final immersiveThemeProvider = StateProvider<bool>((ref) => false);

/// MaterialApp 实际使用的主题模式：沉浸式场景自动强制暗色。
final effectiveThemeModeProvider = Provider<ThemeMode>((ref) {
  if (ref.watch(immersiveThemeProvider)) {
    return ThemeMode.dark;
  }
  return ref.watch(themeModeProvider);
});
