import 'dart:async';
import 'dart:ui';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

/// 记忆桌面窗口的位置和尺寸，下次启动时按上次的 bounds 恢复。
class WindowBoundsMemory with WindowListener {
  WindowBoundsMemory._();

  static final WindowBoundsMemory instance = WindowBoundsMemory._();

  static const _kX = 'window_bounds_x';
  static const _kY = 'window_bounds_y';
  static const _kW = 'window_bounds_width';
  static const _kH = 'window_bounds_height';

  Timer? _debounce;

  /// 在 `windowManager.ensureInitialized()` 之后调用：
  /// 恢复上次保存的窗口 bounds，并监听移动/缩放以持续保存。
  Future<void> init(SharedPreferences prefs) async {
    await _restore(prefs);
    windowManager.addListener(this);
  }

  Future<void> _restore(SharedPreferences prefs) async {
    final width = prefs.getDouble(_kW);
    final height = prefs.getDouble(_kH);
    if (width == null || height == null) return;

    // 尺寸优先恢复；位置只有在上次保存过时才恢复（否则由系统居中）。
    await windowManager.setSize(Size(width, height));
    final x = prefs.getDouble(_kX);
    final y = prefs.getDouble(_kY);
    if (x != null && y != null) {
      await windowManager.setPosition(Offset(x, y));
    }
  }

  Future<void> _save() async {
    // 最大化/全屏时不覆盖记忆的正常窗口 bounds
    if (await windowManager.isMaximized() ||
        await windowManager.isFullScreen()) {
      return;
    }
    final bounds = await windowManager.getBounds();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kX, bounds.left);
    await prefs.setDouble(_kY, bounds.top);
    await prefs.setDouble(_kW, bounds.width);
    await prefs.setDouble(_kH, bounds.height);
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _save);
  }

  @override
  void onWindowMoved() => _scheduleSave();

  @override
  void onWindowResized() => _scheduleSave();
}
