import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/shared/providers/media_player_provider.dart';
import 'package:myhub_flutter/shared/widgets/media_player/audio_cover_mode.dart';
import 'package:myhub_flutter/shared/widgets/media_player/player_controls.dart';
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

  @override
  ConsumerState<MediaPlayerPage> createState() => _MediaPlayerPageState();
}

class _MediaPlayerPageState extends ConsumerState<MediaPlayerPage> {
  late final MediaPlayerController _controller;
  late final Player _player;
  StreamSubscription<dynamic>? _bufferingSub;

  bool _buffering = false;

  /// 桌面端系统全屏状态（驱动控制栏全屏按钮图标）。
  bool _fullscreen = false;

  /// 键盘静音前的音量记忆（M 键取消静音时恢复）。
  double _volumeBeforeMute = 100;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(mediaPlayerProvider);
    _controller.pageOpened();
    // 同步建立/复用会话，随后即可取到 Player
    _controller.play(widget.sourceId, widget.file);
    _player = _controller.player!;
    _bufferingSub = _player.stream.buffering.listen((b) {
      if (!mounted) return;
      setState(() => _buffering = b);
    });
    // 模式（视频/音频）变化时同步调整方向锁定
    _controller.isVideoMode.addListener(_applyOrientationLock);
    _applyOrientationLock();
    if (isDesktopPlatform) {
      windowManager.isFullScreen().then((v) {
        if (mounted && v != _fullscreen) {
          setState(() => _fullscreen = v);
        }
      });
    }
  }

  @override
  void dispose() {
    // 视频模式曾锁定横屏，退出时恢复竖屏
    if (!kIsWeb &&
        (Platform.isAndroid || Platform.isIOS) &&
        _controller.isVideoMode.value) {
      SystemChrome.setPreferredOrientations(
        const [DeviceOrientation.portraitUp],
      );
    }
    // 桌面端系统全屏不带出播放器页
    if (isDesktopPlatform && _fullscreen) {
      unawaited(windowManager.setFullScreen(false));
    }
    _controller.isVideoMode.removeListener(_applyOrientationLock);
    unawaited(_bufferingSub?.cancel());
    // 播放继续，迷你条接管（有错误时保持隐藏）
    _controller.pageClosed();
    super.dispose();
  }

  /// 按当前模式应用屏幕方向（仅移动端）：视频锁定横屏，音频恢复竖屏。
  void _applyOrientationLock() {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    if (_controller.isVideoMode.value) {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations(
        const [DeviceOrientation.portraitUp],
      );
    }
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

  // ---------- 键盘控制（5.5，桌面端为主） ----------

  /// ←/→：快退/快进 5s。
  void _seekBy(Duration delta) {
    final duration = _player.state.duration;
    var target = _player.state.position + delta;
    if (target < Duration.zero) {
      target = Duration.zero;
    } else if (duration > Duration.zero && target > duration) {
      target = duration;
    }
    _player.seek(target);
  }

  /// ↑/↓：音量 ±5%。
  void _changeVolume(double delta) {
    final v = (_player.state.volume + delta).clamp(0.0, 100.0);
    _player.setVolume(v);
  }

  /// M：静音切换（记住静音前音量）。
  void _toggleMute() {
    final v = _player.state.volume;
    if (v > 0) {
      _volumeBeforeMute = v;
      _player.setVolume(0);
    } else {
      _player.setVolume(_volumeBeforeMute > 0 ? _volumeBeforeMute : 100);
    }
  }

  /// 全局键盘绑定（页面级：加载/错误状态下 Esc 同样可用）。
  Map<ShortcutActivator, VoidCallback> get _keyBindings => {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _seekBy(const Duration(seconds: -5)),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _seekBy(const Duration(seconds: 5)),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _changeVolume(5),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _changeVolume(-5),
        const SingleActivator(LogicalKeyboardKey.space): _player.playOrPause,
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.keyF): () {
          if (isDesktopPlatform) {
            _toggleFullscreen();
          }
        },
        const SingleActivator(LogicalKeyboardKey.keyM): _toggleMute,
      };

  @override
  Widget build(BuildContext context) {
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
              return Stack(
                fit: StackFit.expand,
                children: [
                  // 视频画面 / 音频唱片封面模式
                  if (isVideo && videoController != null)
                    Video(
                      controller: videoController,
                      controls: null, // 自定义控制栏见 player_controls.dart
                      fill: Colors.black,
                    )
                  else
                    AudioCoverMode(
                      player: _player,
                      sourceId: widget.sourceId,
                      file: widget.file,
                    ),
                  // 自定义控制栏 Overlay（错误态不挂载，错误视图自带返回按钮）
                  if (!hasError)
                    PlayerControls(
                      player: _player,
                      title: widget.file.name,
                      loading: loading,
                      onBack: () => Navigator.of(context).maybePop(),
                      onToggleFullscreen:
                          isDesktopPlatform ? _toggleFullscreen : null,
                      isFullscreen: _fullscreen,
                    ),
                  // 播放中的缓冲转圈（首次加载走 _LoadingView）
                  if (!loading && !hasError && _buffering)
                    const Center(
                      child: SizedBox(
                        width: 36,
                        height: 36,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  if (loading && !hasError) const _LoadingView(),
                  if (hasError) ...[
                    _ErrorView(message: error, onRetry: _controller.retry),
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
                          onPressed: () => Navigator.of(context).maybePop(),
                        ),
                      ),
                    ),
                  ],
                ],
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
          Text(
            '加载中...',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
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
