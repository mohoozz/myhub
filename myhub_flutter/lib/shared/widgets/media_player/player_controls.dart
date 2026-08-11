import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:media_kit/media_kit.dart';
import 'package:myhub_flutter/core/settings/settings_provider.dart';
import 'package:myhub_flutter/shared/providers/av_player_adapter.dart';
import 'package:myhub_flutter/shared/utils/format.dart';
import 'package:myhub_flutter/shared/widgets/media_player/gesture_handler.dart';
import 'package:myhub_flutter/shared/widgets/media_player/player_osd.dart';

/// 控制栏无操作自动隐藏延时。
const Duration _kHideDelay = Duration(seconds: 3);

/// 自定义播放器控制栏 Overlay（TODO 5.2）。
///
/// 覆盖在播放画面之上：
/// * 顶栏：退出（停止播放）+ 文件名；
/// * 中央大按钮：播放/暂停；
/// * 底栏：播放/暂停、时间、进度条（缓冲叠加）、倍速、音量、
///   迷你播放、全屏；
/// * 轻触画面切换显隐，播放中 [_kHideDelay] 无操作自动隐藏（暂停时常显），
///   桌面端鼠标移动自动唤醒；
/// * 锁定态下锁图标同样按 [_kHideDelay] 自动隐藏，点击屏幕唤醒重新显示。
class PlayerControls extends StatefulWidget {
  const PlayerControls({
    super.key,
    required this.player,
    required this.title,
    required this.onBack,
    required this.osd,
    this.loading = false,
    this.buffering = false,
    this.onMini,
    this.onMiniDrag,
    this.onMiniDragEnd,
    this.onToggleFullscreen,
    this.isFullscreen = false,
    this.orientation,
    this.onToggleOrientation,
  });

  /// 已打开媒体的播放器（media_kit Player 或 AvPlayerAdapter）。
  final dynamic player;

  /// 顶栏显示的文件名。
  final String title;

  /// 返回上一页。
  final VoidCallback onBack;

  /// 屏幕中央数值反馈通道（键盘/按钮/手势调节共用）。
  final PlayerOsd osd;

  /// 首次加载中：隐藏中央大按钮（顶/底栏仍可用，可返回）。
  final bool loading;

  /// 播放中缓冲：隐藏中央大按钮，避免与页面级缓冲转圈重叠。
  final bool buffering;

  /// 进入迷你模式：退出播放页但保持播放（底部迷你条接管）。
  /// 为 null 时隐藏迷你按钮。
  final VoidCallback? onMini;

  /// 移动端：中间区域向下拖动进入迷你模式的拖动进度（0~1）。
  /// 为 null 时手势层中间区域不识别拖拽。
  final ValueChanged<double>? onMiniDrag;

  /// 移动端：迷你拖拽松手时的最终进度（页面据此判定进入迷你或回弹）。
  final ValueChanged<double>? onMiniDragEnd;

  /// 系统全屏切换（桌面端）；为 null 时隐藏全屏按钮（移动端）。
  final VoidCallback? onToggleFullscreen;

  /// 当前是否系统全屏。
  final bool isFullscreen;

  /// 当前方向偏好（仅移动端显示方向切换悬浮按钮）。
  final PlayerOrientation? orientation;

  /// 方向切换回调（点击在 portrait ↔ landscape 之间切换）；
  /// 视频模式专属。null 时不渲染悬浮按钮。
  final VoidCallback? onToggleOrientation;

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

  /// 锁定状态：长按进入，屏蔽所有手势与调节按钮，中央仅剩锁图标。
  bool _locked = false;

  dynamic get _player => widget.player;

  @override
  void initState() {
    super.initState();
    // 初始值取当前状态，后续由流驱动
    final state = _player.state;
    _playing = state.playing as bool;
    _position = state.position as Duration;
    _duration = state.duration as Duration;
    _buffered = state.buffer as Duration;
    _rate = state.rate as double;
    _volume = state.volume as double;
    _subTracks = _realSubTracks((state.tracks as Tracks).subtitle);
    _currentSub = (state.track as Track).subtitle;

    final stream = _player.stream;
    _subs.addAll([
      (stream.playing as Stream<bool>).listen((v) {
        if (!mounted) return;
        setState(() => _playing = v);
        if (!v) {
          _setVisible(true); // 暂停时常显
          _hideTimer?.cancel();
        } else {
          _startHideTimer();
        }
      }),
      (stream.position as Stream<Duration>).listen((p) {
        if (!mounted) return;
        setState(() => _position = p);
      }),
      (stream.duration as Stream<Duration>).listen((d) {
        if (!mounted) return;
        setState(() => _duration = d);
      }),
      (stream.buffer as Stream<Duration>).listen((b) {
        if (!mounted) return;
        setState(() => _buffered = b);
      }),
      (stream.rate as Stream<double>).listen((r) {
        if (!mounted) return;
        setState(() => _rate = r);
      }),
      (stream.volume as Stream<double>).listen((v) {
        if (!mounted) return;
        setState(() => _volume = v);
      }),
      (stream.tracks as Stream<Tracks>).listen((t) {
        if (!mounted) return;
        setState(() => _subTracks = _realSubTracks(t.subtitle));
      }),
      (stream.track as Stream<Track>).listen((t) {
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
    // 锁定态同样参与自动隐藏：锁图标显示一段时间后自动隐藏，
    // 点击屏幕（onTap 唤醒）后再次显示。
    _hideTimer = Timer(_kHideDelay, () {
      if (mounted && _playing) {
        _setVisible(false);
      }
    });
  }

  /// 任意交互时调用：显示控制栏并重置隐藏计时。
  void _wake() {
    if (!_visible) {
      _setVisible(true);
    }
    _startHideTimer();
  }

  void _toggleVisible() {
    // 锁定态下不切换显隐（锁图标的显隐由 _wake / 自动隐藏计时控制，
    // build 中锁定态 onTap 已改走 _wake，此处保留为防御）。
    if (_locked) return;
    _setVisible(!_visible);
    if (_visible) {
      _startHideTimer();
    } else {
      _hideTimer?.cancel();
    }
  }

  /// 设置控制栏显隐（统一出口，便于后续扩展联动）。
  void _setVisible(bool v) {
    if (_visible == v) return;
    setState(() => _visible = v);
  }

  // ---------- 锁定 ----------

  /// 长按进入锁定：屏蔽手势与调节按钮，中央仅留锁图标。
  /// 锁图标同样按播放状态自动隐藏（3s 无操作），点击屏幕后唤醒显示。
  void _lock() {
    _hideTimer?.cancel();
    setState(() => _locked = true);
    _setVisible(true);
    _startHideTimer();
  }

  /// 点击中央锁图标解锁：恢复手势与按钮，重新开始自动隐藏计时。
  void _unlock() {
    setState(() => _locked = false);
    _setVisible(true);
    _startHideTimer();
  }

  // ---------- 播放动作 ----------

  void _togglePlay() {
    final p = _player;
    // media_kit（非 iOS）：播放完成后 mpv 停在末尾，playOrPause() 只切
    // pause 属性不会重播，需先 seek 回起点。
    // iOS AVPlayer 模式的重播已由原生层处理（didReachEnd）。
    if (p is AvPlayerAdapter) {
      p.playOrPause();
    } else if (p.state.completed as bool) {
      p.seek(Duration.zero);
      p.play();
    } else {
      p.playOrPause();
    }
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
    widget.osd.show(_volumeIconFor(v), '${v.round()}%');
    _wake();
  }

  void _toggleMute() {
    if (_volume > 0) {
      // 记住静音前音量：否则取消静音会恢复到初始值（100）而非当前音量，
      // 进入播放器时音量与系统一致后，静音再取消会突然跳到 100。
      _volumeBeforeMute = _volume;
      _player.setVolume(0);
      widget.osd.show(LucideIcons.volumeX, '静音');
    } else {
      final v = _volumeBeforeMute > 0 ? _volumeBeforeMute : 100.0;
      _player.setVolume(v);
      widget.osd.show(_volumeIconFor(v), '${v.round()}%');
    }
    _wake();
  }

  static IconData _volumeIconFor(double v) {
    if (v <= 0) return LucideIcons.volumeX;
    if (v < 50) return LucideIcons.volume1;
    return LucideIcons.volume2;
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
                    widget.osd.show(LucideIcons.gauge, _speedLabel(s));
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
        final off =
            _currentSub == null ||
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
                      color: _currentSub?.id == track.id
                          ? primary
                          : Colors.white,
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
        osd: widget.osd,
        // 轻触画面：切换控制栏显隐；锁定态下改为唤醒——
        // 锁图标自动隐藏后，点击屏幕重新显示（并重置隐藏计时）。
        onTap: _locked ? _wake : _toggleVisible,
        // 长按进入锁定
        onLongPress: _lock,
        // 锁定态屏蔽全部手势
        enabled: !_locked,
        // 调节手势：重置自动隐藏计时
        onInteraction: _wake,
        onBrightnessChanged: (b) {
          setState(() => _brightness = b);
          // iOS AVPlayer 模式：亮度同步到系统亮度（双向同步）
          final p = _player;
          if (p is AvPlayerAdapter) {
            p.setBrightness(b);
          }
        },
        onMiniDrag: widget.onMiniDrag,
        onMiniDragEnd: widget.onMiniDragEnd,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 亮度遮罩（软件调光，由 5.4 左侧竖滑调节）。
            // iOS AVPlayer 模式不渲染：亮度已直接同步系统屏幕亮度（物理
            // 调暗），叠加遮罩会双重调暗，且进入播放器时 _brightness 与
            // 系统亮度脱节会导致首次调节时画面突然变暗。
            // Android/media_kit 为纯软件调光，保留遮罩。
            if (_brightness < 1 && _player is! AvPlayerAdapter)
              IgnorePointer(
                child: Container(
                  color: Colors.black.withValues(alpha: 1.0 - _brightness),
                ),
              ),
            // 顶栏：返回 + 文件名（锁定态隐藏，防止误触退出）
            if (!_locked)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _fade(_buildTopBar(context)),
              ),
            // 中央锁定解锁按钮：仅锁定态显示锁图标（点击解锁）。
            // 已移除中央大播放/暂停按钮（播放/暂停由底栏按钮与手势控制，
            // 避免遮挡画面中央）。
            // 包裹 _fade 跟随控制栏显隐：自动隐藏后点击屏幕（onTap 唤醒）
            // 重新显示。
            if (_locked) Center(child: _fade(_buildUnlockButton())),
            // 方向切换悬浮按钮（仅移动端）：贴屏幕左侧中部显示，
            // 跟随控制栏显隐（轻触画面/暂停时显，自动隐藏延时到时隐）。
            // SafeArea 只保留左侧 inset：iPhone 横屏时刘海/Dynamic Island
            // 位于屏幕左边缘正中（inset 约 59），不避开会把按钮完全挡住。
            // 锁定时隐藏方向按钮，避免误触与视觉干扰
            if (_isMobile && !_locked)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: SafeArea(
                  top: false,
                  right: false,
                  bottom: false,
                  child: SizedBox(
                    width: 72,
                    height: double.infinity,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _fade(_buildOrientationFabContent()),
                    ),
                  ),
                ),
              ),
            // 底栏（锁定态隐藏，防止误触调节进度/音量等）
            if (!_locked)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _fade(_buildBottomBar(context)),
              ),
            // 中央数值反馈胶囊（手势/键盘/按钮调节共用，置顶渲染）
            PlayerOsdView(osd: widget.osd),
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
              tooltip: '退出',
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

  /// 移动端（非桌面、非 Web）才显示方向悬浮按钮。
  bool get _isMobile =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// 仅 iOS 平台（用于 iOS 端隐藏音量按钮，仅保留手势调节）。
  bool get _isIOS => !kIsWeb && Platform.isIOS;

  /// 中央锁图标按钮：点击解锁。外层包 [_fade] 跟随控制栏显隐，
  /// 自动隐藏后点击屏幕（onTap 唤醒）重新显示。
  Widget _buildUnlockButton() {
    return Material(
      color: Colors.black54,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: _unlock,
        child: const Tooltip(
          message: '解锁',
          child: Padding(
            padding: EdgeInsets.all(18),
            child: Icon(
              LucideIcons.lock,
              size: 38,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  /// 方向切换悬浮按钮（仅移动端 + 仅视频模式）：
  /// 屏幕**左侧**中部固定位置的圆形按钮，包 [_fade] 跟随控制栏显隐。
  /// 图标使用 lucide [LucideIcons.rotateCw]（顺时针旋转箭头），
  /// 表达"旋转方向"语义最直观。
  Widget _buildOrientationFabContent() {
    if (widget.onToggleOrientation == null) return const SizedBox.shrink();
    final cur = widget.orientation ?? PlayerOrientation.portrait;
    final isLandscape = cur == PlayerOrientation.landscape;
    return Padding(
      padding: const EdgeInsets.only(left: 14),
      child: Material(
        color: Colors.black54,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () {
            widget.onToggleOrientation!();
            _wake();
          },
          child: Tooltip(
            message: isLandscape ? '切换到竖屏' : '切换到横屏',
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Icon(
                LucideIcons.rotateCw,
                size: 22,
                color: Colors.white,
              ),
            ),
          ),
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
              // 音量按钮：iOS 上隐藏，仅保留手势滑动调节音量。
              // 桌面端保留静音按钮（点击切换 0 / 上次音量），更符合 PC 习惯。
              if (!_isIOS)
                IconButton(
                  iconSize: 20,
                  color: Colors.white,
                  tooltip: _volume > 0 ? '静音' : '取消静音',
                  icon: Icon(_volumeIcon),
                  onPressed: _toggleMute,
                ),
              if (showVolumeSlider && !_isIOS)
                SizedBox(
                  width: 96,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2,
                      activeTrackColor: Colors.white,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: Colors.white,
                      overlayColor: Colors.white24,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 5,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 10,
                      ),
                    ),
                    child: Slider(
                      value: (_volume / 100).clamp(0.0, 1.0),
                      onChanged: (v) => _setVolume(v * 100),
                    ),
                  ),
                ),
              // 进入迷你模式：退出播放页，播放由底部迷你条接管
              if (widget.onMini != null)
                IconButton(
                  iconSize: 20,
                  color: Colors.white,
                  tooltip: '迷你播放',
                  icon: const Icon(LucideIcons.pictureInPicture),
                  onPressed: widget.onMini,
                ),
              // 全屏切换（桌面端）
              if (widget.onToggleFullscreen != null)
                IconButton(
                  iconSize: 20,
                  color: Colors.white,
                  tooltip: widget.isFullscreen ? '退出全屏' : '全屏',
                  icon: Icon(
                    widget.isFullscreen
                        ? LucideIcons.minimize
                        : LucideIcons.maximize,
                  ),
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

  Duration _durationOf(double frac) =>
      Duration(milliseconds: (frac * widget.duration.inMilliseconds).round());

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
        : (_dragFrac ?? widget.position.inMilliseconds / totalMs).clamp(
            0.0,
            1.0,
          );
    final bufferFrac = !_seekable
        ? 0.0
        : (widget.buffered.inMilliseconds / totalMs).clamp(0.0, 1.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final thumbLeft = (playedFrac * width - _thumbRadius).clamp(0.0, width);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: _seekable
              ? (d) => widget.onSeek(
                  _durationOf(_fracOf(d.localPosition.dx, width)),
                )
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
                  child: Container(height: _trackHeight, color: Colors.white38),
                ),
                // 已播放
                FractionallySizedBox(
                  widthFactor: playedFrac,
                  child: Container(height: _trackHeight, color: Colors.white),
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

/// 之前自定义的 `_OrientationLockIconPainter`（圆环+菱形+括号组合）已废弃——
/// 用户反馈不够直观，方向切换按钮改用 lucide `rotateCw` 顺时针旋转箭头。
/// 保留此处注释说明设计变更。
