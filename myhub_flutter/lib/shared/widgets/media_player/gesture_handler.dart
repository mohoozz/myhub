import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:media_kit/media_kit.dart';
import 'package:myhub_flutter/shared/utils/format.dart';

/// 播放器手势识别层（TODO 5.4）。
///
/// * 水平滑动：调节进度（±10s 起，随滑动距离增加，满幅约 ±120s）；
/// * 右侧 1/3 竖滑：调节音量；
/// * 左侧 1/3 竖滑：调节亮度（软件调光，经 [onBrightnessChanged] 通知外部渲染遮罩）；
/// * 双击左/右半区：快退/快进 10s；
/// * 调节时屏幕中央悬浮胶囊实时反馈（图标 + 数值）。
///
/// 作为控制栏的根节点使用：单击经 [onTap] 切换控制栏显隐，
/// 任意调节手势经 [onInteraction] 通知外部重置自动隐藏计时。
/// 内部按钮/进度条等子组件在手势竞技中优先命中，互不冲突。
class PlayerGestureDetector extends StatefulWidget {
  const PlayerGestureDetector({
    super.key,
    required this.player,
    required this.child,
    this.onTap,
    this.onInteraction,
    this.onBrightnessChanged,
  });

  /// 已打开媒体的 Player。
  final Player player;

  /// 控制栏内容（顶/底栏、中央按钮等）。
  final Widget child;

  /// 单击（显隐控制栏）。
  final VoidCallback? onTap;

  /// 任意调节手势发生（重置控制栏自动隐藏计时）。
  final VoidCallback? onInteraction;

  /// 亮度变化（0.0 ~ 1.0，软件调光遮罩由外部渲染）。
  final ValueChanged<double>? onBrightnessChanged;

  @override
  State<PlayerGestureDetector> createState() =>
      _PlayerGestureDetectorState();
}

class _PlayerGestureDetectorState extends State<PlayerGestureDetector> {
  /// 水平滑动 seek：起步 ±10s。
  static const double _seekBaseSec = 10;

  /// 水平滑动 seek：满幅约 ±120s。
  static const double _seekFullSec = 120;

  /// 双击快退/快进秒数。
  static const int _doubleTapSeekSec = 10;

  Timer? _feedbackTimer;
  ({IconData icon, String text})? _feedback;

  // 水平拖动 seek 状态
  double _dragStartX = 0;
  Duration _seekStart = Duration.zero;
  Duration? _seekTarget;

  // 竖直拖动状态
  _VerticalMode _vMode = _VerticalMode.none;
  double _vStartY = 0;
  double _vStartValue = 0;

  /// 当前亮度（0.0 ~ 1.0，1.0 为不遮罩）。
  double _brightness = 1.0;

  /// 双击落点横坐标（onDoubleTap 不带位置，由 onDoubleTapDown 记录）。
  double _doubleTapX = 0;

  Player get _player => widget.player;

  @override
  void dispose() {
    _feedbackTimer?.cancel();
    super.dispose();
  }

  // ---------- 悬浮胶囊 ----------

  void _showFeedback(IconData icon, String text) {
    _feedbackTimer?.cancel();
    setState(() => _feedback = (icon: icon, text: text));
  }

  void _dismissFeedbackLater([
    Duration delay = const Duration(milliseconds: 600),
  ]) {
    _feedbackTimer?.cancel();
    _feedbackTimer = Timer(delay, () {
      if (mounted) {
        setState(() => _feedback = null);
      }
    });
  }

  // ---------- 双击快退/快进 ----------

  void _handleDoubleTap(double width) {
    final forward = _doubleTapX >= width / 2;
    final delta = Duration(seconds: forward ? _doubleTapSeekSec : -_doubleTapSeekSec);
    final target =
        _clampPosition(_player.state.position + delta, _player.state.duration);
    _player.seek(target);
    _showFeedback(
      forward ? LucideIcons.fastForward : LucideIcons.rewind,
      '${forward ? '+' : '-'}$_doubleTapSeekSec'
      's  ${formatPlaybackTime(target)}',
    );
    _dismissFeedbackLater();
    widget.onInteraction?.call();
  }

  // ---------- 水平滑动调节进度 ----------

  void _startSeek(DragStartDetails d) {
    _dragStartX = d.localPosition.dx;
    _seekStart = _player.state.position;
    _seekTarget = null;
  }

  void _updateSeek(DragUpdateDetails d, double width) {
    if (width <= 0) return;
    final dx = d.localPosition.dx - _dragStartX;
    if (dx == 0) return;
    final seconds =
        dx.sign * (_seekBaseSec + (dx.abs() / width) * (_seekFullSec - _seekBaseSec));
    final target = _clampPosition(
      _seekStart + Duration(milliseconds: (seconds * 1000).round()),
      _player.state.duration,
    );
    _seekTarget = target;
    _showFeedback(
      seconds >= 0 ? LucideIcons.fastForward : LucideIcons.rewind,
      '${seconds >= 0 ? '+' : '-'}${seconds.abs().round()}s  ${formatPlaybackTime(target)}',
    );
    widget.onInteraction?.call();
  }

  void _endSeek() {
    final target = _seekTarget;
    if (target != null) {
      _player.seek(target);
    }
    _seekTarget = null;
    _dismissFeedbackLater();
  }

  Duration _clampPosition(Duration pos, Duration duration) {
    if (pos < Duration.zero) return Duration.zero;
    if (duration > Duration.zero && pos > duration) return duration;
    return pos;
  }

  // ---------- 竖直滑动调节音量/亮度 ----------

  void _startVertical(DragStartDetails d, double width) {
    _vStartY = d.localPosition.dy;
    if (d.localPosition.dx >= width * 2 / 3) {
      _vMode = _VerticalMode.volume;
      _vStartValue = _player.state.volume;
    } else if (d.localPosition.dx <= width / 3) {
      _vMode = _VerticalMode.brightness;
      _vStartValue = _brightness;
    } else {
      _vMode = _VerticalMode.none;
    }
  }

  void _updateVertical(DragUpdateDetails d, double height) {
    if (_vMode == _VerticalMode.none || height <= 0) return;
    // 上滑增大、下滑减小；满幅滑动 = 满量程
    final delta = (_vStartY - d.localPosition.dy) / height;
    switch (_vMode) {
      case _VerticalMode.volume:
        final v = (_vStartValue + delta * 100).clamp(0.0, 100.0);
        _player.setVolume(v);
        _showFeedback(_volumeIcon(v), '${v.round()}%');
      case _VerticalMode.brightness:
        final b = (_vStartValue + delta).clamp(0.0, 1.0);
        _brightness = b;
        widget.onBrightnessChanged?.call(b);
        _showFeedback(
          b > 0.5 ? LucideIcons.sun : LucideIcons.sunDim,
          '${(b * 100).round()}%',
        );
      case _VerticalMode.none:
        break;
    }
    widget.onInteraction?.call();
  }

  void _endVertical() {
    _vMode = _VerticalMode.none;
    _dismissFeedbackLater();
  }

  IconData _volumeIcon(double v) {
    if (v <= 0) return LucideIcons.volumeX;
    if (v < 50) return LucideIcons.volume1;
    return LucideIcons.volume2;
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: widget.onTap,
          onDoubleTapDown: (d) => _doubleTapX = d.localPosition.dx,
          onDoubleTap: () => _handleDoubleTap(width),
          onHorizontalDragStart: _startSeek,
          onHorizontalDragUpdate: (d) => _updateSeek(d, width),
          onHorizontalDragEnd: (_) => _endSeek(),
          onHorizontalDragCancel: _dismissFeedbackLater,
          onVerticalDragStart: (d) => _startVertical(d, width),
          onVerticalDragUpdate: (d) => _updateVertical(d, height),
          onVerticalDragEnd: (_) => _endVertical(),
          onVerticalDragCancel: () {
            _vMode = _VerticalMode.none;
            _dismissFeedbackLater();
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              widget.child,
              if (_feedback != null)
                IgnorePointer(
                  child: Center(
                    child: _FeedbackCapsule(feedback: _feedback!),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

enum _VerticalMode { none, volume, brightness }

/// 屏幕中央悬浮胶囊：图标 + 数值，调节手势期间实时反馈。
class _FeedbackCapsule extends StatelessWidget {
  const _FeedbackCapsule({required this.feedback});

  final ({IconData icon, String text}) feedback;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(feedback.icon, size: 18, color: Colors.white),
          const SizedBox(width: 10),
          Text(
            feedback.text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
