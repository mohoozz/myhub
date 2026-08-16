import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/core/router/app_router.dart';
import 'package:myhub_flutter/features/browse/widgets/file_cover.dart';
import 'package:myhub_flutter/shared/providers/av_player_adapter.dart';
import 'package:myhub_flutter/shared/providers/media_player_provider.dart';
import 'package:myhub_flutter/shared/widgets/media_player/media_player.dart';

/// 迷你播放器（TODO 5.7，QQ 音乐风格）。
///
/// 播放会话由全局 [mediaPlayerProvider] 持有，视图层：
/// * 移动端：嵌入底部导航栏上方（_CompactShell.bottomNavigationBar），
///   与导航栏视觉一体，导航栏高度保持 52，mini 叠加在上方不占额外空间；
/// * 桌面端：仍以悬浮 Stack 呈现（_withMiniPlayer），保留侧边栏旁的悬浮感。
///
/// 点击封面/标题区展开全屏播放器（复用同一会话）。
/// 关闭按钮停止播放并移除；向下拖拽关闭。
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
          file: file,
          onExpand: () {
            // 迷你条在移动端挂在 Scaffold.bottomNavigationBar 内，自身 context
            // 没有独立 Navigator 祖先；桌面端是 Navigator 之上的 Stack 也无
            // Navigator。统一借 GoRouter 根 navigatorKey 的 context 打开全屏页。
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
    required this.file,
    required this.onExpand,
  });

  final MediaPlayerController controller;
  final dynamic player;
  final FileItem file;

  /// 点击封面/标题区展开全屏播放器。
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

  /// 播放/暂停：播放完成后 mpv 停在末尾，直接 playOrPause() 不会重播，
  /// 需先 seek 回起点（iOS AVPlayer 模式的重播已由原生层处理）。
  void _togglePlay() {
    final p = widget.player;
    if (p is! AvPlayerAdapter && (p.state.completed as bool)) {
      p.seek(Duration.zero);
      p.play();
    } else {
      p.playOrPause();
    }
  }

  /// 解析"歌手 - 标题"格式作为副标题（QQ 音乐样式）。
  ///
  /// 仅在**带空格的明显分隔符**（" - "/" – "/" — "）下才视为作者-标题：
  /// 这样可以避免误切 —— 例如文件名 `489155.com@PRED-882-U.mp4` 中
  /// 第一个 `-`（@PRED 与 882 之间）只是路径/来源后缀，不是作者。
  /// 多数"裸"减号/下划线连接的文件名直接作为整体标题展示更符合用户预期。
  ///
  /// 仅作展示用途，解析失败时退回完整文件名。
  ({String title, String? sub}) _parseTitle(FileItem file) {
    final stem = file.name.replaceFirst(
      RegExp(r'\.[^.]+$'),
      '',
    );
    // 仅尝试"带空格"的明显分隔符（QQ 音乐/网易云音乐常见命名约定）
    for (final sep in const [' - ', ' – ', ' — ']) {
      final i = stem.indexOf(sep);
      if (i > 0 && i < stem.length - sep.length) {
        return (
          title: stem.substring(i + sep.length).trim(),
          sub: stem.substring(0, i).trim(),
        );
      }
    }
    return (title: stem, sub: null);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final file = widget.file;
    final progress = _duration > Duration.zero
        ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final parsed = _parseTitle(file);

    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 1.2),
        end: Offset.zero,
      ).animate(_enter),
      child: FadeTransition(
        opacity: _enter,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.92, end: 1).animate(_enter),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // mini 主体（不含进度条）：顶部 0 padding 让封面溢出可见。
              _buildBar(context, colorScheme, file, parsed),
              // 进度条放底部（紧贴 NavigationBar 上方）：
              // 原计划放顶部 2px，但放顶部会遮挡封面溢出——封面顶部
              // 突出于 mini 上边界是核心视觉，进度条必须让步。改到 mini
              // 底部（与 nav 顶部分隔线位置一致），仍是 2px 细条且作为
              // mini 与 nav 的唯一视觉分隔依据。
              SizedBox(
                height: 2,
                child: Stack(
                  children: [
                    Container(color: colorScheme.outline.withValues(alpha: 0.25)),
                    FractionallySizedBox(
                      widthFactor: progress.toDouble(),
                      child: Container(color: colorScheme.primary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// mini 主体：封面 + 标题/副标题 + 操作按钮。
  ///
  /// 移动端（compact=true）：QQ 音乐样式 — 48 圆角封面 + 双行标题
  /// + 收藏/播放/列表三个图标按钮。
  /// 桌面端（compact=false）：保留旧版宽胶囊布局（视频小窗 + 滑杆 + 关闭），
  /// 桌面端无 NavigationBar，不需要与底部菜单栏融合。
  Widget _buildBar(
    BuildContext context,
    ColorScheme colorScheme,
    FileItem file,
    ({String title, String? sub}) parsed,
  ) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    if (compact) {
      return _buildCompactBar(context, colorScheme, file, parsed);
    }
    return _buildDesktopBar(context, colorScheme, file, parsed);
  }

  /// QQ 音乐风格 mini：贴底菜单栏上方，整体与 nav 同色、共形。
  ///
  /// 视觉：
  /// * 高度 56（封面 40 + 上下内边距 8）；
  /// * 左侧 48×48 圆角封面（视频显示视频帧，音频显示类型图标）；
  /// * 中间双行：标题（13px 加粗）+ 副标题（11px 次色，单行省略）；
  /// * 右侧三按钮（24px）：心形（占位，当前未做收藏）、播放/暂停、
  ///   列表（占位，可后续接入播放列表）；
  /// * 顶部 2px 细进度条已在 build 中统一绘制。
  Widget _buildCompactBar(
    BuildContext context,
    ColorScheme colorScheme,
    FileItem file,
    ({String title, String? sub}) parsed,
  ) {
    // mini 背景与 nav 共色（与 NavigationBar / Card 区分）：
    //   * 亮色：白底 #FFFFFF（navBackgroundLight / cardLight 同色）
    //   * 暗色：近黑 #0A0A0A（navBackgroundDark，比 card 更黑一档）
    // colorScheme.surface 在亮色是 #EEF4FB（蓝灰），与 nav 的 #FFFFFF
    // 不同——若用 surface，mini 与 nav 之间会出现明显色缝，破坏"一体的
    // 播放器+菜单栏"观感。直接按 brightness 取 nav 同色硬编码：
    final isDark = colorScheme.brightness == Brightness.dark;
    final barColor = isDark
        ? const Color(0xFF0A0A0A) // AppColors.navBackgroundDark
        : Colors.white; // AppColors.cardLight / navBackgroundLight
    return Material(
      // 与底部导航栏共用 surface 背景色：
      // QQ 音乐样式让 mini 与 nav 视觉一体（同一色块），仅底部 2px 进度条
      // 作为分隔依据（顶部进度条改到底部，避免遮挡封面顶部溢出）。
      color: barColor,
      elevation: 0,
      // mini 上方圆角由下方 Stack 内层的 ClipRRect 处理（仅裁主体内容，
      // 不裁封面）。封面通过 Transform.translate 向上溢出 8px 自然呈现。
      child: Dismissible(
        key: widget.key!,
        direction: DismissDirection.down, // 拖拽到底部关闭
        onDismissed: (_) => widget.controller.stop(),
        child: Stack(
          clipBehavior: Clip.none, // 允许封面溢出不被裁剪
          children: [
            // 底层：mini 主体内容（标题/按钮）按顶部 16 圆角裁剪
            ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(16),
              ),
              child: Padding(
                // 顶部留 4 让封面整体仍居中：
                // 封面 56x56 向上溢出 8px，主体从封面中心下方开始布局；
                // mini 主体内容（标题+按钮）实际 Row 高度 ≈ 44，
                // 顶部 4 + 主体 44 + 底部 6 = 54 → 与封面 56 + 8 溢出 接近。
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // 占位：用与封面等宽的空白让标题区水平对齐。
                    // 封面实际渲染在 Stack 顶层（不受 Padding 影响）。
                    SizedBox(width: _CoverArt._coverSize),
                    const SizedBox(width: 10),
                    // 中间：标题 + 副标题
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.onExpand,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              parsed.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colorScheme.onSurface,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                height: 1.2,
                              ),
                            ),
                            if (parsed.sub != null && parsed.sub!.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                parsed.sub!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: colorScheme.onSurfaceVariant,
                                  fontSize: 11,
                                  height: 1.2,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    // 右侧操作按钮（心形 / 播放-暂停 / 关闭）
                    _MiniIconButton(
                      icon: LucideIcons.heart,
                      size: 22,
                      color: colorScheme.onSurfaceVariant,
                      onTap: () {
                        // 收藏入口预留：mini 上快速收藏当前播放项
                      },
                    ),
                    _MiniIconButton(
                      icon: _playing ? LucideIcons.pause : LucideIcons.play,
                      size: 28,
                      color: colorScheme.onSurface,
                      onTap: _togglePlay,
                    ),
                    _MiniIconButton(
                      icon: LucideIcons.x,
                      size: 22,
                      color: colorScheme.onSurfaceVariant,
                      // 关闭 mini：停止播放并销毁会话
                      onTap: widget.controller.stop,
                    ),
                  ],
                ),
              ),
            ),
            // 顶层：封面（不受裁剪，自然溢出 mini 上边界 8px）
            Positioned(
              left: 8,
              top: -_CoverArt._topOverflow, // 向上溢出
              child: _CoverArt(
                controller: widget.controller,
                file: file,
                onTap: widget.onExpand,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 桌面端 mini：原宽胶囊布局（视频小窗 + 音量滑杆 + 关闭）。
  ///
  /// 桌面端是侧边栏，不需要与底部菜单栏融合，保留桌面端的"灵动岛"风格
  /// （细边框 + 圆角 16），避免影响 PC 端用户既有使用习惯。
  Widget _buildDesktopBar(
    BuildContext context,
    ColorScheme colorScheme,
    FileItem file,
    ({String title, String? sub}) parsed,
  ) {
    // 桌面端继续使用 surfaceContainerHigh + 灰边框（灵动岛风格）
    final pillShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(16)),
      side: const BorderSide(
        color: Color(0xFF9E9E9E), // Material grey 500
        width: 1,
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Material(
            color: colorScheme.surfaceContainerHigh,
            elevation: 0,
            shape: pillShape,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: widget.onExpand,
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
                            _VideoThumb(
                              controller: widget.controller,
                              colorScheme: colorScheme,
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
                            Material(
                              color: colorScheme.primary,
                              shape: const CircleBorder(),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                customBorder: const CircleBorder(),
                                onTap: _togglePlay,
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
                                child: _VolumeSlider(
                                  value: (_volume / 100).clamp(0.0, 1.0),
                                  color: colorScheme.primary,
                                  trackColor: colorScheme.outlineVariant,
                                  onChanged: (v) =>
                                      widget.player.setVolume(v * 100),
                                ),
                              ),
                            _PillIconButton(
                              icon: LucideIcons.x,
                              color: colorScheme.onSurfaceVariant,
                              onTap: widget.controller.stop,
                            ),
                          ],
                        ),
                      ),
                      // 桌面端进度条放底部（与原行为一致）
                      LinearProgressIndicator(
                        value: _duration > Duration.zero
                            ? (_position.inMilliseconds /
                                    _duration.inMilliseconds)
                                .clamp(0.0, 1.0)
                            : 0.0,
                        minHeight: 2,
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
    );
  }
}

/// mini 左侧封面（QQ 音乐风格：封面顶部明显突出于 mini 上边界）。
///
/// * 视频模式且有 videoController / textureId → 显示视频帧；
/// * 音频 / 无视频帧 → 显示类型图标 + 主色调占位（与封面风格一致）。
/// 点击展开全屏播放器。
///
/// "突出"实现：mini 主体用 Stack 包装，封面在顶层用 [Positioned] 顶部
/// 偏移 `_topOverflow`（**8px**），让封面顶部显著突出于 mini 上边界，
/// 形成"封面浮在 mini 上方"的 QQ 音乐观感。Stack 的 [clipBehavior=none]
/// 保证封面不被外层裁剪。
///
/// 注：尺寸 [_coverSize]（56）大于文字双行高度（≈26px），封面整体
/// 居中靠底部对齐，与 mini 主体底部齐平。
class _CoverArt extends StatelessWidget {
  const _CoverArt({
    required this.controller,
    required this.file,
    required this.onTap,
  });

  /// 封面尺寸（QQ 音乐感：略大，比文字双行高约 30px）。
  static const double _coverSize = 56;

  /// 封面顶部溢出量（mini 上边界之上的像素数）。8px 明显可见。
  static const double _topOverflow = 8;

  final MediaPlayerController controller;
  final FileItem file;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: _coverSize,
          height: _coverSize,
          child: ValueListenableBuilder<bool>(
            valueListenable: controller.isVideoMode,
            builder: (context, isVideo, _) {
              // 视频模式：尝试渲染视频帧
              if (isVideo) {
                if (controller.useAvPlayer) {
                  final texId = controller.textureId;
                  if (texId != null && texId.value > 0) {
                    return ValueListenableBuilder<int>(
                      valueListenable: texId,
                      builder: (context, id, _) => Texture(
                        textureId: id,
                        filterQuality: FilterQuality.low,
                      ),
                    );
                  }
                } else {
                  final videoController = controller.videoController;
                  if (videoController != null) {
                    return Video(
                      controller: videoController,
                      controls: null,
                      fit: BoxFit.cover,
                      fill: Colors.black,
                    );
                  }
                }
              }
              // 音频：加载内嵌专辑封面（后端 FFmpeg 提取，缓存命中即出），
              // 无封面/加载失败回退到类型图标。视频无帧时仍显示图标。
              if (file.isAudio) {
                return FileCover(
                  item: file,
                  sourceId: controller.sourceId,
                  iconSize: 26,
                  fit: BoxFit.cover,
                  borderRadius: 8,
                );
              }
              return Container(
                color: colorScheme.primary.withValues(alpha: 0.12),
                alignment: Alignment.center,
                child: Icon(
                  file.isAudio ? LucideIcons.music : LucideIcons.film,
                  size: 26,
                  color: colorScheme.primary,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// mini 右侧小型图标按钮（紧凑点击区域，InkResponse 提供 ripple）。
///
/// 紧凑内边距（padding 6 而非 8）：三个按钮总宽度控制在 ~110px，
/// 给中间标题文字区腾出空间，避免长标题被截断过多。
class _MiniIconButton extends StatelessWidget {
  const _MiniIconButton({
    required this.icon,
    required this.color,
    required this.onTap,
    this.size = 22,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 20,
      child: Padding(
        // 紧凑点击区域：6px 比默认 8px 节省横向空间，让标题区更宽。
        padding: const EdgeInsets.all(6),
        child: Icon(icon, size: size, color: color),
      ),
    );
  }
}

/// 桌面端使用的视频缩略图（保留原 64×36 视频小窗）。
class _VideoThumb extends StatelessWidget {
  const _VideoThumb({
    required this.controller,
    required this.colorScheme,
  });

  final MediaPlayerController controller;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: controller.isVideoMode,
      builder: (context, isVideo, _) {
        if (!isVideo) {
          return Icon(
            LucideIcons.music,
            size: 18,
            color: colorScheme.onSurfaceVariant,
          );
        }
        if (controller.useAvPlayer) {
          final texId = controller.textureId;
          if (texId == null || texId.value <= 0) {
            return Container(
              width: 64,
              height: 36,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Icon(Icons.movie,
                  size: 18, color: Colors.white54),
            );
          }
          return ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 64,
              height: 36,
              child: ValueListenableBuilder<int>(
                valueListenable: texId,
                builder: (context, id, _) => Texture(
                  textureId: id,
                  filterQuality: FilterQuality.low,
                ),
              ),
            ),
          );
        }
        final videoController = controller.videoController;
        if (videoController != null) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(6),
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
    );
  }
}

/// 桌面端胶囊内的小型图标按钮（保留兼容）。
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

/// 自绘细音量滑杆：桌面端 mini 保留。
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

  final double value;
  final Color color;
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
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, cy - _trackHeight / 2, size.width, _trackHeight),
        const Radius.circular(_trackHeight / 2),
      ),
      trackPaint,
    );
    if (thumbX > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, cy - _trackHeight / 2, thumbX, _trackHeight),
          const Radius.circular(_trackHeight / 2),
        ),
        activePaint,
      );
    }
    canvas.drawCircle(Offset(thumbX, cy), _thumbRadius, activePaint);
  }

  @override
  bool shouldRepaint(_VolumeSliderPainter oldDelegate) =>
      value != oldDelegate.value ||
      color != oldDelegate.color ||
      trackColor != oldDelegate.trackColor;
}
