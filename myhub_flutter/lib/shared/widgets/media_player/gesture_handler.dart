import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:media_kit/media_kit.dart';
import 'package:myhub_flutter/shared/utils/format.dart';
import 'package:myhub_flutter/shared/widgets/media_player/player_osd.dart';

/// 播放器手势识别层（TODO 5.4）。
///
/// * 水平滑动：调节进度（±10s 起，随滑动距离增加，满幅约 ±120s）；
/// * 右侧 1/3 竖滑：调节音量；
/// * 左侧 1/3 竖滑：调节亮度（软件调光，经 [onBrightnessChanged] 通知外部渲染遮罩）；
/// * 双击左/右半区：快退/快进 10s；
/// * 调节时经 [osd] 在屏幕中央悬浮胶囊实时反馈（图标 + 数值）。
///
/// 作为控制栏的根节点使用：单击经 [onTap] 切换控制栏显隐，
/// 任意调节手势经 [onInteraction] 通知外部重置自动隐藏计时。
/// 内部按钮/进度条等子组件在手势竞技中优先命中，互不冲突。
class PlayerGestureDetector extends StatefulWidget {
  const PlayerGestureDetector({
    super.key,
    required this.player,
    required this.osd,
    required this.child,
    this.onTap,
    this.onInteraction,
    this.onBrightnessChanged,
  });

  /// 已打开媒体的 Player。
  final Player player;

  /// 屏幕中央数值反馈通道（与键盘/按钮调节共用）。
  final PlayerOsd osd;

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

  PlayerOsd get _osd => widget.osd;

  // ---------- 双击快退/快进 ----------

  void _handleDoubleTap(double width) {
    final forward = _doubleTapX >= width / 2;
    final delta = Duration(seconds: forward ? _doubleTapSeekSec : -_doubleTapSeekSec);
    final target =
        _clampPosition(_player.state.position + delta, _player.state.duration);
    _player.seek(target);
    _osd.show(
      forward ? LucideIcons.fastForward : LucideIcons.rewind,
      '${forward ? '+' : '-'}$_doubleTapSeekSec'
      's  ${formatPlaybackTime(target)}',
    );
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
    _osd.showHold(
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
    _osd.dismiss();
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
        _osd.showHold(_volumeIcon(v), '${v.round()}%');
      case _VerticalMode.brightness:
        final b = (_vStartValue + delta).clamp(0.0, 1.0);
        _brightness = b;
        widget.onBrightnessChanged?.call(b);
        _osd.showHold(
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
    _osd.dismiss();
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
          onHorizontalDragCancel: _osd.dismiss,
          onVerticalDragStart: (d) => _startVertical(d, width),
          onVerticalDragUpdate: (d) => _updateVertical(d, height),
          onVerticalDragEnd: (_) => _endVertical(),
          onVerticalDragCancel: () {
            _vMode = _VerticalMode.none;
            _osd.dismiss();
          },
          // OSD 胶囊由控制栏统一挂载在顶层（键盘/按钮调节也要显示）
          child: widget.child,
        );
      },
    );
  }
}

enum _VerticalMode { none, volume, brightness }
