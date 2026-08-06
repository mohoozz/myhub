import 'dart:async';

import 'package:flutter/material.dart';

OverlayEntry? _currentEntry;

/// 在屏幕顶部显示浮动提示（替代默认的底部 SnackBar）。
///
/// 样式跟随主题（卡片底色 + 圆角 + 柔和阴影），宽度随内容自适应（居中胶囊）；
/// 动画为自上而下滑入 + 淡入，约 2.5 秒后淡出消失。
void showTopSnackBar(BuildContext context, String message) {
  final overlay = Overlay.of(context);
  // 替换旧提示：直接移除（不做退场动画），避免多条堆积
  _currentEntry?.remove();
  _currentEntry = null;

  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => _TopToast(
      message: message,
      onDismissed: () {
        if (_currentEntry == entry) _currentEntry = null;
        entry.remove();
      },
    ),
  );
  _currentEntry = entry;
  overlay.insert(entry);
}

class _TopToast extends StatefulWidget {
  const _TopToast({required this.message, required this.onDismissed});

  final String message;
  final VoidCallback onDismissed;

  @override
  State<_TopToast> createState() => _TopToastState();
}

class _TopToastState extends State<_TopToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slide;
  late final Animation<double> _fade;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      reverseDuration: const Duration(milliseconds: 200),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, -0.6),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _controller.forward();
    _timer = Timer(const Duration(milliseconds: 2500), _dismiss);
  }

  Future<void> _dismiss() async {
    if (!mounted) return;
    try {
      await _controller.reverse();
    } on TickerCanceled {
      return; // 被新提示替换，entry 已移除
    }
    if (mounted) widget.onDismissed();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Positioned(
      top: 56,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: SlideTransition(
          position: _slide,
          child: FadeTransition(
            opacity: _fade,
            child: Center(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 480),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: theme.dividerColor),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Text(
                  widget.message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
