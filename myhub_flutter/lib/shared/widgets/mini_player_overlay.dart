import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/shared/providers/mini_player_provider.dart';

/// 迷你播放器 Overlay 内容条。
///
/// 挂载在 MaterialApp `builder` 的 Stack 中（Navigator 之上），
/// 因此 Tab 切换、全屏路由跳转都不会销毁它。
/// 视觉细节在第 5 章播放器模块中完善，此处提供最小可用交互：
/// 展示标题、播放/暂停切换、关闭。
class MiniPlayerOverlay extends ConsumerWidget {
  const MiniPlayerOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(miniPlayerProvider);
    if (state == null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      elevation: 8,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 顶部 2px 播放进度条（视觉规范细化见 5.7）
          LinearProgressIndicator(
            value: state.progress,
            minHeight: 2,
            backgroundColor: theme.colorScheme.outlineVariant,
            valueColor:
                AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Icon(
                  state.playing ? LucideIcons.pause : LucideIcons.play,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    state.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                // 注：此处位于 Navigator 之上，不能用 Tooltip（无 Overlay 祖先）
                IconButton(
                  iconSize: 18,
                  icon: Icon(
                    state.playing ? LucideIcons.pause : LucideIcons.play,
                  ),
                  onPressed: () =>
                      ref.read(miniPlayerProvider.notifier).togglePlaying(),
                ),
                IconButton(
                  iconSize: 18,
                  icon: const Icon(LucideIcons.x),
                  onPressed: () =>
                      ref.read(miniPlayerProvider.notifier).hide(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
