import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/features/auth/providers/auth_provider.dart';
import 'package:myhub_flutter/shared/providers/auth_state_provider.dart';
import 'package:myhub_flutter/shared/providers/avatar_provider.dart';
import 'package:myhub_flutter/shared/widgets/avatar_button.dart';

/// 个人主页：展示账户名与头像，点击头像可更换。
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final username = ref.watch(authStateProvider).username ?? '未登录';

    return Scaffold(
      appBar: AppBar(title: const Text('个人中心')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: () => _pickAvatar(context, ref),
              child: Stack(
                children: [
                  const UserAvatar(radius: 56),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: theme.colorScheme.primary,
                        border: Border.all(
                          color: theme.colorScheme.surface,
                          width: 2,
                        ),
                      ),
                      child: Icon(
                        LucideIcons.camera,
                        size: 16,
                        color: theme.colorScheme.onPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Text(username, style: theme.textTheme.titleLarge),
            const SizedBox(height: 32),
            OutlinedButton.icon(
              icon: const Icon(LucideIcons.logOut, size: 16),
              label: const Text('退出登录'),
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
                side: BorderSide(color: theme.colorScheme.error.withValues(alpha: 0.5)),
              ),
              onPressed: () => _confirmLogout(context, ref),
            ),
          ],
        ),
      ),
    );
  }

  /// 确认后退出登录（清除本地 Token，路由守卫自动跳回登录页）。
  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要退出当前账号吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(authProvider).logout();
    }
  }

  Future<void> _pickAvatar(BuildContext context, WidgetRef ref) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      dialogTitle: '选择头像',
    );
    final path = result?.files.single.path;
    if (path == null || !context.mounted) return;
    try {
      await ref.read(avatarProvider.notifier).setAvatar(path);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('头像设置失败，请重试')));
      }
    }
  }
}
