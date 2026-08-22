import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/models/feed.dart';
import 'package:myhub_flutter/features/feed/widgets/feed_card.dart'
    show PlatformBadge, MediaTypeBadge;
import 'package:myhub_flutter/shared/utils/format.dart';

/// 单条动态沉浸式详情卡片：整页展示封面大图、作者、标题、完整描述与操作。
class FeedDetailCard extends StatelessWidget {
  const FeedDetailCard({
    super.key,
    required this.item,
    required this.bookmarked,
    required this.onOpen,
    required this.onToggleBookmark,
  });

  final FeedItem item;
  final bool bookmarked;
  final VoidCallback onOpen;
  final VoidCallback onToggleBookmark;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hasCover = item.cover.isNotEmpty;
    final hasDescription = item.description.isNotEmpty;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头部：平台 + 作者 + 相对时间
          Row(
            children: [
              PlatformBadge(platform: item.platform),
              const SizedBox(width: 8),
              if (item.author.isNotEmpty)
                Expanded(
                  child: Text(
                    item.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              const SizedBox(width: 8),
              Text(
                item.publishedAt == null
                    ? ''
                    : formatRelativeTime(item.publishedAt!),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // 标题
          Text(
            item.title.isEmpty ? item.description : item.title,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              height: 1.3,
            ),
          ),
          if (hasCover) ...[
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Image.network(
                  item.cover,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _coverFallback(theme),
                ),
              ),
            ),
          ],
          // 完整描述
          if (hasDescription) ...[
            const SizedBox(height: 14),
            Text(
              item.description,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
            ),
          ],
          const SizedBox(height: 20),
          // 操作区
          Row(
            children: [
              FilledButton.icon(
                onPressed: onOpen,
                icon: const Icon(LucideIcons.externalLink, size: 16),
                label: const Text('打开原站'),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: onToggleBookmark,
                icon: Icon(
                  LucideIcons.bookmark,
                  size: 16,
                  color: bookmarked ? colorScheme.primary : null,
                ),
                label: Text(bookmarked ? '已收藏' : '稍后观看'),
              ),
              const Spacer(),
              MediaTypeBadge(mediaType: item.mediaType),
            ],
          ),
        ],
      ),
    );
  }

  Widget _coverFallback(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          LucideIcons.image,
          size: 40,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
