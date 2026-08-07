import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/api/comic_api.dart';
import 'package:myhub_flutter/core/api/file_api.dart';
import 'package:myhub_flutter/core/models/reading_progress.dart';
import 'package:myhub_flutter/shared/providers/auth_headers_provider.dart';
import 'package:myhub_flutter/shared/utils/format.dart';

/// "正在阅读"进度卡片：封面/类型图标、类型徽标、标题、源名、进度条、相对时间。
class ReadingCard extends ConsumerWidget {
  const ReadingCard({
    super.key,
    required this.progress,
    required this.sourceName,
    this.onTap,
    this.onLongPress,
    this.onShowMenu,
    this.selectionMode = false,
    this.selected = false,
  });

  final ReadingProgress progress;
  final String sourceName;
  final VoidCallback? onTap;

  /// 多选模式下长按切换选中；非多选模式下长按由 [onShowMenu] 弹出菜单。
  final VoidCallback? onLongPress;

  /// PC 端右键 / 移动端长按触发：在对应位置弹出上下文菜单（信息/定位/删除）。
  final void Function(Offset globalPosition)? onShowMenu;

  /// 多选模式：显示选中框并高亮选中项。
  final bool selectionMode;

  /// 当前是否被选中（多选模式下生效）。
  final bool selected;

  static const _typeColors = {
    'novel': [Color(0xFF7C3AED), Color(0xFFDB2777)],
    'comic': [Color(0xFF334155), Color(0xFF0F172A)],
    'video': [Color(0xFF0F766E), Color(0xFF155E75)],
    'audio': [Color(0xFF2563EB), Color(0xFF7C3AED)],
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final title = progress.title.isNotEmpty
        ? progress.title
        : progress.filePath.split('/').last;

    return Material(
      color: selected
          ? colorScheme.primary.withValues(alpha: 0.08)
          : theme.cardTheme.color,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: GestureDetector(
        // 移动端长按（非多选模式）：在按下的位置弹出与右键相同的菜单
        onLongPressStart: selectionMode
            ? null
            : (d) => onShowMenu?.call(d.globalPosition),
        child: InkWell(
          onTap: onTap,
          onLongPress: selectionMode ? onLongPress : null,
          onSecondaryTapUp: selectionMode
              ? null
              : (d) => onShowMenu?.call(d.globalPosition),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 16 / 10,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ReadingCover(progress: progress),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: selectionMode
                          ? ReadingSelectBadge(selected: selected)
                          : ReadingTypeBadge(mediaType: progress.mediaType),
                    ),
                    if (!selectionMode && progress.finished)
                      const Positioned(
                        bottom: 8,
                        right: 8,
                        child: _FinishedBadge(),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (sourceName.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        sourceName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.75,
                          ),
                          fontSize: 10,
                        ),
                      ),
                    ],
                    const SizedBox(height: 3),
                    Text(
                      progress.finished
                          ? '已读完 · ${formatRelativeTime(progress.updatedAt)}'
                          : '${progress.percent.toStringAsFixed(0)}% · '
                                '${formatRelativeTime(progress.updatedAt)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              LinearProgressIndicator(
                value: (progress.percent / 100).clamp(0.0, 1.0),
                minHeight: 4,
                backgroundColor: colorScheme.outline.withValues(alpha: 0.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 已读完徽标（叠加在封面右下角）。
class _FinishedBadge extends StatelessWidget {
  const _FinishedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.checkCheck, size: 11, color: Colors.white),
          SizedBox(width: 3),
          Text(
            '已读完',
            style: TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 多选模式右上角的圆形选中/未选中标记。
class ReadingSelectBadge extends StatelessWidget {
  const ReadingSelectBadge({super.key, required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected
            ? colorScheme.primary
            : Colors.black.withValues(alpha: 0.35),
        border: Border.all(
          color: selected ? colorScheme.primary : Colors.white54,
          width: 1.5,
        ),
      ),
      child: selected
          ? Icon(
              LucideIcons.check,
              size: 13,
              color: theme.colorScheme.onPrimary,
            )
          : null,
    );
  }
}

/// "正在阅读"类型徽标：小说/漫画/视频/音频。
class ReadingTypeBadge extends StatelessWidget {
  const ReadingTypeBadge({super.key, required this.mediaType});

  final String mediaType;

  static const _labels = {
    'novel': '小说',
    'comic': '漫画',
    'video': '视频',
    'audio': '音频',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        _labels[mediaType] ?? '其他',
        style: theme.textTheme.labelSmall?.copyWith(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 阅读封面：优先 cover 字段图片；视频/音频回退到 FFmpeg 缩略图，
/// 漫画回退到第一页；其余按类型渐变 + 图标。
class ReadingCover extends ConsumerWidget {
  const ReadingCover({super.key, required this.progress, this.iconSize = 36});

  final ReadingProgress progress;
  final double iconSize;

  IconData get _icon => switch (progress.mediaType) {
    'video' => LucideIcons.film,
    'audio' => LucideIcons.music,
    'novel' => LucideIcons.bookOpen,
    'comic' => LucideIcons.images,
    _ => LucideIcons.file,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors =
        ReadingCard._typeColors[progress.mediaType] ??
        const [Color(0xFF475569), Color(0xFF1E293B)];
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
      ),
      child: Center(
        child: Icon(
          _icon,
          size: iconSize,
          color: Colors.white.withValues(alpha: 0.75),
        ),
      ),
    );

    String? url;
    if (progress.cover.isNotEmpty) {
      url = progress.cover;
    } else if (progress.mediaType == 'video' || progress.mediaType == 'audio') {
      url = ref
          .read(fileApiProvider)
          .thumbnailUrl(progress.sourceId, progress.filePath);
    } else if (progress.mediaType == 'comic') {
      url = ref
          .read(comicApiProvider)
          .pageUrl(progress.sourceId, progress.filePath, 0);
    }
    if (url == null) return fallback;

    final headers = ref.watch(authHeadersProvider).valueOrNull;
    if (headers == null) return fallback;
    return CachedNetworkImage(
      imageUrl: url,
      httpHeaders: headers,
      fit: BoxFit.cover,
      fadeInDuration: const Duration(milliseconds: 150),
      placeholder: (_, __) => fallback,
      errorWidget: (_, __, ___) => fallback,
    );
  }
}

/// 列表视图行：小封面、标题、类型徽标、源名、百分比/相对时间、进度条。
class ReadingListTile extends ConsumerWidget {
  const ReadingListTile({
    super.key,
    required this.progress,
    required this.sourceName,
    this.onTap,
    this.onLongPress,
    this.onShowMenu,
    this.selectionMode = false,
    this.selected = false,
  });

  final ReadingProgress progress;
  final String sourceName;
  final VoidCallback? onTap;

  /// 多选模式下长按切换选中；非多选模式下长按由 [onShowMenu] 弹出菜单。
  final VoidCallback? onLongPress;

  /// PC 端右键 / 移动端长按触发：在对应位置弹出上下文菜单（信息/定位/删除）。
  final void Function(Offset globalPosition)? onShowMenu;

  final bool selectionMode;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final title = progress.title.isNotEmpty
        ? progress.title
        : progress.filePath.split('/').last;

    return GestureDetector(
      // 移动端长按（非多选模式）：在按下的位置弹出与右键相同的菜单
      onLongPressStart: selectionMode
          ? null
          : (d) => onShowMenu?.call(d.globalPosition),
      child: InkWell(
        onTap: onTap,
        onLongPress: selectionMode ? onLongPress : null,
        onSecondaryTapUp: selectionMode
            ? null
            : (d) => onShowMenu?.call(d.globalPosition),
        child: Container(
          color: selected ? colorScheme.primary.withValues(alpha: 0.08) : null,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              if (selectionMode) ...[
                ReadingSelectBadge(selected: selected),
                const SizedBox(width: 10),
              ],
              SizedBox(
                width: 44,
                height: 44,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: ReadingCover(progress: progress, iconSize: 20),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ReadingTypeBadge(mediaType: progress.mediaType),
                      ],
                    ),
                    if (sourceName.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        sourceName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.75,
                          ),
                          fontSize: 10,
                        ),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: (progress.percent / 100).clamp(0.0, 1.0),
                              minHeight: 4,
                              backgroundColor: colorScheme.outline.withValues(
                                alpha: 0.4,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          progress.finished
                              ? '已读完 · ${formatRelativeTime(progress.updatedAt)}'
                              : '${progress.percent.toStringAsFixed(0)}% · '
                                    '${formatRelativeTime(progress.updatedAt)}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
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
