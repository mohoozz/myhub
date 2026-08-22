import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/models/feed.dart';
import 'package:myhub_flutter/shared/utils/format.dart';

/// 平台徽标样式（徽标短名 + 主题色）。
class PlatformBadge extends StatelessWidget {
  const PlatformBadge({super.key, required this.platform});

  final String platform;

  static final _colors = <String, Color>{
    'bilibili': const Color(0xFF00A1D6),
    'youtube': const Color(0xFFFF0000),
    'douyin': const Color(0xFF161823),
  };

  static final _labels = <String, String>{
    'bilibili': 'B站',
    'youtube': 'YT',
    'douyin': '抖音',
  };

  @override
  Widget build(BuildContext context) {
    final color = _colors[platform] ?? const Color(0xFF607D8B);
    final label = _labels[platform] ?? platform;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
          height: 1.2,
        ),
      ),
    );
  }
}

/// 媒体类型徽标（视频/音频/文章）。
class MediaTypeBadge extends StatelessWidget {
  const MediaTypeBadge({super.key, required this.mediaType});

  final String mediaType;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, label) = switch (mediaType) {
      'video' => (LucideIcons.video, '视频'),
      'audio' => (LucideIcons.music, '音频'),
      'article' => (LucideIcons.fileText, '文章'),
      _ => (LucideIcons.file, '动态'),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 3),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// 动态卡片：平台徽标、作者、封面缩略图、标题、发布时间（相对时间）、类型徽标。
class FeedCard extends StatelessWidget {
  const FeedCard({
    super.key,
    required this.item,
    required this.unread,
    required this.bookmarked,
    required this.onTap,
    required this.onToggleBookmark,
  });

  final FeedItem item;

  /// 是否未读（位于已读游标之后）。
  final bool unread;

  /// 是否已加入稍后观看。
  final bool bookmarked;
  final VoidCallback onTap;
  final VoidCallback onToggleBookmark;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hasCover = item.cover.isNotEmpty;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hasCover)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  item.cover,
                  width: 88,
                  height: 66,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _coverFallback(theme),
                ),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      PlatformBadge(platform: item.platform),
                      const SizedBox(width: 6),
                      if (item.author.isNotEmpty)
                        Expanded(
                          child: Text(
                            item.author,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      if (unread)
                        Container(
                          width: 8,
                          height: 8,
                          margin: const EdgeInsets.only(left: 6),
                          decoration: BoxDecoration(
                            color: colorScheme.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    item.title.isEmpty ? item.description : item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.publishedAt == null
                              ? ''
                              : formatRelativeTime(item.publishedAt!),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      MediaTypeBadge(mediaType: item.mediaType),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: Icon(
                bookmarked ? LucideIcons.bookmark : LucideIcons.bookmark,
                size: 18,
                color: bookmarked
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
              ),
              onPressed: onToggleBookmark,
              tooltip: bookmarked ? '移出稍后观看' : '稍后观看',
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }

  Widget _coverFallback(ThemeData theme) {
    return Container(
      width: 88,
      height: 66,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Icon(
        LucideIcons.image,
        size: 22,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
