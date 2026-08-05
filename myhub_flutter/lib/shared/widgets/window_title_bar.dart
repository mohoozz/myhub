import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:window_manager/window_manager.dart';

/// Whether the current platform uses a custom in-app title bar.
bool get isDesktopPlatform =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

/// Custom title bar replacing the native one on desktop builds.
///
/// The empty area is a [DragToMoveArea] (drag to move, double-click to
/// maximize / restore); minimize / maximize / close buttons sit on the
/// right, styled after the rest of the app.
class WindowTitleBar extends StatelessWidget {
  const WindowTitleBar({super.key});

  static const double height = 40;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      height: height,
      color: colorScheme.surface,
      child: Row(
        children: [
          const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
          _WindowButton(
            icon: LucideIcons.minus,
            onPressed: windowManager.minimize,
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
          ),
          _WindowButton(
            icon: LucideIcons.x,
            isClose: true,
            onPressed: windowManager.close,
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
    this.isClose = false,
  });

  final IconData icon;
  final VoidCallback onPressed;

  /// Close buttons turn red on hover, following the OS convention.
  final bool isClose;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, size: 15),
      color: colorScheme.onSurfaceVariant,
      hoverColor: isClose
          ? const Color(0xFFE81123)
          : colorScheme.onSurface.withValues(alpha: 0.06),
      style: IconButton.styleFrom(
        shape: const RoundedRectangleBorder(),
        minimumSize: const Size(46, WindowTitleBar.height),
        maximumSize: const Size(46, WindowTitleBar.height),
      ).copyWith(
        foregroundColor: isClose
            ? WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.hovered)
                    ? Colors.white
                    : colorScheme.onSurfaceVariant,
              )
            : null,
      ),
    );
  }
}
