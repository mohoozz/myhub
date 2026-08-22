import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 动态单条垂直分页浏览容器。
///
/// * PageView 垂直滑动翻页（移动端手势）；
/// * 上/下方向键、PageUp/PageDown 翻页（PC 键盘）；
/// * 滚轮翻页（累计滚动量过阈值翻一页，兼容高精度触控板）；
/// * 右下角悬浮「上一条 / 下一条」按钮 + 进度指示。
class FeedPagedViewer extends StatefulWidget {
  const FeedPagedViewer({
    super.key,
    required this.itemCount,
    required this.initialIndex,
    required this.itemBuilder,
    required this.onIndexChanged,
    required this.onReachEnd,
  });

  final int itemCount;
  final int initialIndex;
  final IndexedWidgetBuilder itemBuilder;

  /// 翻页回调（当前下标，0 起）。
  final ValueChanged<int> onIndexChanged;

  /// 接近末尾时回调（用于触底加载更多）。
  final VoidCallback onReachEnd;

  @override
  State<FeedPagedViewer> createState() => _FeedPagedViewerState();
}

class _FeedPagedViewerState extends State<FeedPagedViewer> {
  static const double _wheelThreshold = 24;

  late final PageController _controller;
  int _index = 0;
  double _wheelAccum = 0;

  int get _count => widget.itemCount;

  int _clampIndex(int index) =>
      _count <= 0 ? 0 : index.clamp(0, _count - 1);

  @override
  void initState() {
    super.initState();
    _index = _clampIndex(widget.initialIndex);
    _controller = PageController(initialPage: _index);
  }

  @override
  void didUpdateWidget(covariant FeedPagedViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 刷新后恢复阅读进度：initialIndex 变化则跳转到对应页。
    if (widget.initialIndex != oldWidget.initialIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_controller.hasClients) return;
        final target = _clampIndex(widget.initialIndex);
        if (target != _index) {
          setState(() => _index = target);
          _controller.jumpToPage(target);
        }
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _flip(int delta) {
    if (!_controller.hasClients) return;
    final target = _clampIndex(_index + delta);
    if (target == _index) return;
    _controller.animateToPage(
      target,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  void _next() => _flip(1);

  void _prev() => _flip(-1);

  Map<ShortcutActivator, VoidCallback> get _shortcuts => {
        const SingleActivator(LogicalKeyboardKey.arrowDown): _next,
        const SingleActivator(LogicalKeyboardKey.arrowUp): _prev,
        const SingleActivator(LogicalKeyboardKey.pageDown): _next,
        const SingleActivator(LogicalKeyboardKey.pageUp): _prev,
      };

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    // 先注册即胜出，阻止 PageView 像素级滚动。
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      _wheelAccum += event.scrollDelta.dy;
      if (_wheelAccum.abs() >= _wheelThreshold) {
        _flip(_wheelAccum > 0 ? 1 : -1);
        _wheelAccum = 0;
      }
    });
  }

  void _onPageChanged(int index) {
    setState(() => _index = index);
    widget.onIndexChanged(index);
    if (index >= _count - 3) widget.onReachEnd();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return CallbackShortcuts(
      bindings: _shortcuts,
      child: Focus(
        autofocus: true,
        child: Stack(
          children: [
            PageView.builder(
              controller: _controller,
              scrollDirection: Axis.vertical,
              itemCount: _count,
              onPageChanged: _onPageChanged,
              itemBuilder: (context, index) => Listener(
                onPointerSignal: _onPointerSignal,
                child: widget.itemBuilder(context, index),
              ),
            ),
            if (_count > 1) _buildControls(theme, colorScheme),
          ],
        ),
      ),
    );
  }

  Widget _buildControls(ThemeData theme, ColorScheme colorScheme) {
    return Positioned(
      right: 16,
      bottom: 24,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${_index + 1} / $_count',
            style: theme.textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          _NavButton(
            icon: LucideIcons.chevronUp,
            tooltip: '上一条',
            enabled: _index > 0,
            onPressed: _prev,
          ),
          const SizedBox(height: 8),
          _NavButton(
            icon: LucideIcons.chevronDown,
            tooltip: '下一条',
            enabled: _index < _count - 1,
            onPressed: _next,
          ),
        ],
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surface.withValues(alpha: 0.92),
      shape: const CircleBorder(),
      elevation: 2,
      child: IconButton(
        icon: Icon(icon, size: 20),
        tooltip: tooltip,
        onPressed: enabled ? onPressed : null,
        disabledColor: colorScheme.onSurface.withValues(alpha: 0.3),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
