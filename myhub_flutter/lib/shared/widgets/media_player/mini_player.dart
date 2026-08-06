import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:media_kit/media_kit.dart';
import 'package:myhub_flutter/core/router/app_router.dart';
import 'package:myhub_flutter/shared/providers/media_player_provider.dart';
import 'package:myhub_flutter/shared/widgets/media_player/media_player.dart';

/// 迷你播放器（TODO 5.7）：底部迷你条，跨页面保持。
///
/// 挂载在 MaterialApp `builder` 的 Stack 中（Navigator 之上），
/// 播放会话由全局 [mediaPlayerProvider] 持有：
/// * 顶部 2px 细进度条 + 文件名 + 播放/暂停圆形按钮 + 关闭按钮；
/// * 点击迷你条重新展开全屏播放器（复用同一会话）；
/// * 关闭按钮 / 向下拖拽：停止播放并移除。
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(mediaPlayerProvider);
    return ValueListenableBuilder<bool>(
      valueListenable: controller.miniVisible,
      builder: (context, visible, _) {
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
  final Player player;

  /// 点击迷你条展开全屏播放器。
  final VoidCallback onExpand;

  @override
  State<_MiniPlayerBar> createState() => _MiniPlayerBarState();
}

class _MiniPlayerBarState extends State<_MiniPlayerBar> {
  final List<StreamSubscription<dynamic>> _subs = [];

  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    final player = widget.player;
    _playing = player.state.playing;
    _position = player.state.position;
    _duration = player.state.duration;
    _subs.addAll([
      player.stream.playing.listen((v) {
        if (mounted) setState(() => _playing = v);
      }),
      player.stream.position.listen((v) {
        if (mounted) setState(() => _position = v);
      }),
      player.stream.duration.listen((v) {
        if (mounted) setState(() => _duration = v);
      }),
    ]);
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final file = widget.controller.file!;
    final progress = _duration > Duration.zero
        ? (_position.inMilliseconds / _duration.inMilliseconds)
            .clamp(0.0, 1.0)
        : 0.0;

    // 注：此处位于 Navigator 之上，不能用 Tooltip（无 Overlay 祖先）
    return Dismissible(
      key: widget.key!,
      direction: DismissDirection.down, // 拖拽到底部关闭
      onDismissed: (_) => widget.controller.stop(),
      child: Material(
        color: colorScheme.surface,
        elevation: 8,
        child: InkWell(
          onTap: widget.onExpand, // 点击展开全屏播放器（复用同一会话）
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 顶部 2px 细进度条
              LinearProgressIndicator(
                value: progress.toDouble(),
                minHeight: 2,
                backgroundColor: colorScheme.outlineVariant,
                valueColor:
                    AlwaysStoppedAnimation<Color>(colorScheme.primary),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      file.isAudio ? LucideIcons.music : LucideIcons.film,
                      size: 18,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        file.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    // 播放/暂停圆形按钮
                    Material(
                      color: colorScheme.primary,
                      shape: const CircleBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: widget.player.playOrPause,
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Icon(
                            _playing ? LucideIcons.pause : LucideIcons.play,
                            size: 16,
                            color: colorScheme.onPrimary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    // 关闭：停止播放并移除
                    IconButton(
                      iconSize: 18,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(LucideIcons.x),
                      onPressed: widget.controller.stop,
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
}
