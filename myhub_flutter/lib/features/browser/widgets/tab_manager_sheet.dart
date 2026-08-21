import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:myhub_flutter/features/browser/browser_provider.dart';

/// iOS 标签管理页（F-601 13.4）：Safari 风格卡片网格。
///
/// * 卡片网格展示各标签（域名 / 标题）；
/// * 底部工具栏：标签数切换、新建、无痕开关；
/// * 长按标签：关闭其他、关闭全部。
class TabManagerSheet extends ConsumerStatefulWidget {
  const TabManagerSheet({super.key, required this.onClose});

  /// 关闭标签管理页（返回浏览）。
  final VoidCallback onClose;

  @override
  ConsumerState<TabManagerSheet> createState() => _TabManagerSheetState();
}

class _TabManagerSheetState extends ConsumerState<TabManagerSheet> {
  /// 无痕模式（新建标签时应用）。
  bool _incognito = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final tabs = ref.watch(browserTabsProvider);
    final activeIndex = ref.watch(activeBrowserTabIndexProvider);
    final notifier = ref.read(browserTabsProvider.notifier);

    return Scaffold(
      backgroundColor: colorScheme.surfaceContainerLowest,
      body: SafeArea(
        child: Column(
          children: [
            // 顶部标题栏
            _buildHeader(theme, tabs.length),
            // 卡片网格
            Expanded(
              child: tabs.isEmpty
                  ? const Center(child: Text('没有打开的标签页'))
                  : GridView.builder(
                      padding: const EdgeInsets.all(16),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            childAspectRatio: 1.1,
                          ),
                      itemCount: tabs.length,
                      itemBuilder: (context, index) {
                        final tab = tabs[index];
                        return _TabCard(
                          tab: tab,
                          active: index == activeIndex,
                          onTap: () {
                            notifier.activate(tab.id);
                            widget.onClose();
                          },
                          onClose: () => notifier.closeTab(tab.id),
                          onLongPress: () => _showContextMenu(context, tab),
                        );
                      },
                    ),
            ),
            // 底部工具栏
            _buildBottomBar(theme, colorScheme, tabs.length),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Text(
            '$count 个标签页',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          IconButton(
            onPressed: widget.onClose,
            icon: const Icon(LucideIcons.chevronDown),
            tooltip: '收起',
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(ThemeData theme, ColorScheme colorScheme, int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(top: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: Row(
        children: [
          // 新建标签
          IconButton(
            onPressed: () {
              ref
                  .read(browserTabsProvider.notifier)
                  .newTab(incognito: _incognito);
              // 新建后回到浏览页并聚焦地址栏
              widget.onClose();
            },
            icon: const Icon(LucideIcons.plus),
            tooltip: '新建标签页',
          ),
          // 标签数切换提示
          Expanded(
            child: Center(
              child: Text(
                '$count 个标签页',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          // 无痕开关
          IconButton(
            onPressed: () => setState(() => _incognito = !_incognito),
            icon: Icon(
              _incognito ? LucideIcons.eyeOff : LucideIcons.eye,
              color: _incognito ? colorScheme.primary : colorScheme.onSurface,
            ),
            tooltip: _incognito ? '无痕模式开' : '无痕模式关',
          ),
        ],
      ),
    );
  }

  void _showContextMenu(BuildContext context, BrowserTabState tab) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(LucideIcons.copy),
              title: const Text('关闭其他标签页'),
              onTap: () {
                Navigator.pop(sheetContext);
                ref.read(browserTabsProvider.notifier).closeOthers(tab.id);
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.trash2),
              title: const Text('关闭全部标签页'),
              onTap: () {
                Navigator.pop(sheetContext);
                ref.read(browserTabsProvider.notifier).closeAll();
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 单个标签卡片：缩略占位 + 域名 + 标题 + 关闭按钮。
class _TabCard extends StatelessWidget {
  const _TabCard({
    required this.tab,
    required this.active,
    required this.onTap,
    required this.onClose,
    required this.onLongPress,
  });

  final BrowserTabState tab;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final title = tab.isNewTab
        ? '新标签页'
        : (tab.title.isEmpty ? tab.host : tab.title);
    final host = tab.host;

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: active
              ? Border.all(color: colorScheme.primary, width: 2)
              : Border.all(color: colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 卡片头部：favicon + 域名 + 关闭按钮
            Container(
              color: colorScheme.surfaceContainerHigh,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  if (tab.incognito)
                    Icon(
                      LucideIcons.eyeOff,
                      size: 14,
                      color: colorScheme.onSurfaceVariant,
                    )
                  else if (tab.faviconUrl.isNotEmpty)
                    Image.network(
                      tab.faviconUrl,
                      width: 14,
                      height: 14,
                      errorBuilder: (_, __, ___) => Icon(
                        LucideIcons.globe,
                        size: 14,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    )
                  else
                    Icon(
                      LucideIcons.globe,
                      size: 14,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      host.isEmpty ? '新标签页' : host,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
                  // 关闭按钮
                  InkWell(
                    onTap: onClose,
                    customBorder: const CircleBorder(),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(
                        LucideIcons.x,
                        size: 14,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // 标题
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurface,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
