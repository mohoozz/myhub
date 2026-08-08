import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/core/settings/settings_provider.dart';
import 'package:myhub_flutter/shared/providers/media_player_provider.dart';
import 'package:myhub_flutter/shared/utils/format.dart';
import 'package:myhub_flutter/shared/widgets/media_player/audio_cover_mode.dart';
import 'package:myhub_flutter/shared/widgets/media_player/orientation_watcher.dart';
import 'package:myhub_flutter/shared/widgets/media_player/player_controls.dart';
import 'package:myhub_flutter/shared/widgets/media_player/player_osd.dart';
import 'package:myhub_flutter/shared/widgets/window_title_bar.dart';
import 'package:window_manager/window_manager.dart';

/// 播放器主 Widget（TODO 5.1，视图层）。
///
/// * 播放会话由全局 [mediaPlayerProvider] 持有（TODO 5.7）：
///   本页 pop 后播放继续，底部迷你条接管；同一媒体重复进入时复用会话；
/// * 通过 `Navigator.push` 独立全屏路由进入（[MediaPlayerPage.open]），
///   纯黑沉浸式背景；
/// * 本页只负责视图：加载/缓冲/错误状态、控制栏（5.2）、音频封面模式（5.3）、
///   屏幕方向锁定、系统全屏（桌面端）、键盘控制（5.5）。
class MediaPlayerPage extends ConsumerStatefulWidget {
  const MediaPlayerPage({
    super.key,
    required this.sourceId,
    required this.file,
  });

  /// 文件所属路径源 ID。
  final int sourceId;

  /// 待播放文件（`mediaType` 为 video/audio，缺失时按扩展名兜底识别）。
  final FileItem file;

  /// 以独立全屏路由打开播放器（不随 Tab 切换销毁）。
  static Future<void> open(
    BuildContext context, {
    required int sourceId,
    required FileItem file,
  }) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => MediaPlayerPage(sourceId: sourceId, file: file),
      ),
    );
  }

  /// 智能打开媒体：迷你条在播时直接切换会话（保持迷你模式，不进全屏页），
  /// 否则 push 全屏播放页。
  static Future<void> openOrMini(
    BuildContext context,
    WidgetRef ref, {
    required int sourceId,
    required FileItem file,
  }) {
    final controller = ref.read(mediaPlayerProvider);
    if (controller.miniVisible.value && controller.hasMedia) {
      controller.play(sourceId, file);
      return Future.value();
    }
    return open(context, sourceId: sourceId, file: file);
  }

  @override
  ConsumerState<MediaPlayerPage> createState() => _MediaPlayerPageState();
}

class _MediaPlayerPageState extends ConsumerState<MediaPlayerPage>
    with SingleTickerProviderStateMixin {
  late final MediaPlayerController _controller;
  /// 当前播放器（media_kit Player 或 AvPlayerAdapter，iOS 用 AVPlayer）。
  late final dynamic _player;

  /// 沉浸式标题栏开关（缓存 notifier，dispose 后 ref 不可再用）。
  late final StateController<bool> _immersiveTitleBar;

  /// 屏幕中央数值反馈（键盘/手势/按钮调节共用）。
  final PlayerOsd _osd = PlayerOsd();

  StreamSubscription<dynamic>? _bufferingSub;

  bool _buffering = false;

  /// 桌面端系统全屏状态（驱动控制栏全屏按钮图标）。
  bool _fullscreen = false;

  /// 键盘静音前的音量记忆（M 键取消静音时恢复）。
  double _volumeBeforeMute = 100;

  /// 当前生效的方向偏好（控制栏按钮三态循环：portrait → landscape → sensor）。
  late PlayerOrientation _orientation;

  /// 水平仪监听器（仅 `sensor` 模式启用）。
  final OrientationWatcher _orientationWatcher = OrientationWatcher();

  /// 迷你模式拖拽/收起动画控制器：
  /// 拖动时 set value 跟手，松手时 [AnimationController.animateTo] 回弹或收起。
  late final AnimationController _miniAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  /// 向下拖动进入迷你模式：位移上限（屏高比例）。
  static const double _miniDragDyFactor = 0.45;

  /// 向下拖动进入迷你模式：缩放下限。
  static const double _miniMinScale = 0.62;

  /// 向下拖动进入迷你模式：圆角上限。
  static const double _miniMaxRadius = 20;

  /// 进入迷你模式的拖动进度阈值（超过则收起进入迷你，否则回弹）。
  static const double _miniThreshold = 0.25;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(mediaPlayerProvider);
    _controller.pageOpened();
    // 同步建立/复用会话，随后即可取到 Player
    _controller.play(widget.sourceId, widget.file);
    _player = _controller.player!;
    // buffering 流在 media_kit 和 AvPlayerAdapter 上都有
    final bufferingStream = _player.stream.buffering as Stream<bool>;
    _bufferingSub = bufferingStream.listen((b) {
      if (!mounted) return;
      setState(() => _buffering = b);
    });
    // 读取用户方向偏好（持久化：上次竖屏/横屏/水平仪自动）。
    // 注意：PlayerSettings 异步从 SharedPreferences 恢复，首次 build() 返回默认
    // portrait；故先取默认值，再用 ref.listen 在异步恢复完成后同步一次。
    _orientation = ref.read(playerSettingsProvider).orientation;
    // 模式（视频/音频）变化时同步调整方向锁定
    _controller.isVideoMode.addListener(_applyOrientationLock);
    _orientationWatcher.tiltListenable.addListener(_onTiltChanged);
    // 监听方向偏好恢复（从 SharedPreferences 异步加载完成时）：
    // 更新会话内 _orientation 并重新应用，保证打开播放器即沿用上次方向。
    // 注意：ref.listen 必须在 build 中调用（Riverpod 限制），
    // 实际位置见 _MediaPlayerPageState.build。
    _applyOrientationLock();
    if (isDesktopPlatform) {
      windowManager.isFullScreen().then((v) {
        if (mounted && v != _fullscreen) {
          setState(() => _fullscreen = v);
        }
      });
      // 沉浸式黑色标题栏（播放页为纯黑背景，白底标题栏会突兀）；
      // initState 处于组件树锁定阶段，与 pageOpened 同理延迟到帧后修改
      _immersiveTitleBar = ref.read(immersiveTitleBarProvider.notifier);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _immersiveTitleBar.state = true;
      });
    }
  }

  @override
  void dispose() {
    // 移动端兜底：退出播放页恢复竖屏。
    // 正常的 _exitAndStop / _enterMiniMode 路径已先 await 过 orientation，
    // 这里保留以防异常路径（如 Flutter 路由强制销毁）漏掉恢复。
    // 异步调用无须 await：dispose 同步返回，framework 会在原生方向
    // 过渡动画期间自然完成 setter。
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
    }
    // 桌面端系统全屏不带出播放器页
    if (isDesktopPlatform && _fullscreen) {
      unawaited(windowManager.setFullScreen(false));
    }
    // 退出播放页，标题栏恢复主题色；
    // dispose 处于组件树锁定阶段，同步改 provider 会抛异常并中断后续
    // pageClosed()（迷你条因此不显示），统一延迟到帧后执行
    if (isDesktopPlatform) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _immersiveTitleBar.state = false;
      });
    }
    _controller.isVideoMode.removeListener(_applyOrientationLock);
    _orientationWatcher.tiltListenable.removeListener(_onTiltChanged);
    unawaited(_orientationWatcher.stop());
    unawaited(_bufferingSub?.cancel());
    _osd.dispose();
    _miniAnim.dispose();
    // 播放继续，迷你条接管（有错误时保持隐藏）
    _controller.pageClosed();
    super.dispose();
  }

  /// 移动端：先 await 把方向切回竖屏，再交还流程。
  ///
  /// iOS 上 [SystemChrome.setPreferredOrientations] 会触发原生 UIViewController
  /// 旋转动画（约 300ms）；如果不先 await，pop 与旋转过渡并发，
  /// 横屏 Scaffold 已销毁而原生 view 还在旋转，画面会闪一帧异常（控制栏
  /// 残影、边缘拉伸）。统一在这里同步关掉方向再继续退出/收起。
  Future<void> _restorePortraitOrientation() async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
  }

  /// 按当前模式和方向偏好应用屏幕方向（仅移动端）。
  ///
  /// 三种策略：
  /// * [PlayerOrientation.portrait]  - 视频/音频均锁定竖屏；
  /// * [PlayerOrientation.landscape] - 视频锁定横屏，音频保持竖屏；
  /// * [PlayerOrientation.sensor]    - 视频跟随水平仪，音频保持竖屏。
  void _applyOrientationLock() {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    // 音频模式不参与横屏策略：唱片封面更适合竖屏
    if (!_controller.isVideoMode.value) {
      _setOrientations(const [DeviceOrientation.portraitUp]);
      return;
    }
    switch (_orientation) {
      case PlayerOrientation.portrait:
        _setOrientations(const [DeviceOrientation.portraitUp]);
        _orientationWatcher.stop();
      case PlayerOrientation.landscape:
        _setOrientations(const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        _orientationWatcher.stop();
      case PlayerOrientation.sensor:
        // 启动水平仪监听；初始姿态决定首次方向，之后由 [_onTiltChanged] 驱动
        _orientationWatcher.start();
        final initial = orientationsFor(_orientationWatcher.currentTilt);
        if (initial.isNotEmpty) {
          _setOrientations(initial);
        } else {
          // 设备水平放置未决：先允许竖屏，由首帧姿态修正
          _setOrientations(const [DeviceOrientation.portraitUp]);
        }
    }
  }

  Future<void> _setOrientations(List<DeviceOrientation> list) async {
    if (list.isEmpty) return;
    await SystemChrome.setPreferredOrientations(list);
  }

  /// 水平仪姿态变化：仅在 `sensor` 模式下应用。
  void _onTiltChanged() {
    if (!mounted) return;
    if (_orientation != PlayerOrientation.sensor) return;
    if (!_controller.isVideoMode.value) return;
    final list = orientationsFor(_orientationWatcher.currentTilt);
    if (list.isEmpty) return;
    _setOrientations(list);
  }

  /// 控制栏方向按钮：portrait ↔ landscape 二态切换。
  ///
  /// 按钮只关心"当前方向"与"目标方向"，跟"水平仪自动"互不耦合：
  /// * 当前竖屏 → 切到横屏；
  /// * 当前横屏 → 切到竖屏；
  /// * 当前是水平仪（sensor）→ 切到竖屏（按一次固定方向更可控）。
  /// "自动（水平仪）"模式由设置页配置（不在控制栏按钮路径上）。
  ///
  /// 注意：方向偏好**不持久化**——每次进入播放页默认竖屏，
  /// 切换仅对当前会话生效；离开页面即重置回竖屏。
  Future<void> _toggleOrientation() async {
    final next = switch (_orientation) {
      PlayerOrientation.landscape => PlayerOrientation.portrait,
      PlayerOrientation.portrait => PlayerOrientation.landscape,
      PlayerOrientation.sensor => PlayerOrientation.portrait,
    };
    setState(() => _orientation = next);
    // 持久化方向偏好：下次打开播放器沿用上次的竖屏/横屏选择。
    final settings = ref.read(playerSettingsProvider);
    unawaited(
      ref
          .read(playerSettingsProvider.notifier)
          .update(settings.copyWith(orientation: next)),
    );
    _applyOrientationLock();
    _osd.show(
      next == PlayerOrientation.landscape
          ? LucideIcons.rectangleHorizontal
          : LucideIcons.rectangleVertical,
      next == PlayerOrientation.landscape ? '横屏' : '竖屏',
    );
  }

  /// 桌面端系统级全屏切换。
  Future<void> _toggleFullscreen() async {
    if (!isDesktopPlatform) return;
    final target = !await windowManager.isFullScreen();
    await windowManager.setFullScreen(target);
    if (mounted) {
      setState(() => _fullscreen = target);
    }
  }

  // ---------- 退出 / 迷你模式 ----------

  /// 直接退出：停止播放并关闭播放页（不进入迷你模式）。
  Future<void> _exitAndStop() async {
    // 先让原生视图开始旋转回竖屏，避免与 pop 动画并发造成一帧异常
    await _restorePortraitOrientation();
    unawaited(_controller.stop());
    if (!mounted) return;
    await Navigator.of(context).maybePop();
  }

  /// 进入迷你模式：先播收起动画（缩小下沉），结束后退出播放页，
  /// 播放继续由底部迷你条接管（与中间向下拖动过渡一致）。
  void _enterMiniMode() {
    unawaited(_settleToMini());
  }

  /// 收起动画：页面缩小下沉到底，结束后先切回竖屏再 pop 退出播放页。
  ///
  /// pop 之前先恢复竖屏：横屏时收起动画与 iOS 原生旋转过渡并发，
  /// 容易在动画末段叠出一帧控制栏残影 / 边缘异常。
  Future<void> _settleToMini() async {
    try {
      await _miniAnim.animateTo(1.0);
    } catch (_) {
      return; // 动画被销毁（页面已退出）
    }
    if (!mounted) return;
    await _restorePortraitOrientation();
    if (!mounted) return;
    unawaited(Navigator.of(context).maybePop());
  }

  /// 中间区域向下拖动：页面跟随位移/缩放/圆角。
  void _onMiniDrag(double fraction) {
    if (!mounted) return;
    _miniAnim.value = fraction;
  }

  /// 松手：超过阈值收起进入迷你模式，否则回弹全屏。
  void _onMiniDragEnd(double fraction) {
    if (!mounted) return;
    if (fraction >= _miniThreshold) {
      unawaited(_settleToMini());
    } else {
      _miniAnim.animateTo(0);
    }
  }

  // ---------- 键盘控制（5.5，桌面端为主） ----------

  /// ←/→：快退/快进 5s。
  void _seekBy(Duration delta) {
    final duration = _player.state.duration as Duration;
    var target = (_player.state.position as Duration) + delta;
    if (target < Duration.zero) {
      target = Duration.zero;
    } else if (duration > Duration.zero && target > duration) {
      target = duration;
    }
    _player.seek(target);
    final forward = delta >= Duration.zero;
    _osd.show(
      forward ? LucideIcons.fastForward : LucideIcons.rewind,
      '${forward ? '+' : '-'}${delta.inSeconds.abs()}s  '
      '${formatPlaybackTime(target)}',
    );
  }

  /// ↑/↓：音量 ±5%。
  ///
  /// 防御：iOS 模拟器上音频设备未初始化时，
  /// `Player.state.volume` 可能返回 mpv 内部非语义值（如负数）；
  /// 先把读到的值 clamp 到 [0, 100] 再叠加 delta。
  void _changeVolume(double delta) {
    final raw = (_player.state.volume as double).clamp(0.0, 100.0);
    final v = (raw + delta).clamp(0.0, 100.0);
    _player.setVolume(v);
    _osd.show(_volumeIcon(v), '${v.round()}%');
  }

  /// M：静音切换（记住静音前音量）。
  void _toggleMute() {
    final v = _player.state.volume as double;
    if (v > 0) {
      _volumeBeforeMute = v;
      _player.setVolume(0);
      _osd.show(LucideIcons.volumeX, '静音');
    } else {
      final restored = _volumeBeforeMute > 0 ? _volumeBeforeMute : 100.0;
      _player.setVolume(restored);
      _osd.show(_volumeIcon(restored), '${restored.round()}%');
    }
  }

  static IconData _volumeIcon(double v) {
    if (v <= 0) return LucideIcons.volumeX;
    if (v < 50) return LucideIcons.volume1;
    return LucideIcons.volume2;
  }

  /// 全局键盘绑定（页面级：加载/错误状态下 Esc 同样可用）。
  Map<ShortcutActivator, VoidCallback> get _keyBindings => {
    const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
        _seekBy(const Duration(seconds: -5)),
    const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
        _seekBy(const Duration(seconds: 5)),
    const SingleActivator(LogicalKeyboardKey.arrowUp): () => _changeVolume(5),
    const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
        _changeVolume(-5),
    const SingleActivator(LogicalKeyboardKey.space): () => _player.playOrPause(),
    const SingleActivator(LogicalKeyboardKey.escape): _exitAndStop,
    const SingleActivator(LogicalKeyboardKey.keyF): () {
      if (isDesktopPlatform) {
        _toggleFullscreen();
      }
    },
    const SingleActivator(LogicalKeyboardKey.keyM): _toggleMute,
  };

  @override
  Widget build(BuildContext context) {
    // 监听方向偏好异步恢复（SharedPreferences 加载完成后同步）。
    // Riverpod 限制：ref.listen 必须在 build 方法中调用。
    // 仅同步方向变化，避免播放中外部改设置频繁切向。
    ref.listen<PlayerSettings>(playerSettingsProvider, (previous, next) {
      if (!mounted) return;
      if (previous?.orientation == next.orientation) return;
      _orientation = next.orientation;
      _applyOrientationLock();
    });
    return Scaffold(
      backgroundColor: Colors.black, // 沉浸式纯黑背景
      body: CallbackShortcuts(
        bindings: _keyBindings,
        child: Focus(
          autofocus: true,
          child: ListenableBuilder(
            listenable: Listenable.merge([
              _controller.loading,
              _controller.error,
              _controller.isVideoMode,
            ]),
            builder: (context, _) {
              final loading = _controller.loading.value;
              final error = _controller.error.value;
              final isVideo = _controller.isVideoMode.value;
              final videoController = _controller.videoController;
              final hasError = error != null;
              return AnimatedBuilder(
                animation: _miniAnim,
                builder: (context, _) {
                  final f = _miniAnim.value;
                  final size = MediaQuery.sizeOf(context);
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      // 拖动/收起时露出的底层背景（模拟下层页面，
                      // 让"向下拖出迷你条"的过渡有层次感）
                      ColoredBox(
                        color: f > 0.001
                            ? const Color(0xFF161616)
                            : Colors.black,
                      ),
                      Transform.translate(
                        offset: Offset(0, f * _miniDragDyFactor * size.height),
                        child: Transform.scale(
                          scale: 1 - (1 - _miniMinScale) * f,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(
                              _miniMaxRadius * f,
                            ),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                // 视频画面 / 音频唱片封面模式
                                if (isVideo) ...[
                                  if (_controller.useAvPlayer &&
                                      _controller.textureId != null)
                                    ValueListenableBuilder<int>(
                                      valueListenable: _controller.textureId!,
                                      builder: (context, texId, _) {
                                        if (texId <= 0) {
                                          return const ColoredBox(
                                            color: Colors.black,
                                            child: SizedBox.expand(),
                                          );
                                        }
                                        // Texture 总是拉伸填满父容器，无法
                                        // 直接按视频比例显示。视频原始比例
                                        // 为 16:9（1920x1080）。按容器宽高
                                        // 选择「宽度优先」或「高度优先」：
                                        //   - 竖屏容器（w/h < 16/9）：宽度填满，
                                        //     视频高度按 16:9 计算，上下留黑边
                                        //   - 横屏容器（w/h >= 16/9）：高度填满，
                                        //     视频宽度按 16:9 计算，左右留黑边
                                        return LayoutBuilder(
                                          builder: (context, constraints) {
                                            final w = constraints.maxWidth;
                                            final h = constraints.maxHeight;
                                            final videoH = w * 9 / 16;
                                            if (videoH <= h) {
                                              // 竖屏：宽度填满，按 16:9 计算高度
                                              return Stack(
                                                fit: StackFit.expand,
                                                children: [
                                                  const ColoredBox(
                                                    color: Colors.black,
                                                  ),
                                                  Positioned(
                                                    top: (h - videoH) / 2,
                                                    left: 0,
                                                    right: 0,
                                                    height: videoH,
                                                    child: Texture(
                                                      textureId: texId,
                                                      filterQuality:
                                                          FilterQuality.medium,
                                                    ),
                                                  ),
                                                ],
                                              );
                                            } else {
                                              // 横屏：高度填满，按 16:9 计算宽度
                                              final videoW = h * 16 / 9;
                                              return Stack(
                                                fit: StackFit.expand,
                                                children: [
                                                  const ColoredBox(
                                                    color: Colors.black,
                                                  ),
                                                  Positioned(
                                                    top: 0,
                                                    bottom: 0,
                                                    left: (w - videoW) / 2,
                                                    width: videoW,
                                                    child: Texture(
                                                      textureId: texId,
                                                      filterQuality:
                                                          FilterQuality.medium,
                                                    ),
                                                  ),
                                                ],
                                              );
                                            }
                                          },
                                        );
                                      },
                                    )
                                  else if (videoController != null)
                                    Video(
                                      controller: videoController,
                                      controls:
                                          null, // 自定义控制栏见 player_controls.dart
                                      fill: Colors.black,
                                    )
                                  else
                                    const ColoredBox(
                                      color: Colors.black,
                                      child: SizedBox.expand(),
                                    ),
                                ] else
                                  AudioCoverMode(
                                    player: _player,
                                    sourceId: widget.sourceId,
                                    file: widget.file,
                                  ),
                                // 自定义控制栏 Overlay（错误态不挂载，
                                // 错误视图自带返回按钮）
                                if (!hasError)
                                  PlayerControls(
                                    player: _player,
                                    title: widget.file.name,
                                    osd: _osd,
                                    loading: loading,
                                    buffering: _buffering,
                                    // 音频模式下隐藏中央按钮（按钮在唱片中央），
                                    // 避免重叠和与 OSD 进度提示冲突。
                                    showCenterPlayButton: isVideo,
                                    onBack: _exitAndStop,
                                    onMini: _enterMiniMode,
                                    onMiniDrag: isDesktopPlatform
                                        ? null
                                        : _onMiniDrag,
                                    onMiniDragEnd: isDesktopPlatform
                                        ? null
                                        : _onMiniDragEnd,
                                    onToggleFullscreen: isDesktopPlatform
                                        ? _toggleFullscreen
                                        : null,
                                    isFullscreen: _fullscreen,
                                    orientation: isDesktopPlatform
                                        ? null
                                        : _orientation,
                                    onToggleOrientation:
                                        isDesktopPlatform ? null : _toggleOrientation,
                                  ),
                                // 播放中的缓冲转圈（首次加载走 _LoadingView）；
                                // 圆形底托与中央播放按钮同风格，
                                // 缓冲时按钮已隐藏不会重叠
                                if (!loading && !hasError && _buffering)
                                  const Center(
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: Colors.black45,
                                        shape: BoxShape.circle,
                                      ),
                                      child: Padding(
                                        padding: EdgeInsets.all(20),
                                        child: SizedBox(
                                          width: 38,
                                          height: 38,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 3,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                if (loading && !hasError) const _LoadingView(),
                                if (hasError) ...[
                                  _ErrorView(
                                    message: error,
                                    onRetry: _controller.retry,
                                  ),
                                  Positioned(
                                    top: 0,
                                    left: 0,
                                    child: SafeArea(
                                      bottom: false,
                                      child: IconButton(
                                        icon: const Icon(
                                          LucideIcons.arrowLeft,
                                          color: Colors.white,
                                        ),
                                        tooltip: '返回',
                                        onPressed: () =>
                                            Navigator.of(context).maybePop(),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 首次加载状态：中央转圈 + "加载中..."。
class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 40,
            height: 40,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: Colors.white70,
            ),
          ),
          SizedBox(height: 16),
          Text('加载中...', style: TextStyle(color: Colors.white70, fontSize: 13)),
        ],
      ),
    );
  }
}

/// 错误状态：错误信息 + 重试按钮。
class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              LucideIcons.circleAlert,
              size: 48,
              color: Colors.white38,
            ),
            const SizedBox(height: 16),
            const Text(
              '播放失败',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(LucideIcons.rotateCw, size: 16),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
