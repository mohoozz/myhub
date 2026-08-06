import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/router/app_router.dart';
import 'package:myhub_flutter/core/theme/app_theme.dart';
import 'package:myhub_flutter/core/theme/theme_mode_provider.dart';
import 'package:myhub_flutter/shared/providers/progress_sync_provider.dart';
import 'package:myhub_flutter/shared/widgets/media_player/mini_player.dart';
import 'package:myhub_flutter/shared/widgets/window_title_bar.dart';

/// Root widget of the myhub app.
class MyhubApp extends ConsumerWidget {
  const MyhubApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    final themeMode = ref.watch(effectiveThemeModeProvider);
    // 激活离线进度同步服务（网络恢复时批量上传未同步进度，F-502）
    ref.watch(progressSyncProvider);
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        // 仅 Android 12+ 使用 Material You 动态取色；其余平台固定白蓝品牌色
        // （Windows 系统强调色会污染主题，例如青绿色按钮）。
        final useDynamic =
            !kIsWeb && Platform.isAndroid && lightDynamic != null;
        return MaterialApp.router(
          title: 'myhub',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(
              dynamicScheme: useDynamic ? lightDynamic : null),
          darkTheme: AppTheme.dark(
              dynamicScheme: useDynamic ? darkDynamic : null),
          themeMode: themeMode,
          routerConfig: router,
          scrollBehavior: const AppScrollBehavior(),
          builder: (context, child) {
            // 沉浸式系统栏：透明状态栏/导航栏，图标明暗跟随主题
            final dark = switch (themeMode) {
              ThemeMode.dark => true,
              ThemeMode.light => false,
              ThemeMode.system =>
                MediaQuery.platformBrightnessOf(context) == Brightness.dark,
            };
            final body = _buildBody(context, child);
            if (isDesktopPlatform) return body;
            return AnnotatedRegion<SystemUiOverlayStyle>(
              value: SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                systemNavigationBarColor: Colors.transparent,
                statusBarIconBrightness:
                    dark ? Brightness.light : Brightness.dark,
                systemNavigationBarIconBrightness:
                    dark ? Brightness.light : Brightness.dark,
                systemStatusBarContrastEnforced: false,
                systemNavigationBarContrastEnforced: false,
              ),
              child: body,
            );
          },
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, Widget? child) {
    if (!isDesktopPlatform) {
      return _withMiniPlayer(context, child);
    }
    // Custom title bar spans the full window width above every page.
    // builder sits above the Navigator, so a Material ancestor has to
    // be provided manually for the title bar's ink / text widgets.
    return Material(
      child: Column(
        children: [
          const WindowTitleBar(),
          Expanded(child: _withMiniPlayer(context, child)),
        ],
      ),
    );
  }
}

/// 平台自适应滚动物理：iOS/macOS 橡皮筋回弹，其余平台默认（Android 拉伸辉光）。
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return switch (getPlatform(context)) {
      TargetPlatform.iOS ||
      TargetPlatform.macOS =>
        const BouncingScrollPhysics(),
      _ => super.getScrollPhysics(context),
    };
  }
}

/// 在页面内容之上叠加迷你播放器（Overlay 宿主）。
///
/// Stack 位于 Navigator 之外：Tab 切换页面存活（IndexedStack），
/// 全屏播放页走独立路由 push，返回后迷你播放器仍在。
/// 窄屏布局下抬升到底部导航栏（NavigationBar 高 80 + 系统安全区）之上。
Widget _withMiniPlayer(BuildContext context, Widget? child) {
  final compact = MediaQuery.sizeOf(context).width < 600;
  final bottom =
      compact ? 80 + MediaQuery.viewPaddingOf(context).bottom : 0.0;
  return Stack(
    children: [
      child ?? const SizedBox.shrink(),
      Positioned(
        left: 0,
        right: 0,
        bottom: bottom,
        child: const MiniPlayer(),
      ),
    ],
  );
}
