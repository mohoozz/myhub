import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:myhub_flutter/core/utils/browser_support.dart';
import 'package:myhub_flutter/features/auth/login_screen.dart';
import 'package:myhub_flutter/features/browse/browse_screen.dart';
import 'package:myhub_flutter/features/browser/browser_screen.dart';
import 'package:myhub_flutter/features/favorites/favorites_screen.dart';
import 'package:myhub_flutter/features/feed/feed_screen.dart';
import 'package:myhub_flutter/features/profile/profile_screen.dart';
import 'package:myhub_flutter/features/reading/reading_screen.dart';
import 'package:myhub_flutter/features/settings/settings_screen.dart';
import 'package:myhub_flutter/features/trash/trash_screen.dart';
import 'package:myhub_flutter/shared/providers/auth_state_provider.dart';
import 'package:myhub_flutter/shared/widgets/app_navigation.dart';

/// Branch indexes of the [StatefulShellRoute] (order matters).
abstract final class AppBranches {
  static const int reading = 0;
  static const int favorites = 1;
  static const int feed = 2;
  static const int browse = 3;
  static const int browser = 4;
  static const int settings = 5;
}

/// App-wide [GoRouter]; the indexed-stack shell keeps pages alive.
///
/// 路由守卫：
/// * 未登录访问任意页面 → 重定向 `/login`（`from` 参数记住目标，登录后回跳）；
/// * 已登录访问 `/login` → 重定向回 `from` 或 `/reading`；
/// * 认证状态恢复中（unknown）→ 暂留当前位置，恢复后自动重评估。
///
/// 深层链接由 go_router 原生支持，`from` 回跳保证守卫不打断直达链接。
final appRouterProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    initialLocation: '/login',
    redirect: (context, state) {
      final auth = ref.read(authStateProvider);
      final atLogin = state.matchedLocation == '/login';

      switch (auth.status) {
        case AuthStatus.unknown:
          // 状态恢复中：登录页直接展示，其他页先去登录页等待恢复
          return atLogin ? null : _toLogin(state);
        case AuthStatus.unauthenticated:
          return atLogin ? null : _toLogin(state);
        case AuthStatus.authenticated:
          // 浏览器页签平台降级：WebView 不可用平台（非 Windows / iOS）
          // 深层链接进入 /browser 时回退到浏览页
          if (!browserSupported &&
              state.matchedLocation.startsWith('/browser')) {
            return '/browse';
          }
          if (atLogin) {
            final from = state.uri.queryParameters['from'];
            return (from != null && from.startsWith('/'))
                ? from
                : '/reading';
          }
          return null;
      }
    },
    routes: [
      GoRoute(
        path: '/login',
        name: 'login',
        builder: (context, state) => const LoginScreen(),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            AppNavigation(shell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/reading',
                name: 'reading',
                builder: (context, state) => const ReadingScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/favorites',
                name: 'favorites',
                builder: (context, state) => const FavoritesScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/feed',
                name: 'feed',
                builder: (context, state) => const FeedScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/browse',
                name: 'browse',
                builder: (context, state) => const BrowseScreen(),
              ),
            ],
          ),
          // 内置浏览器（仅 PC（Windows）/ iOS 平台显示入口，其余平台
          // 由路由降级回 /browse）
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/browser',
                name: 'browser',
                builder: (context, state) => const BrowserScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                name: 'settings',
                builder: (context, state) => const SettingsScreen(),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/trash',
        name: 'trash',
        builder: (context, state) => const TrashScreen(),
      ),
      GoRoute(
        path: '/profile',
        name: 'profile',
        builder: (context, state) => const ProfileScreen(),
      ),
    ],
  );

  // 认证状态变化（启动恢复 / 登录 / 登出）时重评估路由守卫
  ref.listen(authStateProvider, (previous, next) {
    if (previous?.status != next.status) {
      router.refresh();
    }
  });
  ref.onDispose(router.dispose);

  return router;
});

/// 构造跳转登录页的地址，`from` 参数记住原始目标供登录后回跳。
String? _toLogin(GoRouterState state) {
  final from = state.uri.toString();
  if (from == '/' || from == '/login') {
    return '/login';
  }
  return '/login?from=${Uri.encodeComponent(from)}';
}
