import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/features/browser/browser_provider.dart';
import 'package:myhub_flutter/features/browser/browser_settings.dart';
import 'package:myhub_flutter/features/browser/widgets/address_bar.dart'
    show resolveNavigationUrl;
import 'package:myhub_flutter/features/browser/widgets/shortcut_dialogs.dart';
import 'package:reorderable_grid_view/reorderable_grid_view.dart';

/// 新标签页 / 起始页（F-602）：默认搜索引擎大搜索框 + 常用站点快捷入口网格。
///
/// * 搜索框：输入后 Enter 走默认搜索引擎（复用 [resolveNavigationUrl]）；
/// * 快捷入口网格：favicon + 标题，点击导航；
/// * 管理：空位"+"添加、长按编辑/删除、拖拽排序。
class StartPage extends ConsumerStatefulWidget {
  const StartPage({super.key, required this.onOpenUrl});

  /// 用户请求导航到某个 URL（搜索提交 / 快捷入口点击）。
  final void Function(String url) onOpenUrl;

  @override
  ConsumerState<StartPage> createState() => _StartPageState();
}

class _StartPageState extends ConsumerState<StartPage> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _submitSearch() {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;
    final template = ref.read(browserSettingsProvider).searchUrlTemplate;
    widget.onOpenUrl(resolveNavigationUrl(query, searchUrlTemplate: template));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final shortcutsAsync = ref.watch(shortcutsProvider);

    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Logo / 标题
              Icon(LucideIcons.globe, size: 48, color: colorScheme.primary),
              const SizedBox(height: 16),
              // 大搜索框
              _buildSearchBox(theme, colorScheme),
              const SizedBox(height: 32),
              // 快捷入口网格
              _buildShortcutGrid(theme, colorScheme, shortcutsAsync),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchBox(ThemeData theme, ColorScheme colorScheme) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 560),
      height: 48,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: colorScheme.outline),
        boxShadow: [
          BoxShadow(
            color: colorScheme.shadow.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          const SizedBox(width: 16),
          Icon(
            LucideIcons.search,
            size: 20,
            color: colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocus,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _submitSearch(),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurface,
              ),
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: '搜索或输入网址',
                hintStyle: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildShortcutGrid(
    ThemeData theme,
    ColorScheme colorScheme,
    AsyncValue<List<ShortcutItem>> shortcutsAsync,
  ) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640),
      child: shortcutsAsync.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(),
        ),
        error: (err, _) => _buildErrorState(theme, colorScheme, err),
        data: (items) => _buildGrid(theme, colorScheme, items),
      ),
    );
  }

  Widget _buildErrorState(
    ThemeData theme,
    ColorScheme colorScheme,
    Object err,
  ) {
    return Column(
      children: [
        Icon(
          LucideIcons.wifiOff,
          size: 32,
          color: colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 8),
        Text(
          '快捷入口加载失败',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => ref.invalidate(shortcutsProvider),
          child: const Text('重试'),
        ),
      ],
    );
  }

  Widget _buildGrid(
    ThemeData theme,
    ColorScheme colorScheme,
    List<ShortcutItem> items,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ReorderableGridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 1.0,
          ),
          itemCount: items.length,
          dragStartDelay: const Duration(milliseconds: 300),
          dragEnabled: Platform.isWindows,
          itemBuilder: (context, index) {
            final item = items[index];
            return _ShortcutTile(
              key: ValueKey(item.id),
              item: item,
              onTap: () => widget.onOpenUrl(item.url),
            );
          },
          onReorder: (oldIndex, newIndex) =>
              _onReorder(items, oldIndex, newIndex),
        ),
        const SizedBox(height: 16),
        // 空位"+"添加（独立于拖拽网格）
        _AddTile(onTap: () => _showAddDialog(context)),
      ],
    );
  }

  /// 拖拽重排：调整顺序并持久化。
  Future<void> _onReorder(
    List<ShortcutItem> items,
    int oldIndex,
    int newIndex,
  ) async {
    // newIndex 为 0..len 时需 -1 对齐（ReorderableGridView 语义）
    if (newIndex > oldIndex) newIndex -= 1;
    final reordered = [...items];
    final moved = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, moved);
    final ids = reordered.map((e) => e.id).toList();
    try {
      await ref.read(shortcutsNotifierProvider.notifier).reorder(ids);
    } catch (_) {
      // 重排失败静默（下次刷新列表恢复原顺序）
    }
  }

  void _showAddDialog(BuildContext context) {
    showShortcutDialog(
      context,
      title: '添加快捷入口',
      onSave: (title, url) async {
        await ref.read(shortcutsNotifierProvider.notifier).add(title, url);
      },
    );
  }
}

/// 单个快捷入口：favicon + 标题。
/// PC 右键（/ iOS 长按）弹出编辑/删除菜单；长按拖拽排序（仅 PC）。
class _ShortcutTile extends ConsumerWidget {
  const _ShortcutTile({super.key, required this.item, required this.onTap});

  final ShortcutItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return GestureDetector(
      onTap: onTap,
      // PC 右键菜单；iOS 长按菜单（iOS 下拖拽禁用，无手势冲突）
      onSecondaryTapUp: (d) => _showActions(context, ref),
      onLongPress: Platform.isIOS ? () => _showActions(context, ref) : null,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // favicon（无 favicon 服务时回退域名首字母）
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colorScheme.outlineVariant),
            ),
            alignment: Alignment.center,
            child: _Favicon(host: item.host, url: item.faviconUrl),
          ),
          const SizedBox(height: 8),
          Text(
            item.title.isEmpty ? item.host : item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  void _showActions(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(LucideIcons.pencil),
              title: const Text('编辑'),
              onTap: () {
                Navigator.pop(sheetContext);
                showShortcutDialog(
                  context,
                  title: '编辑快捷入口',
                  initialTitle: item.title,
                  initialUrl: item.url,
                  onSave: (title, url) async {
                    await ref
                        .read(shortcutsNotifierProvider.notifier)
                        .update(item.id, title: title, url: url);
                  },
                );
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.trash2),
              title: const Text('删除'),
              onTap: () async {
                Navigator.pop(sheetContext);
                final confirmed = await confirmDeleteShortcut(
                  context,
                  name: item.title.isEmpty ? item.host : item.title,
                );
                if (confirmed) {
                  unawaited(
                    ref
                        .read(shortcutsNotifierProvider.notifier)
                        .remove(item.id),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 空位"+"添加按钮。
class _AddTile extends StatelessWidget {
  const _AddTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: colorScheme.outlineVariant,
                style: BorderStyle.solid,
              ),
            ),
            alignment: Alignment.center,
            child: Icon(
              LucideIcons.plus,
              size: 20,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '添加',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// favicon：网络加载，失败回退首字母。
class _Favicon extends StatelessWidget {
  const _Favicon({required this.host, required this.url});

  final String host;
  final String url;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (host.isEmpty) {
      return Icon(
        LucideIcons.globe,
        size: 22,
        color: colorScheme.onSurfaceVariant,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        url,
        width: 28,
        height: 28,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Text(
          host[0].toUpperCase(),
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: colorScheme.primary,
          ),
        ),
      ),
    );
  }
}
