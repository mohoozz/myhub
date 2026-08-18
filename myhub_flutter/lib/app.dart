import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/router/app_router.dart';
import 'package:myhub_flutter/core/settings/server_config_provider.dart';
import 'package:myhub_flutter/core/theme/app_theme.dart';
import 'package:myhub_flutter/core/theme/theme_mode_provider.dart';
import 'package:myhub_flutter/shared/providers/progress_sync_provider.dart';
import 'package:myhub_flutter/shared/widgets/boot_splash.dart';
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
            // 启动探测（bootProvider）完成前显示引导页，避免主界面在
            // 内网/外网未定时用错误地址发请求；探测失败也放行（已退回外网）。
            final boot = ref.watch(bootProvider);
            final booted = boot.hasValue || boot.hasError;
            final body =
                booted ? _buildBody(context, child) : const BootSplash();
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
///
/// 桌面/Web 平台同时重写滚动条样式：持续显示明显 thumb（thickness 8、
/// radius 4），避免默认的细线 thumb 在内容上显得突兀；移动端走默认行为
/// （hover/touch 时显示），不打扰触摸阅读。
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

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    if (kIsWeb || isDesktopPlatform) {
      // 桌面/Web 显式声明：持续 thumb、圆角、明显厚度，hover 仍可拖动。
      return Scrollbar(
        controller: details.controller,
        thumbVisibility: true,
        thickness: 8,
        radius: const Radius.circular(4),
        interactive: true,
        child: child,
      );
    }
    return super.buildScrollbar(context, child, details);
  }
}

/// 在页面内容之上叠加迷你播放器（Overlay 宿主）。
///
/// * 桌面端（>=600px）：Stack 浮于内容底部，侧边栏旁的悬浮 mini；
/// * 移动端（<600px）：mini 由 [_CompactShell] 嵌入 Scaffold.bottomNavigationBar
///   内与导航栏一体呈现，Stack 仅作为内容宿主（不挂 mini）。
///   移动端无需在此抬升 bottom，因为底部导航栏已自带位置，mini 与 nav 同处
///   一个容器内视觉贴合。
Widget _withMiniPlayer(BuildContext context, Widget? child) {
  final compact = MediaQuery.sizeOf(context).width < 600;
  if (compact) {
    // 移动端：mini 在 shell 内部与底部导航栏一体组装；此处仅返回 child。
    return child ?? const SizedBox.shrink();
  }
  // 桌面端：悬浮 mini（保持与原有"灵动岛"风格兼容）
  return Stack(
    children: [
      child ?? const SizedBox.shrink(),
      const Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: MiniPlayer(),
      ),
    ],
  );
}
