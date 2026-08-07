import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// 设备当前物理姿态（基于重力加速度计 X 轴）。
///
/// iOS/Android 上重力传感器静止时输出 [0, 0, 9.8]（设备平放），
/// 设备竖向握持时为 [0, 9.8, 0]，横向握持时为 ±9.8/0/0。
/// 横竖判定阈值：|x| > |y| 视为横屏，|y| > |x| 视为竖屏。
enum DeviceTilt { portrait, landscapeLeft, landscapeRight, flat }

DeviceTilt _tiltFrom(double x, double y) {
  // 阈值外认为是相对水平放置，方向不明确
  const double eps = 1.5;
  if (x.abs() < eps && y.abs() < eps) return DeviceTilt.flat;
  if (y.abs() >= x.abs()) return DeviceTilt.portrait;
  return x > 0 ? DeviceTilt.landscapeLeft : DeviceTilt.landscapeRight;
}

/// 播放器方向自动跟随（水平仪）监听器。
///
/// 仅在 `sensor` 模式下被 `MediaPlayerPage` 启用：
/// * 订阅 `accelerometerEventStream` 计算设备姿态；
/// * 去抖：相同姿态连续稳定 [stableMs] 后才下发，避免抖动；
/// * 提供 [currentTilt] 供 UI 查询。
class OrientationWatcher {
  /// 姿态稳定时间（连续保持才触发切换），用于去抖。
  final Duration stableMs;

  OrientationWatcher({this.stableMs = const Duration(milliseconds: 600)});

  final ValueNotifier<DeviceTilt> _tilt =
      ValueNotifier<DeviceTilt>(DeviceTilt.flat);

  StreamSubscription<AccelerometerEvent>? _sub;
  DeviceTilt _lastReported = DeviceTilt.flat;
  Timer? _stableTimer;

  /// 当前判定姿态。
  ValueListenable<DeviceTilt> get tiltListenable => _tilt;

  DeviceTilt get currentTilt => _tilt.value;

  /// 启动监听。
  void start() {
    if (_sub != null) return;
    if (kIsWeb) return;
    if (!Platform.isAndroid && !Platform.isIOS) return;
    _sub = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 200),
    ).listen(
      (e) => _onSample(e.x, e.y),
      onError: (_) {/* 传感器不可用时静默，回退为当前锁定方向 */},
      cancelOnError: false,
    );
  }

  void _onSample(double x, double y) {
    final t = _tiltFrom(x, y);
    if (t == _lastReported) {
      _stableTimer?.cancel();
      return;
    }
    // 进入新的可能姿态：等待 [stableMs] 仍保持才确认
    _stableTimer?.cancel();
    _stableTimer = Timer(stableMs, () {
      _lastReported = t;
      _tilt.value = t;
    });
  }

  /// 停止监听并释放计时器。
  Future<void> stop() async {
    _stableTimer?.cancel();
    _stableTimer = null;
    await _sub?.cancel();
    _sub = null;
  }
}

/// 根据姿态计算应锁定的方向列表。
///
/// 传感器命名与 Flutter 的 [DeviceOrientation] 一一对应：
/// * [DeviceTilt.landscapeLeft]  = 设备顶部朝左 → [DeviceOrientation.landscapeLeft]；
/// * [DeviceTilt.landscapeRight] = 设备顶部朝右 → [DeviceOrientation.landscapeRight]。
List<DeviceOrientation> orientationsFor(DeviceTilt tilt) {
  switch (tilt) {
    case DeviceTilt.portrait:
      return const [DeviceOrientation.portraitUp];
    case DeviceTilt.landscapeLeft:
      return const [DeviceOrientation.landscapeLeft];
    case DeviceTilt.landscapeRight:
      return const [DeviceOrientation.landscapeRight];
    case DeviceTilt.flat:
      // 设备近水平：保持上次（不变更）
      return const [];
  }
}
