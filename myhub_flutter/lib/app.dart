import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/router/app_router.dart';
import 'package:myhub_flutter/core/theme/app_theme.dart';
import 'package:myhub_flutter/core/theme/theme_mode_provider.dart';
import 'package:myhub_flutter/shared/widgets/mini_player_overlay.dart';
import 'package:myhub_flutter/shared/widgets/window_title_bar.dart';

/// Root widget of the myhub app.
class MyhubApp extends ConsumerWidget {
  const MyhubApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    final themeMode = ref.watch(effectiveThemeModeProvider);
    return MaterialApp.router(
      title: 'myhub',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      routerConfig: router,
      builder: (context, child) {
        if (!isDesktopPlatform) {
          return _withMiniPlayer(child);
        }
        // Custom title bar spans the full window width above every page.
        // builder sits above the Navigator, so a Material ancestor has to
        // be provided manually for the title bar's ink / text widgets.
        return Material(
          child: Column(
            children: [
              const WindowTitleBar(),
              Expanded(child: _withMiniPlayer(child)),
            ],
          ),
        );
      },
    );
  }
}

/// 在页面内容之上叠加迷你播放器（Overlay 宿主）。
///
/// Stack 位于 Navigator 之外：Tab 切换页面存活（IndexedStack），
/// 全屏播放页走独立路由 push，返回后迷你播放器仍在。
Widget _withMiniPlayer(Widget? child) {
  return Stack(
    children: [
      child ?? const SizedBox.shrink(),
      const Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: MiniPlayerOverlay(),
      ),
    ],
  );
}
