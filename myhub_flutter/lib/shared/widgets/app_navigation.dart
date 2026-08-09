import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/router/app_router.dart';
import 'package:myhub_flutter/core/theme/theme_mode_provider.dart';
import 'package:myhub_flutter/shared/widgets/avatar_button.dart';
import 'package:myhub_flutter/shared/widgets/window_title_bar.dart';

/// Adaptive navigation shell around the [StatefulNavigationShell].
///
/// * `< 600px`: bottom [NavigationBar] with reading / feed / browse.
/// * `>= 600px` (PC first): narrow icon-only side rail — brand mark on
///   top, primary destinations in the middle, settings and the theme
///   toggle pinned to the bottom.
class AppNavigation extends StatelessWidget {
  const AppNavigation({required this.shell, super.key});

  final StatefulNavigationShell shell;

  void _goBranch(int index) {
    shell.goBranch(index, initialLocation: index == shell.currentIndex);
  }

  @override
  Widget build(BuildContext context) {
    Widget child = LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 600) {
          return _CompactShell(shell: shell, onSelect: _goBranch);
        }
        return _RailShell(shell: shell, onSelect: _goBranch);
      },
    );
    // 桌面端全局快捷键：Ctrl+1..5 切换主 Tab
    if (isDesktopPlatform) {
      child = CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.digit1, control: true):
              () => _goBranch(AppBranches.reading),
          const SingleActivator(LogicalKeyboardKey.digit2, control: true):
              () => _goBranch(AppBranches.favorites),
          const SingleActivator(LogicalKeyboardKey.digit3, control: true):
              () => _goBranch(AppBranches.feed),
          const SingleActivator(LogicalKeyboardKey.digit4, control: true):
              () => _goBranch(AppBranches.browse),
          const SingleActivator(LogicalKeyboardKey.digit5, control: true):
              () => _goBranch(AppBranches.settings),
        },
        child: Focus(autofocus: true, child: child),
      );
    }
    return child;
  }
}

/// < 600px: bottom navigation with the three daily-driver pages.
class _CompactShell extends StatelessWidget {
  const _CompactShell({required this.shell, required this.onSelect});

  final StatefulNavigationShell shell;
  final ValueChanged<int> onSelect;

  /// Branches shown in the bottom bar: reading / feed / browse / settings.
  ///
  /// 移动端底部 4 Tab：日常三类页面 + "我的"（设置入口）。
  /// PC 端仍走侧边栏（[_RailShell]），[AppBranches.settings] 在那里以
  /// 设置图标形式挂在底部。
  static const List<int> _visibleBranches = [
    AppBranches.reading,
    AppBranches.feed,
    AppBranches.browse,
    AppBranches.settings,
  ];

  @override
  Widget build(BuildContext context) {
    final selected = _visibleBranches.contains(shell.currentIndex)
        ? _visibleBranches.indexOf(shell.currentIndex)
        : 0;
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      // 移动端不再显示 AppBar：右上角头像已下沉到"我的"Tab 头部，
      // 避免顶栏占位造成阅读区上方留白。
      body: SafeArea(child: shell),
      bottomNavigationBar: Material(
        // 顶部 1px 分隔线，把菜单栏和内容区"切开"，
        // 避免和上面的浅色背景融为一体。
        color: colorScheme.surface,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Divider(
              height: 1,
              thickness: 1,
              color: colorScheme.outline,
            ),
            NavigationBarTheme(
              // 1. 选中态图标/文字统一用品牌蓝（亮/暗主题都用 colorScheme.primary）
              // 2. indicator 透明 + 关闭 overlay，去掉点击时的矩形高亮和选中胶囊
              // 3. labelBehavior=alwaysHide：不显示任何文字，避免选中项"被弹起"的视觉跳跃
              data: NavigationBarThemeData(
                backgroundColor: colorScheme.surface,
                surfaceTintColor: Colors.transparent,
                indicatorColor: Colors.transparent,
                indicatorShape: const RoundedRectangleBorder(),
                overlayColor: WidgetStateProperty.all(Colors.transparent),
                labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
                iconTheme: WidgetStateProperty.resolveWith((states) {
                  final selected = states.contains(WidgetState.selected);
                  return IconThemeData(
                    color: selected
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                    size: 22,
                  );
                }),
              ),
              child: NavigationBar(
                // 整体高度比默认 80 略小：紧凑布局，避免底部留白过多。
                height: 52,
                elevation: 0,
                selectedIndex: selected,
                onDestinationSelected: (index) =>
                    onSelect(_visibleBranches[index]),
                destinations: const [
                  NavigationDestination(
                    icon: Icon(LucideIcons.house),
                    selectedIcon: Icon(LucideIcons.house),
                    label: '阅读',
                  ),
                  NavigationDestination(
                    icon: Icon(LucideIcons.zap),
                    selectedIcon: Icon(LucideIcons.zap),
                    label: '动态',
                  ),
                  NavigationDestination(
                    icon: Icon(LucideIcons.folder),
                    selectedIcon: Icon(LucideIcons.folder),
                    label: '浏览',
                  ),
                  NavigationDestination(
                    icon: Icon(LucideIcons.userRound),
                    selectedIcon: Icon(LucideIcons.userRound),
                    label: '我的',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// >= 600px: narrow icon rail matching the desktop-first design spec.
class _RailShell extends ConsumerWidget {
  const _RailShell({required this.shell, required this.onSelect});

  final StatefulNavigationShell shell;
  final ValueChanged<int> onSelect;

  static const double _railWidth = 68;

  /// Primary destinations, in rail order.
  static const List<({int branch, IconData icon, String label})> _items = [
    (branch: AppBranches.reading, icon: LucideIcons.house, label: '阅读'),
    (branch: AppBranches.favorites, icon: LucideIcons.star, label: '收藏'),
    (branch: AppBranches.feed, icon: LucideIcons.zap, label: '动态'),
    (branch: AppBranches.browse, icon: LucideIcons.folder, label: '浏览'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      body: Row(
        children: [
          Container(
            width: _railWidth,
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerLowest,
              border: Border(
                right: BorderSide(color: colorScheme.outline),
              ),
            ),
            child: Column(
              children: [
                const SizedBox(height: 16),
                const AvatarButton(),
                const SizedBox(height: 20),
                for (final item in _items) ...[
                  _RailItem(
                    icon: item.icon,
                    label: item.label,
                    selected: shell.currentIndex == item.branch,
                    onTap: () => onSelect(item.branch),
                  ),
                  const SizedBox(height: 10),
                ],
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Divider(
                    height: 1,
                    color: colorScheme.outline.withValues(alpha: 0.5),
                  ),
                ),
                const SizedBox(height: 10),
                _RailItem(
                  icon: LucideIcons.settings,
                  label: '设置',
                  selected: shell.currentIndex == AppBranches.settings,
                  onTap: () => onSelect(AppBranches.settings),
                ),
                const SizedBox(height: 10),
                _RailItem(
                  icon: isDark ? LucideIcons.sun : LucideIcons.moon,
                  label: isDark ? '切换到浅色' : '切换到深色',
                  selected: false,
                  onTap: () => ref
                      .read(themeModeProvider.notifier)
                      .toggle(isDark ? Brightness.dark : Brightness.light),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
          // SafeArea：iOS 横屏刘海/Dynamic Island 保护（桌面端为 no-op）
          Expanded(child: SafeArea(child: shell)),
        ],
      ),
    );
  }
}

/// A single icon-only entry of the side rail.
class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final foreground =
        selected ? colorScheme.primary : colorScheme.onSurfaceVariant;
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: selected
                ? colorScheme.primary.withValues(alpha: 0.1)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, size: 20, color: foreground),
        ),
      ),
    );
  }
}
