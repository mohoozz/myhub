import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:media_kit/media_kit.dart';
import 'package:myhub_flutter/core/settings/settings_provider.dart';
import 'package:myhub_flutter/shared/utils/format.dart';
import 'package:myhub_flutter/shared/widgets/media_player/gesture_handler.dart';

/// 控制栏无操作自动隐藏延时。
const Duration _kHideDelay = Duration(seconds: 3);

/// 自定义播放器控制栏 Overlay（TODO 5.2）。
///
/// 覆盖在播放画面之上：
/// * 顶栏：返回 + 文件名；
/// * 中央大按钮：播放/暂停；
/// * 底栏：播放/暂停、时间、进度条（缓冲叠加）、倍速、音量、全屏；
/// * 轻触画面切换显隐，播放中 [_kHideDelay] 无操作自动隐藏（暂停时常显），
///   桌面端鼠标移动自动唤醒。
class PlayerControls extends StatefulWidget {
  const PlayerControls({
    super.key,
    required this.player,
    required this.title,
    required this.onBack,
    this.loading = false,
    this.onToggleFullscreen,
    this.isFullscreen = false,
  });

  /// 已打开媒体的 media_kit Player。
  final Player player;

  /// 顶栏显示的文件名。
  final String title;

  /// 返回上一页。
  final VoidCallback onBack;

  /// 首次加载中：隐藏中央大按钮（顶/底栏仍可用，可返回）。
  final bool loading;

  /// 系统全屏切换（桌面端）；为 null 时隐藏全屏按钮（移动端）。
  final VoidCallback? onToggleFullscreen;

  /// 当前是否系统全屏。
  final bool isFullscreen;

  @override
  State<PlayerControls> createState() => _PlayerControlsState();
}

class _PlayerControlsState extends State<PlayerControls> {
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _hideTimer;

  bool _visible = true;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  double _rate = 1.0;
  double _volume = 100;

  /// 可用字幕轨（已过滤 auto/no 伪轨）。
  List<SubtitleTrack> _subTracks = const [];

  /// 当前选中的字幕轨。
  SubtitleTrack? _currentSub;

  /// 静音前音量，用于取消静音时恢复。
  double _volumeBeforeMute = 100;

  /// 软件调光亮度（1.0 = 不遮罩），由 5.4 手势层调节。
  double _brightness = 1.0;

  /// 拖拽进度条时的预览位置（null = 未拖拽）。
  Duration? _dragPosition;

  Player get _player => widget.player;

  @override
  void initState() {
    super.initState();
    // 初始值取当前状态，后续由流驱动
    _playing = _player.state.playing;
    _position = _player.state.position;
    _duration = _player.state.duration;
    _buffered = _player.state.buffer;
    _rate = _player.state.rate;
    _volume = _player.state.volume;
    _subTracks = _realSubTracks(_player.state.tracks.subtitle);
    _currentSub = _player.state.track.subtitle;

    _subs.addAll([
      _player.stream.playing.listen((v) {
        if (!mounted) return;
        setState(() {
          _playing = v;
          if (!v) _visible = true; // 暂停时常显
        });
        if (v) {
          _startHideTimer();
        } else {
          _hideTimer?.cancel();
        }
      }),
      _player.stream.position.listen((p) {
        if (!mounted) return;
        setState(() => _position = p);
      }),
      _player.stream.duration.listen((d) {
        if (!mounted) return;
        setState(() => _duration = d);
      }),
      _player.stream.buffer.listen((b) {
        if (!mounted) return;
        setState(() => _buffered = b);
      }),
      _player.stream.rate.listen((r) {
        if (!mounted) return;
        setState(() => _rate = r);
      }),
      _player.stream.volume.listen((v) {
        if (!mounted) return;
        setState(() => _volume = v);
      }),
      _player.stream.tracks.listen((t) {
        if (!mounted) return;
        setState(() => _subTracks = _realSubTracks(t.subtitle));
      }),
      _player.stream.track.listen((t) {
        if (!mounted) return;
        setState(() => _currentSub = t.subtitle);
      }),
    ]);
    _startHideTimer();
  }

  /// 过滤 media_kit 附加的 auto/no 伪轨，只留真实字幕轨。
  static List<SubtitleTrack> _realSubTracks(List<SubtitleTrack> tracks) {
    return [
      for (final t in tracks)
        if (t.id != 'auto' && t.id != 'no') t,
    ];
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }

  // ---------- 显隐控制 ----------

  void _startHideTimer() {
    _hideTimer?.cancel();
    if (!_playing) return; // 暂停时不自动隐藏
    _hideTimer = Timer(_kHideDelay, () {
      if (mounted && _playing) {
        setState(() => _visible = false);
      }
    });
  }

  /// 任意交互时调用：显示控制栏并重置隐藏计时。
  void _wake() {
    if (!_visible) {
      setState(() => _visible = true);
    }
    _startHideTimer();
  }

  void _toggleVisible() {
    setState(() => _visible = !_visible);
    if (_visible) {
      _startHideTimer();
    } else {
      _hideTimer?.cancel();
    }
  }

  // ---------- 播放动作 ----------

  void _togglePlay() {
    _player.playOrPause();
    _wake();
  }

  void _seekTo(Duration d) {
    setState(() {
      _dragPosition = null;
      _position = d;
    });
    _player.seek(d);
    _wake();
  }

  void _setVolume(double v) {
    _player.setVolume(v);
    if (v > 0) _volumeBeforeMute = v;
    _wake();
  }

  void _toggleMute() {
    if (_volume > 0) {
      _player.setVolume(0);
    } else {
      _player.setVolume(_volumeBeforeMute > 0 ? _volumeBeforeMute : 100);
    }
    _wake();
  }

  static String _speedLabel(double s) => playbackSpeedLabel(s);

  IconData get _volumeIcon {
    if (_volume <= 0) return LucideIcons.volumeX;
    if (_volume < 50) return LucideIcons.volume1;
    return LucideIcons.volume2;
  }

  /// 倍速选择 BottomSheet。
  void _showSpeedSheet() {
    _wake();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF141414),
      builder: (sheetContext) {
        final primary = Theme.of(sheetContext).colorScheme.primary;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final s in kPlaybackSpeeds)
                ListTile(
                  dense: true,
                  title: Text(
                    _speedLabel(s),
                    style: TextStyle(
                      color: s == _rate ? primary : Colors.white,
                      fontSize: 14,
                    ),
                  ),
                  trailing: s == _rate
                      ? Icon(LucideIcons.check, size: 18, color: primary)
                      : null,
                  onTap: () {
                    _player.setRate(s);
                    Navigator.of(sheetContext).pop();
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  /// 字幕轨显示名：优先 mpv 轨标题（外挂字幕为文件名），其次语言码。
  static String _subLabel(SubtitleTrack t) {
    final title = t.title?.trim();
    if (title != null && title.isNotEmpty) return title;
    final lang = t.language?.trim();
    if (lang != null && lang.isNotEmpty && lang != 'auto') return lang;
    return '字幕 ${t.id}';
  }

  /// 字幕轨切换 BottomSheet（5.6）。
  void _showSubtitleSheet() {
    _wake();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF141414),
      builder: (sheetContext) {
        final primary = Theme.of(sheetContext).colorScheme.primary;
        final off = _currentSub == null ||
            _currentSub!.id == 'no' ||
            _currentSub!.id == 'auto';
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                dense: true,
                title: Text(
                  '关闭字幕',
                  style: TextStyle(
                    color: off ? primary : Colors.white,
                    fontSize: 14,
                  ),
                ),
                trailing: off
                    ? Icon(LucideIcons.check, size: 18, color: primary)
                    : null,
                onTap: () {
                  _player.setSubtitleTrack(SubtitleTrack.no());
                  Navigator.of(sheetContext).pop();
                },
              ),
              for (final track in _subTracks)
                ListTile(
                  dense: true,
                  title: Text(
                    _subLabel(track),
                    style: TextStyle(
                      color:
                          _currentSub?.id == track.id ? primary : Colors.white,
                      fontSize: 14,
                    ),
                  ),
                  trailing: _currentSub?.id == track.id
                      ? Icon(LucideIcons.check, size: 18, color: primary)
                      : null,
                  onTap: () {
                    _player.setSubtitleTrack(track);
                    Navigator.of(sheetContext).pop();
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  // ---------- 构建 ----------

  /// 控制栏显隐过渡包装：隐藏时透明且不响应指针。
  Widget _fade(Widget child) {
    return IgnorePointer(
      ignoring: !_visible,
      child: AnimatedOpacity(
        opacity: _visible ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      // 桌面端：鼠标移动唤醒控制栏
      onHover: (_) => _wake(),
      child: PlayerGestureDetector(
        player: _player,
        // 轻触画面：切换控制栏显隐
        onTap: _toggleVisible,
        // 调节手势：重置自动隐藏计时
        onInteraction: _wake,
        onBrightnessChanged: (b) => setState(() => _brightness = b),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 亮度遮罩（软件调光，由 5.4 左侧竖滑调节）
            if (_brightness < 1)
              IgnorePointer(
                child: Container(
                  color: Colors.black.withValues(alpha: 1.0 - _brightness),
                ),
              ),
            // 顶栏：返回 + 文件名
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _fade(_buildTopBar(context)),
            ),
            // 中央大按钮：播放/暂停（加载中不显示）
            Center(
              child: IgnorePointer(
                ignoring: !_visible || widget.loading,
                child: AnimatedOpacity(
                  opacity: _visible && !widget.loading ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Material(
                    color: Colors.black45,
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: _togglePlay,
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Icon(
                          _playing ? LucideIcons.pause : LucideIcons.play,
                          size: 42,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 底栏
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _fade(_buildBottomBar(context)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(LucideIcons.arrowLeft, color: Colors.white),
              tooltip: '返回',
              onPressed: widget.onBack,
            ),
            Expanded(
              child: Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
            ),
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(BuildContext context) {
    const timeStyle = TextStyle(
      color: Colors.white70,
      fontSize: 12,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    final shownPosition = _dragPosition ?? _position;
    // 宽屏内嵌音量滑块；窄屏仅保留静音按钮（移动端音量走 5.4 手势）
    final showVolumeSlider = MediaQuery.sizeOf(context).width >= 560;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 20, 4, 4),
          child: Row(
            children: [
              IconButton(
                iconSize: 26,
                color: Colors.white,
                icon: Icon(_playing ? LucideIcons.pause : LucideIcons.play),
                onPressed: _togglePlay,
              ),
              Text(formatPlaybackTime(shownPosition), style: timeStyle),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: _ProgressBar(
                    position: shownPosition,
                    buffered: _buffered,
                    duration: _duration,
                    onDragUpdate: (d) {
                      setState(() => _dragPosition = d);
                      _wake();
                    },
                    onSeek: _seekTo,
                  ),
                ),
              ),
              Text(formatPlaybackTime(_duration), style: timeStyle),
              // 倍速
              TextButton(
                onPressed: _showSpeedSheet,
                child: Text(
                  _speedLabel(_rate),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
              // 字幕轨切换（存在字幕轨时显示）
              if (_subTracks.isNotEmpty)
                IconButton(
                  iconSize: 20,
                  color: Colors.white,
                  tooltip: '字幕',
                  icon: const Icon(LucideIcons.subtitles),
                  onPressed: _showSubtitleSheet,
                ),
              // 音量
              IconButton(
                iconSize: 20,
                color: Colors.white,
                tooltip: _volume > 0 ? '静音' : '取消静音',
                icon: Icon(_volumeIcon),
                onPressed: _toggleMute,
              ),
              if (showVolumeSlider)
                SizedBox(
                  width: 96,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2,
                      activeTrackColor: Colors.white,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: Colors.white,
                      overlayColor: Colors.white24,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 5),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 10),
                    ),
                    child: Slider(
                      value: (_volume / 100).clamp(0.0, 1.0),
                      onChanged: (v) => _setVolume(v * 100),
                    ),
                  ),
                ),
              // 全屏切换（桌面端）
              if (widget.onToggleFullscreen != null)
                IconButton(
                  iconSize: 20,
                  color: Colors.white,
                  tooltip: widget.isFullscreen ? '退出全屏' : '全屏',
                  icon: Icon(widget.isFullscreen
                      ? LucideIcons.minimize
                      : LucideIcons.maximize),
                  onPressed: widget.onToggleFullscreen,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 进度条：底轨 + 缓冲区间 + 已播放 + 滑块，支持点按/拖拽 seek。
class _ProgressBar extends StatefulWidget {
  const _ProgressBar({
    required this.position,
    required this.buffered,
    required this.duration,
    required this.onDragUpdate,
    required this.onSeek,
  });

  /// 已播放位置（拖拽期间为拖拽预览值）。
  final Duration position;

  /// 缓冲末端位置。
  final Duration buffered;

  /// 总时长（<= 0 视为未知，禁止 seek）。
  final Duration duration;

  /// 拖拽中回调（null = 拖拽结束/取消）。
  final ValueChanged<Duration?> onDragUpdate;

  /// 拖拽结束或点按后的 seek 目标。
  final ValueChanged<Duration> onSeek;

  @override
  State<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<_ProgressBar> {
  static const double _trackHeight = 3;
  static const double _thumbRadius = 5;

  double? _dragFrac;

  bool get _seekable => widget.duration > Duration.zero;

  Duration _durationOf(double frac) => Duration(
        milliseconds: (frac * widget.duration.inMilliseconds).round(),
      );

  double _fracOf(double dx, double width) =>
      width <= 0 ? 0 : (dx / width).clamp(0.0, 1.0);

  void _updateDrag(double dx, double width) {
    final frac = _fracOf(dx, width);
    setState(() => _dragFrac = frac);
    widget.onDragUpdate(_durationOf(frac));
  }

  void _endDrag() {
    final frac = _dragFrac;
    setState(() => _dragFrac = null);
    widget.onDragUpdate(null);
    if (frac != null) {
      widget.onSeek(_durationOf(frac));
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalMs = widget.duration.inMilliseconds;
    final playedFrac = !_seekable
        ? 0.0
        : (_dragFrac ?? widget.position.inMilliseconds / totalMs)
            .clamp(0.0, 1.0);
    final bufferFrac = !_seekable
        ? 0.0
        : (widget.buffered.inMilliseconds / totalMs).clamp(0.0, 1.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final thumbLeft =
            (playedFrac * width - _thumbRadius).clamp(0.0, width);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: _seekable
              ? (d) => widget.onSeek(_durationOf(
                    _fracOf(d.localPosition.dx, width),
                  ))
              : null,
          onHorizontalDragStart: _seekable
              ? (d) => _updateDrag(d.localPosition.dx, width)
              : null,
          onHorizontalDragUpdate: _seekable
              ? (d) => _updateDrag(d.localPosition.dx, width)
              : null,
          onHorizontalDragEnd: _seekable ? (_) => _endDrag() : null,
          onHorizontalDragCancel: _seekable
              ? () {
                  setState(() => _dragFrac = null);
                  widget.onDragUpdate(null);
                }
              : null,
          child: SizedBox(
            height: 24,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                // 底轨
                Container(height: _trackHeight, color: Colors.white24),
                // 缓冲区间
                FractionallySizedBox(
                  widthFactor: bufferFrac,
                  child: Container(
                    height: _trackHeight,
                    color: Colors.white38,
                  ),
                ),
                // 已播放
                FractionallySizedBox(
                  widthFactor: playedFrac,
                  child: Container(
                    height: _trackHeight,
                    color: Colors.white,
                  ),
                ),
                // 滑块
                Positioned(
                  left: thumbLeft,
                  child: Container(
                    width: _thumbRadius * 2,
                    height: _thumbRadius * 2,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
