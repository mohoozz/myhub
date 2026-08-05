import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/router/app_router.dart';
import 'package:myhub_flutter/core/theme/theme_mode_provider.dart';
import 'package:myhub_flutter/shared/widgets/avatar_menu.dart';

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
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 600) {
          return _CompactShell(shell: shell, onSelect: _goBranch);
        }
        return _RailShell(shell: shell, onSelect: _goBranch);
      },
    );
  }
}

/// < 600px: bottom navigation with the three daily-driver pages.
class _CompactShell extends StatelessWidget {
  const _CompactShell({required this.shell, required this.onSelect});

  final StatefulNavigationShell shell;
  final ValueChanged<int> onSelect;

  /// Branches shown in the bottom bar: reading / feed / browse.
  static const List<int> _visibleBranches = [
    AppBranches.reading,
    AppBranches.feed,
    AppBranches.browse,
  ];

  @override
  Widget build(BuildContext context) {
    final selected = _visibleBranches.contains(shell.currentIndex)
        ? _visibleBranches.indexOf(shell.currentIndex)
        : 0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('myhub'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(child: AvatarMenuButton(onGoBranch: onSelect)),
          ),
        ],
      ),
      body: shell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: selected,
        onDestinationSelected: (index) => onSelect(_visibleBranches[index]),
        destinations: const [
          NavigationDestination(
            icon: Icon(LucideIcons.house),
            label: '阅读',
          ),
          NavigationDestination(
            icon: Icon(LucideIcons.zap),
            label: '动态',
          ),
          NavigationDestination(
            icon: Icon(LucideIcons.folder),
            label: '浏览',
          ),
        ],
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
                AvatarMenuButton(onGoBranch: onSelect),
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
          Expanded(child: shell),
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
