import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/api/file_api.dart';
import 'package:myhub_flutter/core/models/reading_progress.dart';
import 'package:myhub_flutter/shared/providers/auth_headers_provider.dart';
import 'package:myhub_flutter/shared/utils/format.dart';

/// "正在阅读"进度卡片：封面/类型图标、类型徽标、标题、进度条、相对时间。
class ReadingCard extends ConsumerWidget {
  const ReadingCard({
    super.key,
    required this.progress,
    this.onTap,
    this.onLongPress,
  });

  final ReadingProgress progress;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  static const _typeLabels = {
    'novel': '小说',
    'comic': '漫画',
    'video': '视频',
    'audio': '音频',
  };

  static const _typeColors = {
    'novel': [Color(0xFF7C3AED), Color(0xFFDB2777)],
    'comic': [Color(0xFF334155), Color(0xFF0F172A)],
    'video': [Color(0xFF0F766E), Color(0xFF155E75)],
    'audio': [Color(0xFF2563EB), Color(0xFF7C3AED)],
  };

  IconData get _icon => switch (progress.mediaType) {
        'video' => LucideIcons.film,
        'audio' => LucideIcons.music,
        'novel' => LucideIcons.bookOpen,
        'comic' => LucideIcons.images,
        _ => LucideIcons.file,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final title = progress.title.isNotEmpty
        ? progress.title
        : progress.filePath.split('/').last;

    return Material(
      color: theme.cardTheme.color,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 10,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _Cover(progress: progress, icon: _icon),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.primary,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        _typeLabels[progress.mediaType] ?? '其他',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
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
                  const SizedBox(height: 3),
                  Text(
                    '${progress.percent.toStringAsFixed(0)}% · '
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
    );
  }
}

/// 卡片封面：优先 cover 字段图片；视频回退到 FFmpeg 缩略图；
/// 其余按类型渐变 + 图标。
class _Cover extends ConsumerWidget {
  const _Cover({required this.progress, required this.icon});

  final ReadingProgress progress;
  final IconData icon;

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
        child: Icon(icon, size: 36, color: Colors.white.withValues(alpha: 0.75)),
      ),
    );

    String? url;
    if (progress.cover.isNotEmpty) {
      url = progress.cover;
    } else if (progress.mediaType == 'video') {
      url = ref
          .read(fileApiProvider)
          .thumbnailUrl(progress.sourceId, progress.filePath);
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
