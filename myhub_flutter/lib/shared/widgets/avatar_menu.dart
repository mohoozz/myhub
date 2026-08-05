import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/router/app_router.dart';
import 'package:myhub_flutter/core/theme/theme_mode_provider.dart';
import 'package:myhub_flutter/shared/providers/auth_state_provider.dart';

/// 头像菜单按钮（导航壳右上角/侧边栏顶部）。
///
/// 菜单项：个人中心、我的收藏、设置、深色模式开关、退出登录。
/// 退出登录清除 Token 后由路由守卫自动跳回登录页。
class AvatarMenuButton extends ConsumerWidget {
  const AvatarMenuButton({required this.onGoBranch, super.key});

  /// 跳转导航壳内分支（收藏/设置）。
  final ValueChanged<int> onGoBranch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final username =
        ref.watch(authStateProvider).username ?? '未登录';

    return PopupMenuButton<String>(
      tooltip: '个人中心',
      position: PopupMenuPosition.under,
      onSelected: (value) => _onSelected(context, ref, value, isDark),
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          enabled: false,
          child: Text(
            username,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: 'profile',
          child: _MenuRow(icon: LucideIcons.userRound, label: '个人中心'),
        ),
        const PopupMenuItem<String>(
          value: 'favorites',
          child: _MenuRow(icon: LucideIcons.star, label: '我的收藏'),
        ),
        const PopupMenuItem<String>(
          value: 'settings',
          child: _MenuRow(icon: LucideIcons.settings, label: '设置'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'theme',
          child: Row(
            children: [
              Icon(
                isDark ? LucideIcons.sun : LucideIcons.moon,
                size: 18,
                color: theme.colorScheme.onSurface,
              ),
              const SizedBox(width: 10),
              const Expanded(child: Text('深色模式')),
              Switch(
                value: isDark,
                onChanged: (_) => _toggleTheme(ref, isDark),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'logout',
          child: _MenuRow(
            icon: LucideIcons.logOut,
            label: '退出登录',
            color: theme.colorScheme.error,
          ),
        ),
      ],
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.35),
            width: 1.5,
          ),
        ),
        child: CircleAvatar(
          radius: 19,
          backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.1),
          child: Icon(
            LucideIcons.userRound,
            size: 20,
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }

  void _onSelected(
    BuildContext context,
    WidgetRef ref,
    String value,
    bool isDark,
  ) {
    switch (value) {
      case 'profile':
        context.push('/profile');
      case 'favorites':
        onGoBranch(AppBranches.favorites);
      case 'settings':
        onGoBranch(AppBranches.settings);
      case 'theme':
        _toggleTheme(ref, isDark);
      case 'logout':
        _logout(context, ref);
    }
  }

  void _toggleTheme(WidgetRef ref, bool isDark) {
    ref
        .read(themeModeProvider.notifier)
        .toggle(isDark ? Brightness.dark : Brightness.light);
  }

  Future<void> _logout(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要退出当前账号吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ref.read(authStateProvider.notifier).markLoggedOut();
      // 路由守卫监听到状态变化后自动重定向 /login
    }
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label, this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final foreground = color ?? Theme.of(context).colorScheme.onSurface;
    return Row(
      children: [
        Icon(icon, size: 18, color: foreground),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: foreground)),
      ],
    );
  }
}
