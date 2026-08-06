import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/shared/providers/auth_headers_provider.dart';
import 'package:myhub_flutter/shared/providers/avatar_provider.dart';

/// 头像按钮（导航壳右上角/侧边栏顶部）。
///
/// 点击直接进入个人主页 `/profile`；显示用户在个人主页设置的头像，
/// 未设置时回退为默认人物图标。
class AvatarButton extends ConsumerWidget {
  const AvatarButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Tooltip(
      message: '个人中心',
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: () => context.push('/profile'),
        customBorder: const CircleBorder(),
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
          child: const UserAvatar(radius: 19),
        ),
      ),
    );
  }
}

/// 当前用户头像（导航按钮与个人主页共用）。
///
/// 已设置头像时经 `CachedNetworkImage` 加载服务端图片（带 JWT 请求头），
/// 加载中/失败/未设置均回退为默认人物图标。
class UserAvatar extends ConsumerWidget {
  const UserAvatar({required this.radius, super.key});

  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final url = ref.watch(avatarProvider);
    final headers = ref.watch(authHeadersProvider).valueOrNull;

    final fallback = CircleAvatar(
      radius: radius,
      backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.1),
      child: Icon(
        LucideIcons.userRound,
        size: radius,
        color: theme.colorScheme.primary,
      ),
    );
    if (url == null || headers == null) return fallback;

    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: url,
        httpHeaders: headers,
        width: radius * 2,
        height: radius * 2,
        fit: BoxFit.cover,
        fadeInDuration: const Duration(milliseconds: 150),
        placeholder: (_, _) => fallback,
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }
}
