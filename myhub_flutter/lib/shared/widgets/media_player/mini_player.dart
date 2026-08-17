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

/// 迷你播放器（QQ 音乐风格，与 iOS 端同款）。
///
/// 播放会话由全局 [mediaPlayerProvider] 持有，视图层：
/// * 移动端：嵌入底部导航栏上方（_CompactShell.bottomNavigationBar），
///   与导航栏视觉一体（同色共形），导航栏高度保持 52；
/// * 桌面端：以悬浮 Stack 呈现（_withMiniPlayer），居中浮于内容之上，
///   加 iOS 风格阴影 / 圆角 / 描边。
///
/// 点击封面/标题区展开全屏播放器（复用同一会话）。
/// 关闭按钮停止播放并移除；移动端向下拖拽可关闭。
///
/// 注意：此处无 Navigator/Overlay 祖先——不能用 Tooltip。
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
          child: _buildBar(
            context: context,
            colorScheme: colorScheme,
            file: file,
            parsed: parsed,
            progress: progress,
          ),
        ),
      ),
    );
  }

  /// mini 主体：封面 + 标题/副标题 + 操作按钮。
  ///
  /// 统一采用 QQ 音乐风格（iOS 端同款）：
  ///
  /// * **移动端**（compact=true）：与底部 NavigationBar 同色、共形，浮在 nav 上方，
  ///   无底部 margin，整体贴合屏幕边缘；
  /// * **桌面端**（compact=false）：浮于内容之上、独立卡片，添加 iOS 风格阴影与底部
  ///   margin，居中显示（默认宽度 360-460），让 mini 像 iOS 上灵动岛那样悬浮。
  ///
  /// 视觉要素两种模式共用：
  /// * 封面超出 mini 上边界（移动 8 / 桌面 12 像素），形成封面"浮"在上方的 QQ 音乐观感；
  /// * 双行文字（标题 + 副标题，单行省略）；
  /// * 右侧操作图标（心形 / 播放-暂停 / 关闭）；
  /// * 底部 2px 细进度条（位于 mini 内部，跟随卡片圆角）。
  Widget _buildBar({
    required BuildContext context,
    required ColorScheme colorScheme,
    required FileItem file,
    required ({String title, String? sub}) parsed,
    required double progress,
  }) {
    return _buildMusicStyleBar(
      context: context,
      colorScheme: colorScheme,
      file: file,
      parsed: parsed,
      progress: progress,
      compact: MediaQuery.sizeOf(context).width < 600,
    );
  }

  /// QQ 音乐风格 mini（与 iOS 端同款）。
  ///
  /// 移动端（[compact]=true）紧密贴合底部 NavigationBar，与 nav 视觉一体；
  /// 桌面端（[compact]=false）浮于底部居中，加 iOS 风格阴影 + 圆角 + 边距。
  ///
  /// 视觉参数：
  /// * 桌面端 cover 56×56 → 64×64（适合更大屏幕）；
  /// * 桌面端溢出量 8 → 12（更明显的"封面浮在上"观感）；
  /// * 桌面端字号 13/11 → 14/12（避免在宽面板里显得偏小）。
  Widget _buildMusicStyleBar({
    required BuildContext context,
    required ColorScheme colorScheme,
    required FileItem file,
    required ({String title, String? sub}) parsed,
    required double progress,
    required bool compact,
  }) {
    final isDark = colorScheme.brightness == Brightness.dark;
    final barColor = isDark
        ? const Color(0xFF0A0A0A) // AppColors.navBackgroundDark
        : Colors.white; // AppColors.cardLight / navBackgroundLight

    // 卡片主体（不再包含封面）：
    // 封面必须放在卡片的 ClipRRect **之外**，否则顶部溢出会被裁掉。
    // 因此把封面抽到外层 Stack 的兄弟节点，与卡片并列存在。
    //
    // 内容列 + 底部进度条，按顶部 16 圆角裁剪（桌面端外层由 chrome 的 20 圆
    // 角覆盖，正好压住底部圆角，让进度条贴合卡片曲线）。
    final Widget card = Material(
      color: barColor,
      elevation: 0,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildMusicContent(
              context: context,
              colorScheme: colorScheme,
              file: file,
              parsed: parsed,
              compact: compact,
            ),
            // 底部进度条（位于卡片内部）—— 跟随桌面端 chrome 的圆角，
            // 移动端紧贴 nav 之上，与原行为一致。
            SizedBox(
              height: 2,
              child: Stack(
                children: [
                  Container(
                    color: colorScheme.outline.withValues(alpha: 0.25),
                  ),
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
    );

    // 封面节点（外层 Stack 的兄弟），允许其溢出 chrome / 卡片裁剪框。
    final Widget cover = Positioned(
      left: compact ? 8 : 14,
      top: -_MusicCoverArt._topOverflowFor(compact),
      child: _MusicCoverArt(
        controller: widget.controller,
        file: file,
        compact: compact,
        onTap: widget.onExpand,
      ),
    );

    if (compact) {
      // 移动端：外层 Stack 包住 Dismissible(card) + 浮动封面。
      return Dismissible(
        key: widget.key!,
        direction: DismissDirection.down, // 拖拽到底部关闭
        onDismissed: (_) => widget.controller.stop(),
        child: Stack(
          clipBehavior: Clip.none, // 封面溢出不被外层裁剪
          children: [card, cover],
        ),
      );
    }

    // 桌面端：iOS 风格悬浮卡，居中放置，距底部 20px；圆角 20 + 柔和阴影。
    // 关键：封面必须作为 chrome 的兄弟节点（而非 child），否则 chrome 内
    // 的 ClipRRect 会把凸出的封面顶部裁掉——这就是"完全不凸出"的原因。
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: 360,
            maxWidth: 460,
          ),
          child: Stack(
            clipBehavior: Clip.none, // 允许封面溢出 chrome 顶部不被裁剪
            children: [
              _DesktopMiniChrome(child: card),
              cover,
            ],
          ),
        ),
      ),
    );
  }

  /// mini 主体内容（封面右侧的双行 + 操作按钮）。
  ///
  /// 桌面端额外显示文件时长 / 进度数字，并加入"上一首"按钮占位。
  Widget _buildMusicContent({
    required BuildContext context,
    required ColorScheme colorScheme,
    required FileItem file,
    required ({String title, String? sub}) parsed,
    required bool compact,
  }) {
    // 字号 / 内边距在桌面端稍微放大（与较大的 cover 视觉权重匹配）。
    final titleSize = compact ? 13.0 : 14.0;
    final subSize = compact ? 11.0 : 12.0;
    // 桌面端：cover 72 上溢 18，封面在 mini 内高度为 54，需要更大的
    // verticalPad 让标题双行有足够空间、不会与 cover 上下边界挤在一起。
    final verticalPad = compact ? 4.0 : 10.0;
    final bottomPad = compact ? 6.0 : 10.0;
    final rowGap = compact ? 8.0 : 12.0;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        // 左内边距需要避让 cover 实际尺寸 + 间距。
        // 注意封面实际 left 偏移 14，标题左缘还需再留 gap 才能与封面右沿
        // 拉开距离（桌面端 cover 72 + 22 = 94，封面右沿 14+72=86，净间距 8px）。
        (compact ? _MusicCoverArt.coverSizeFor(true) : _MusicCoverArt.coverSizeFor(false)) +
            (compact ? 10 : 22),
        verticalPad,
        compact ? 8 : 10,
        bottomPad,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
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
                      fontSize: titleSize,
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
                        fontSize: subSize,
                        height: 1.2,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          SizedBox(width: rowGap),
          // 右侧操作按钮
          ..._buildMusicControls(colorScheme, compact: compact),
        ],
      ),
    );
  }

  /// 右侧图标按钮组。
  ///
  /// 移动端：心形 / 播放-暂停 / 关闭（共 3 个）。
  /// 桌面端：心形 / 播放-暂停 / 关闭（共 3 个，与移动端一致 — 上一首由
  /// 全屏播放页提供，mini 仅承载最高频的"播放控制"避免按钮过密）。
  List<Widget> _buildMusicControls(ColorScheme colorScheme, {required bool compact}) {
    return [
      _MiniIconButton(
        icon: LucideIcons.heart,
        size: compact ? 22 : 24,
        color: colorScheme.onSurfaceVariant,
        onTap: () {
          // 收藏入口预留：mini 上快速收藏当前播放项
        },
      ),
      _MiniIconButton(
        icon: _playing ? LucideIcons.pause : LucideIcons.play,
        size: compact ? 28 : 30,
        color: colorScheme.onSurface,
        onTap: _togglePlay,
      ),
      _MiniIconButton(
        icon: LucideIcons.x,
        size: compact ? 22 : 24,
        color: colorScheme.onSurfaceVariant,
        onTap: widget.controller.stop,
      ),
    ];
  }
}

/// mini 左侧封面（QQ 音乐风格：封面顶部明显突出于 mini 上边界）。
///
/// * 视频模式且有 videoController / textureId → 显示视频帧；
/// * 音频 / 无视频帧 → 显示类型图标 + 主色调占位（与封面风格一致）。
/// 点击展开全屏播放器。
///
/// "突出"实现：mini 主体用 Stack 包装，封面在顶层用 [Positioned] 顶部
/// 偏移 [_topOverflow]（移动 8 / 桌面 12 像素），让封面顶部显著突出于 mini
/// 上边界，形成"封面浮在 mini 上方"的 QQ 音乐观感。Stack 的 [clipBehavior=none]
/// 保证封面不被外层裁剪。桌面端额外加一圈阴影让封面"上浮感"更强。
class _MusicCoverArt extends StatelessWidget {
  const _MusicCoverArt({
    required this.controller,
    required this.file,
    required this.onTap,
    required this.compact,
  });

  final MediaPlayerController controller;
  final FileItem file;
  final VoidCallback onTap;
  final bool compact;

  /// 平台自适应封面尺寸。
  ///
  /// 移动端 56（与原 QQ 音乐一致），桌面端 64（搭配顶部溢出 9，使封面
  /// 高度 ≈ 卡片内净高 — 让封面下沿正好贴在进度条上方，标题文字双行
  /// 被封面"包"在视觉中心，避免封面落到卡片外）。
  /// 计算：Card 内净高 ≈ verticalPad 10 + titleRow 38 + bottomPad 10 = 58，
  /// cover 64 - topOverflow 9 = 55 ≈ 58，留 3px 余量让封面干净落入卡内。
  static double coverSizeFor(bool compact) => compact ? 56 : 64;

  /// 平台自适应顶部溢出量：桌面端 ~1/7 封面高（64 的 1/7 ≈ 9），让
  /// 封面顶部以"轻浮"姿态突出于 mini 上边界——略凸但不喧宾夺主，
  /// 既保留 QQ 音乐/iOS Now Playing 观感，又给标题区留出充足视觉空间。
  static double _topOverflowFor(bool compact) => compact ? 8 : 9;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final size = coverSizeFor(compact);
    // 桌面端：封面外加一圈柔和阴影，增强"上浮"质感（iOS 卡片感）。
    final cover = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(compact ? 8 : 12),
        child: SizedBox(
          width: size,
          height: size,
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
                  iconSize: compact ? 26 : 32,
                  fit: BoxFit.cover,
                  borderRadius: compact ? 8 : 12,
                );
              }
              return Container(
                color: colorScheme.primary.withValues(alpha: 0.12),
                alignment: Alignment.center,
                child: Icon(
                  file.isAudio ? LucideIcons.music : LucideIcons.film,
                  size: compact ? 26 : 32,
                  color: colorScheme.primary,
                ),
              );
            },
          ),
        ),
      ),
    );

    if (compact) return cover;

    // 桌面端：封面外加一圈柔和阴影，与下方卡片的阴影形成两层深度。
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: colorScheme.brightness == Brightness.dark ? 0.55 : 0.22,
            ),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: cover,
    );
  }
}

/// 桌面端 mini 的 iOS 风格外壳：圆角 20 + 柔和阴影 + 1px 细边框。
///
/// 桌面端 mini 是浮于内容之上的"独立卡"，需要明显投影与轻微描边
/// 才能从深色 / 蓝色背景中跳出来（与 Material You / iOS Now Playing
/// 卡片观感一致）。
class _DesktopMiniChrome extends StatelessWidget {
  const _DesktopMiniChrome({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = colorScheme.brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        // 桌面端阴影：iOS 风格柔和多层阴影 + 微弱描边。
        // 亮色下阴影更淡，用细灰边增加可识别度；
        // 暗色下阴影更深，无须描边（背景已深）。
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.55 : 0.14),
            blurRadius: 32,
            offset: const Offset(0, 12),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.06),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.06),
          width: 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: child,
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
