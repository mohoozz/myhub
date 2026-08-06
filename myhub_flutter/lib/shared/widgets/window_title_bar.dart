import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:window_manager/window_manager.dart';

/// Whether the current platform uses a custom in-app title bar.
bool get isDesktopPlatform =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

/// 沉浸式页面（如全屏播放器）打开时置为 true，标题栏随之切换为纯黑背景。
final immersiveTitleBarProvider = StateProvider<bool>((ref) => false);

/// Custom title bar replacing the native one on desktop builds.
///
/// The empty area is a [DragToMoveArea] (drag to move, double-click to
/// maximize / restore); minimize / maximize / close buttons sit on the
/// right, styled after the rest of the app.
class WindowTitleBar extends ConsumerWidget {
  const WindowTitleBar({super.key});

  static const double height = 40;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final immersive = ref.watch(immersiveTitleBarProvider);
    final colorScheme = Theme.of(context).colorScheme;
    // 沉浸式（播放器）时纯黑背景 + 浅色按钮，与播放页黑色融为一体
    final foreground =
        immersive ? Colors.white70 : colorScheme.onSurfaceVariant;
    final hoverColor = immersive
        ? Colors.white.withValues(alpha: 0.12)
        : colorScheme.onSurface.withValues(alpha: 0.06);
    return Container(
      height: height,
      color: immersive ? Colors.black : colorScheme.surface,
      child: Row(
        children: [
          const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
          _WindowButton(
            icon: LucideIcons.minus,
            onPressed: windowManager.minimize,
            foreground: foreground,
            hoverColor: hoverColor,
          ),
          _WindowButton(
            icon: LucideIcons.square,
            onPressed: () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
            foreground: foreground,
            hoverColor: hoverColor,
          ),
          _WindowButton(
            icon: LucideIcons.x,
            isClose: true,
            onPressed: windowManager.close,
            foreground: foreground,
            hoverColor: hoverColor,
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

class _WindowButton extends StatelessWidget {
  const _WindowButton({
    required this.icon,
    required this.onPressed,
    required this.foreground,
    required this.hoverColor,
    this.isClose = false,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final Color foreground;
  final Color hoverColor;

  /// Close buttons turn red on hover, following the OS convention.
  final bool isClose;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, size: 15),
      color: foreground,
      hoverColor: isClose ? const Color(0xFFE81123) : hoverColor,
      style: IconButton.styleFrom(
        shape: const RoundedRectangleBorder(),
        minimumSize: const Size(46, WindowTitleBar.height),
        maximumSize: const Size(46, WindowTitleBar.height),
      ).copyWith(
        foregroundColor: isClose
            ? WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.hovered)
                    ? Colors.white
                    : foreground,
              )
            : null,
      ),
    );
  }
}
