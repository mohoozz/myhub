import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Home page — "正在阅读" continue-reading grid.
///
/// TODO(api): replace the mock items with the continue-reading endpoint.
class ReadingScreen extends StatelessWidget {
  const ReadingScreen({super.key});

  static const List<_ReadingItem> _items = [
    _ReadingItem(
      title: '第三百章 / 测试卷…',
      meta: '第 229 页 · 1 小时前',
      source: 'PC',
      progress: 0.72,
      coverIcon: LucideIcons.bookOpen,
      badgeIcon: LucideIcons.image,
      colors: [Color(0xFF7C3AED), Color(0xFFDB2777)],
    ),
    _ReadingItem(
      title: '【nara 朗读】双城…',
      meta: '看到 19 分钟 · 3…',
      source: 'PC',
      progress: 0.45,
      coverIcon: LucideIcons.film,
      badgeIcon: LucideIcons.play,
      colors: [Color(0xFF0F766E), Color(0xFF155E75)],
    ),
    _ReadingItem(
      title: '硬核哲学 277.zip',
      meta: '第 9 页 · 4 小时前',
      source: 'PC',
      progress: 0.12,
      coverIcon: LucideIcons.bookOpen,
      badgeIcon: LucideIcons.image,
      colors: [Color(0xFF334155), Color(0xFF0F172A)],
    ),
    _ReadingItem(
      title: '地灵光 2025-12-…',
      meta: '看到 23 分钟 · 22…',
      source: 'PC',
      progress: 0.58,
      coverIcon: LucideIcons.music,
      badgeIcon: LucideIcons.headphones,
      colors: [Color(0xFF2563EB), Color(0xFF7C3AED)],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '正在阅读',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${_items.length} 项',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        onPressed: () {},
                        icon: const Icon(LucideIcons.menu, size: 18),
                        color: theme.colorScheme.onSurfaceVariant,
                        tooltip: '更多',
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 220,
                          mainAxisSpacing: 16,
                          crossAxisSpacing: 16,
                          childAspectRatio: 0.98,
                        ),
                    itemCount: _items.length,
                    itemBuilder: (context, index) =>
                        _ReadingCard(item: _items[index]),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReadingItem {
  const _ReadingItem({
    required this.title,
    required this.meta,
    required this.source,
    required this.progress,
    required this.coverIcon,
    required this.badgeIcon,
    required this.colors,
  });

  final String title;
  final String meta;
  final String source;
  final double progress;
  final IconData coverIcon;
  final IconData badgeIcon;
  final List<Color> colors;
}

class _ReadingCard extends StatelessWidget {
  const _ReadingCard({required this.item});

  final _ReadingItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Material(
      color: theme.cardTheme.color,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {},
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 10,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: item.colors,
                      ),
                    ),
                    child: Center(
                      child: Icon(
                        item.coverIcon,
                        size: 36,
                        color: Colors.white.withValues(alpha: 0.75),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Icon(
                        item.badgeIcon,
                        size: 13,
                        color: colorScheme.onSurfaceVariant,
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
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: item.source,
                          style: TextStyle(
                            color: colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        TextSpan(
                          text: '  ${item.meta}',
                          style: TextStyle(color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
            ),
            const Spacer(),
            LinearProgressIndicator(
              value: item.progress,
              minHeight: 3,
              backgroundColor: colorScheme.outline.withValues(alpha: 0.4),
            ),
          ],
        ),
      ),
    );
  }
}
