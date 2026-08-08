import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:myhub_flutter/core/router/app_router.dart';
import 'package:myhub_flutter/shared/providers/media_player_provider.dart';
import 'package:myhub_flutter/shared/widgets/media_player/media_player.dart';

/// 迷你播放器（TODO 5.7）：悬浮式迷你条，跨页面保持。
///
/// 挂载在 MaterialApp `builder` 的 Stack 中（Navigator 之上），
/// 播放会话由全局 [mediaPlayerProvider] 持有：
/// * 底部居中悬浮的圆角胶囊（"灵动岛"风格，配色跟随主题）：
///   视频小窗（音频为图标）+ 文件名 + 播放/暂停 + 音量控制 +
///   关闭按钮，下缘 2px 细进度条；
/// * 点击胶囊重新展开全屏播放器（复用同一会话）；
/// * 关闭按钮 / 向下拖拽：停止播放并移除。
///
/// 注意：此处无 Navigator/Overlay 祖先——不能用 Tooltip；
/// 音量滑杆为自绘 [_VolumeSlider]（Material Slider 需要 Overlay）。
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(mediaPlayerProvider);
    // 同时监听会话版本：迷你模式下切换媒体时重建，
    // 订阅新 Player、刷新标题与视频小窗（否则残留旧会话画面）
    return ListenableBuilder(
      listenable: Listenable.merge([
        controller.miniVisible,
        controller.sessionVersion,
      ]),
      builder: (context, _) {
        final visible = controller.miniVisible.value;
        final player = controller.player;
        final file = controller.file;
        if (!visible || player == null || file == null) {
          return const SizedBox.shrink();
        }
        return _MiniPlayerBar(
          key: ValueKey(file.path),
          controller: controller,
          player: player,
          onExpand: () {
            // 迷你条挂在 Navigator 之上，自身 context 没有 Navigator 祖先：
            // 借 GoRouter 根 navigatorKey 的 context 打开全屏播放页
            final navContext = ref
                .read(appRouterProvider)
                .routerDelegate
                .navigatorKey
                .currentContext;
            if (navContext == null) return;
            MediaPlayerPage.open(
              navContext,
              sourceId: controller.sourceId!,
              file: controller.file!,
            );
          },
        );
      },
    );
  }
}

class _MiniPlayerBar extends StatefulWidget {
  const _MiniPlayerBar({
    super.key,
    required this.controller,
    required this.player,
    required this.onExpand,
  });

  final MediaPlayerController controller;
  final dynamic player;

  /// 点击迷你条展开全屏播放器。
  final VoidCallback onExpand;

  @override
  State<_MiniPlayerBar> createState() => _MiniPlayerBarState();
}

class _MiniPlayerBarState extends State<_MiniPlayerBar>
    with SingleTickerProviderStateMixin {
  final List<StreamSubscription<dynamic>> _subs = [];

  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _volume = 100;

  /// 静音前的音量记忆（取消静音时恢复）。
  double _volumeBeforeMute = 100;

  /// 入场动画：底部滑入 + 淡入 + 轻微放大（进入迷你模式的过渡）。
  late final AnimationController _enterCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );
  late final Animation<double> _enter = CurvedAnimation(
    parent: _enterCtrl,
    curve: Curves.easeOutCubic,
  );

  @override
  void initState() {
    super.initState();
    final player = widget.player;
    _playing = player.state.playing as bool;
    _position = player.state.position as Duration;
    _duration = player.state.duration as Duration;
    _volume = player.state.volume as double;
    _subs.addAll([
      (player.stream.playing as Stream<bool>).listen((v) {
        if (mounted) setState(() => _playing = v);
      }),
      (player.stream.position as Stream<Duration>).listen((v) {
        if (mounted) setState(() => _position = v);
      }),
      (player.stream.duration as Stream<Duration>).listen((v) {
        if (mounted) setState(() => _duration = v);
      }),
      (player.stream.volume as Stream<double>).listen((v) {
        if (mounted) setState(() => _volume = v);
      }),
    ]);
    _enterCtrl.forward();
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _enterCtrl.dispose();
    super.dispose();
  }

  /// 音量图标：静音切换（记住静音前音量）。
  void _toggleMute() {
    final v = widget.player.state.volume as double;
    if (v > 0) {
      _volumeBeforeMute = v;
      widget.player.setVolume(0);
    } else {
      widget.player.setVolume(_volumeBeforeMute > 0 ? _volumeBeforeMute : 100);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final file = widget.controller.file!;
    final progress = _duration > Duration.zero
        ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    // 固定中性灰细边框（不跟随主题）：明/暗主题及切换过程中
    // 都保持一致的可见边界，不存在过渡中的"白边/黑边"问题。
    final pillShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(16)),
      side: const BorderSide(
        color: Color(0xFF9E9E9E), // Material grey 500
        width: 1,
      ),
    );

    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 1.2),
        end: Offset.zero,
      ).animate(_enter),
      child: FadeTransition(
        opacity: _enter,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.85, end: 1).animate(_enter),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Dismissible(
                  key: widget.key!,
                  direction: DismissDirection.down, // 拖拽到底部关闭
                  onDismissed: (_) => widget.controller.stop(),
                  child: Material(
                    // 胶囊配色跟随主题（浅色主题白底、深色主题深底）
                    // 不使用 elevation：阴影在浅色主题下会出现深色阴影，
                    // 主题从暗切到亮时阴影会"突然"出现,造成底部黑边。
                    // surfaceContainerHigh 已有色调分层,边框提供边界。
                    color: colorScheme.surfaceContainerHigh,
                    elevation: 0,
                    shape: pillShape,
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: widget.onExpand, // 点击展开全屏播放器（复用同一会话）
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          // 窄屏省略音量滑杆，仅保留音量/静音图标
                          final showVolumeSlider = constraints.maxWidth >= 420;
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 8,
                                ),
                                child: Row(
                                  children: [
                                    // 视频：左侧 64x36 播放小窗（复用全局
                                    // VideoController/AVPlayer texture，
                                    // 全屏页已关闭无冲突）；
                                    // 音频：类型图标
                                    ValueListenableBuilder<bool>(
                                      valueListenable:
                                          widget.controller.isVideoMode,
                                      builder: (context, isVideo, _) {
                                        if (!isVideo) {
                                          return Icon(
                                            LucideIcons.music,
                                            size: 18,
                                            color: colorScheme.onSurfaceVariant,
                                          );
                                        }
                                        // iOS AVPlayer 模式：用 Texture 渲染
                                        if (widget.controller.useAvPlayer) {
                                          final texId =
                                              widget.controller.textureId;
                                          if (texId == null ||
                                              texId.value <= 0) {
                                            return Container(
                                              width: 64,
                                              height: 36,
                                              decoration: BoxDecoration(
                                                color: Colors.black,
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                              ),
                                              child: const Icon(Icons.movie,
                                                  size: 18,
                                                  color: Colors.white54),
                                            );
                                          }
                                          return ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(6),
                                            child: SizedBox(
                                              width: 64,
                                              height: 36,
                                              child: ValueListenableBuilder<int>(
                                                valueListenable: texId,
                                                builder: (context, id, _) =>
                                                    Texture(
                                                  textureId: id,
                                                  filterQuality:
                                                      FilterQuality.low,
                                                ),
                                              ),
                                            ),
                                          );
                                        }
                                        // media_kit 模式：用 Video 渲染
                                        final videoController =
                                            widget.controller.videoController;
                                        if (videoController != null) {
                                          return ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                            child: SizedBox(
                                              width: 64,
                                              height: 36,
                                              child: Video(
                                                controller: videoController,
                                                controls: null,
                                                fit: BoxFit.cover,
                                                fill: Colors.black,
                                              ),
                                            ),
                                          );
                                        }
                                        return Icon(
                                          LucideIcons.music,
                                          size: 18,
                                          color: colorScheme.onSurfaceVariant,
                                        );
                                      },
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        file.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: colorScheme.onSurface,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    // 播放/暂停圆形按钮
                                    Material(
                                      color: colorScheme.primary,
                                      shape: const CircleBorder(),
                                      clipBehavior: Clip.antiAlias,
                                      child: InkWell(
                                        customBorder: const CircleBorder(),
                                        onTap: () => widget.player.playOrPause(),
                                        child: Padding(
                                          padding: const EdgeInsets.all(6),
                                          child: Icon(
                                            _playing
                                                ? LucideIcons.pause
                                                : LucideIcons.play,
                                            size: 16,
                                            color: colorScheme.onPrimary,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 2),
                                    // 音量：图标点击静音切换，右侧滑杆调节
                                    _PillIconButton(
                                      icon: _volume <= 0
                                          ? LucideIcons.volumeX
                                          : _volume < 50
                                          ? LucideIcons.volume1
                                          : LucideIcons.volume2,
                                      color: colorScheme.onSurfaceVariant,
                                      onTap: _toggleMute,
                                    ),
                                    if (showVolumeSlider)
                                      SizedBox(
                                        width: 80,
                                        height: 24,
                                        // Material Slider 需要 Overlay 祖先
                                        // （迷你条在 Navigator 之上，没有），
                                        // 故用自绘的细滑杆
                                        child: _VolumeSlider(
                                          value: (_volume / 100).clamp(
                                            0.0,
                                            1.0,
                                          ),
                                          color: colorScheme.primary,
                                          trackColor:
                                              colorScheme.outlineVariant,
                                          onChanged: (v) =>
                                              widget.player.setVolume(v * 100),
                                        ),
                                      ),
                                    // 关闭：停止播放并移除
                                    _PillIconButton(
                                      icon: LucideIcons.x,
                                      color: colorScheme.onSurfaceVariant,
                                      onTap: widget.controller.stop,
                                    ),
                                  ],
                                ),
                              ),
                              // 下缘 2px 细进度条
                              LinearProgressIndicator(
                                value: progress.toDouble(),
                                minHeight: 2,
                                // 未播放轨道完全透明：仅显示已播放蓝色填充。
                                // 1) 主题切换中无任何独立颜色,不会出现
                                //    与胶囊不同步的"黑边/白边";
                                // 2) LinearProgressIndicator 圆角与 Material
                                //    16px 大圆角不匹配,即使同色在抗锯齿边缘
                                //    也会产生颜色叠加,设为透明彻底规避;
                                // 3) Spotify 等现代设计即采用此方案。
                                backgroundColor: Colors.transparent,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  colorScheme.primary,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 胶囊内的小型图标按钮（比 IconButton 更紧凑，避免撑高胶囊）。
class _PillIconButton extends StatelessWidget {
  const _PillIconButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 18,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(icon, size: 18, color: color),
      ),
    );
  }
}

/// 自绘细音量滑杆：2px 圆角轨道 + 小圆点手柄，支持点按/拖动。
///
/// 迷你条在 Navigator 之上无 Overlay 祖先，Material Slider 不可用，
/// 且原生滑杆手柄过大、在胶囊内突兀，故定制。
class _VolumeSlider extends StatelessWidget {
  const _VolumeSlider({
    required this.value,
    required this.color,
    required this.trackColor,
    required this.onChanged,
  });

  /// 当前值（0.0 ~ 1.0）。
  final double value;

  /// 已播放段轨道与手柄颜色。
  final Color color;

  /// 未填充段轨道颜色。
  final Color trackColor;

  final ValueChanged<double> onChanged;

  void _update(Offset localPosition, double width) {
    onChanged((localPosition.dx / width).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _update(d.localPosition, width),
          onHorizontalDragUpdate: (d) => _update(d.localPosition, width),
          child: CustomPaint(
            painter: _VolumeSliderPainter(
              value: value,
              color: color,
              trackColor: trackColor,
            ),
          ),
        );
      },
    );
  }
}

class _VolumeSliderPainter extends CustomPainter {
  const _VolumeSliderPainter({
    required this.value,
    required this.color,
    required this.trackColor,
  });

  final double value;
  final Color color;
  final Color trackColor;

  static const double _trackHeight = 2.5;
  static const double _thumbRadius = 4.5;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final thumbX = (size.width * value).clamp(_thumbRadius, size.width);
    final trackPaint = Paint()..color = trackColor;
    final activePaint = Paint()..color = color;
    // 未填充段轨道
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, cy - _trackHeight / 2, size.width, _trackHeight),
        const Radius.circular(_trackHeight / 2),
      ),
      trackPaint,
    );
    // 已填充段轨道
    if (thumbX > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, cy - _trackHeight / 2, thumbX, _trackHeight),
          const Radius.circular(_trackHeight / 2),
        ),
        activePaint,
      );
    }
    // 手柄圆点
    canvas.drawCircle(Offset(thumbX, cy), _thumbRadius, activePaint);
  }

  @override
  bool shouldRepaint(_VolumeSliderPainter oldDelegate) =>
      value != oldDelegate.value ||
      color != oldDelegate.color ||
      trackColor != oldDelegate.trackColor;
}
