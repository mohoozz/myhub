import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 单页/双页共用的分页浏览容器。
///
/// * PageView 左右滑动翻页（双页模式经 [reverse] 适配日漫 rtl）；
/// * 整页 InteractiveViewer 缩放（双指捏合）；未缩放时拖拽归 PageView
///   翻页，缩放后禁用翻页避免误触，翻页时自动还原缩放；
/// * 桌面/键鼠交互：
///   - 点击左/右 1/4 区域翻页（rtl 时前后映射反转），中部切换控制栏；
///   - 方向键 / PageUp / PageDown / 空格翻页；
///   - 滚轮翻页（累计滚动量过阈值翻一页，兼容高精度触控板小步长）；
///   - Ctrl/⌘ + 滚轮以光标为焦点双向缩放（InteractiveViewer 内置滚轮
///     缩放经 scaleFactor=∞ 屏蔽）。
class ComicPagedViewer extends StatefulWidget {
  const ComicPagedViewer({
    super.key,
    required this.itemCount,
    required this.initialIndex,
    required this.itemBuilder,
    required this.onIndexChanged,
    required this.onToggleChrome,
    this.reverse = false,
    this.rtl = false,
    this.jumpTo,
    this.indexOfPage,
  });

  /// PageView 项目数（单页=页数，双页=双页组数）。
  final int itemCount;

  /// 起始项目下标（0 起）。
  final int initialIndex;

  /// 单个项目（一页 / 一个双页组）的构建器。
  final IndexedWidgetBuilder itemBuilder;

  /// 翻页回调（当前下标，0 起）。
  final ValueChanged<int> onIndexChanged;

  /// 点击画面中部回调（切换顶/底栏显隐）。
  final VoidCallback onToggleChrome;

  /// PageView reverse（日漫：从右向左翻页）。
  final bool reverse;

  /// 从右向左阅读：点击分区与左右方向键的前后映射反转。
  final bool rtl;

  /// 页码跳转通知（值为页码，0 起；负值表示无跳转），用于进度条拖动。
  final ValueListenable<int>? jumpTo;

  /// 页码 → 项目下标换算（双页模式 page ~/ 2）；null 时恒等。
  final int Function(int page)? indexOfPage;

  @override
  State<ComicPagedViewer> createState() => _ComicPagedViewerState();
}

class _ComicPagedViewerState extends State<ComicPagedViewer> {
  static const double _maxScale = 5;

  /// 滚轮翻页触发阈值（鼠标一格 delta≈20，略高避免一格翻多页）。
  static const double _wheelThreshold = 24;

  late final PageController _controller;
  final TransformationController _zoom = TransformationController();

  bool _zoomed = false;
  double _wheelAccum = 0;

  @override
  void initState() {
    super.initState();
    _controller = PageController(initialPage: widget.initialIndex);
    _zoom.addListener(_onZoomChanged);
    widget.jumpTo?.addListener(_onJumpTo);
  }

  @override
  void dispose() {
    widget.jumpTo?.removeListener(_onJumpTo);
    _zoom.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// 进度条拖动跳转：立即定位（无动画，快速加载目标页）。
  void _onJumpTo() {
    final page = widget.jumpTo?.value ?? -1;
    if (page < 0 || !_controller.hasClients) return;
    final index = (widget.indexOfPage?.call(page) ?? page)
        .clamp(0, widget.itemCount - 1);
    if (index == _index) return;
    _resetZoom();
    _controller.jumpToPage(index);
  }

  void _onZoomChanged() {
    final zoomed = _zoom.value.getMaxScaleOnAxis() > 1.001;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  int get _index {
    if (_controller.hasClients && _controller.page != null) {
      return _controller.page!.round();
    }
    return widget.initialIndex;
  }

  void _resetZoom() {
    if (_zoomed) _zoom.value = Matrix4.identity();
  }

  /// 翻 [delta] 项（+1 下一页/组，-1 上一页/组），翻页时还原缩放。
  void _flip(int delta) {
    if (!_controller.hasClients) return;
    final target = (_index + delta).clamp(0, widget.itemCount - 1);
    if (target == _index) return;
    _resetZoom();
    _controller.animateToPage(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _next() => _flip(1);

  void _prev() => _flip(-1);

  // ---------- 点击分区 ----------

  void _onTapUp(TapUpDetails details) {
    final width = context.size?.width ?? 0;
    if (width <= 0) return widget.onToggleChrome();
    final fraction = details.localPosition.dx / width;
    if (fraction < 0.25) {
      widget.rtl ? _next() : _prev();
    } else if (fraction > 0.75) {
      widget.rtl ? _prev() : _next();
    } else {
      widget.onToggleChrome();
    }
  }

  // ---------- 键盘 ----------

  Map<ShortcutActivator, VoidCallback> get _shortcuts => {
        const SingleActivator(LogicalKeyboardKey.arrowRight):
            widget.rtl ? _prev : _next,
        const SingleActivator(LogicalKeyboardKey.arrowLeft):
            widget.rtl ? _next : _prev,
        const SingleActivator(LogicalKeyboardKey.arrowDown): _next,
        const SingleActivator(LogicalKeyboardKey.arrowUp): _prev,
        const SingleActivator(LogicalKeyboardKey.pageDown): _next,
        const SingleActivator(LogicalKeyboardKey.pageUp): _prev,
        const SingleActivator(LogicalKeyboardKey.space): _next,
      };

  // ---------- 滚轮 ----------

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    // 本 Listener 位于 PageView 内部 Scrollable 的下层，向
    // PointerSignalResolver 先注册即胜出，阻止 PageView 像素级滚动
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final ctrl = HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isMetaPressed;
      if (ctrl) {
        _zoomAt(event.localPosition, math.exp(-event.scrollDelta.dy / 200));
        return;
      }
      // 已缩放时触控板双指滚动留给 InteractiveViewer 平移浏览；
      // 鼠标滚轮仍然翻页（翻页会还原缩放）
      if (_zoomed && event.kind == PointerDeviceKind.trackpad) return;
      _wheelAccum += event.scrollDelta.dy;
      if (_wheelAccum.abs() >= _wheelThreshold) {
        _flip(_wheelAccum > 0 ? 1 : -1);
        _wheelAccum = 0;
      }
    });
  }

  /// 以 [focalPoint]（视口坐标）为焦点缩放，算法与 InteractiveViewer
  /// 一致：先缩放再平移，保持焦点下的内容点不动。
  void _zoomAt(Offset focalPoint, double scaleChange) {
    final current = _zoom.value.getMaxScaleOnAxis();
    final next = (current * scaleChange).clamp(1.0, _maxScale);
    if ((next - current).abs() < 1e-6) return;
    if (next <= 1.0) {
      _resetZoom();
      return;
    }
    final change = next / current;
    final focalScene = _zoom.toScene(focalPoint);
    _zoom.value = _zoom.value.clone()..scaleByDouble(change, change, change, 1.0);
    final focalSceneScaled = _zoom.toScene(focalPoint);
    final offset = focalSceneScaled - focalScene;
    _zoom.value = _zoom.value.clone()
      ..translateByDouble(offset.dx, offset.dy, 0.0, 1.0);
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: _shortcuts,
      child: Focus(
        autofocus: true,
        child: GestureDetector(
          onTapUp: _onTapUp,
          child: InteractiveViewer(
            transformationController: _zoom,
            // 屏蔽内置滚轮缩放（scaleChange=exp(-dy/∞)=1），滚轮交由
            // 上方自定义逻辑处理；双指捏合/触控板捏合不受影响
            scaleFactor: double.infinity,
            maxScale: _maxScale,
            // 未缩放时横向拖拽交给 PageView 翻页，缩放后才由
            // InteractiveViewer 平移浏览
            panEnabled: _zoomed,
            child: PageView.builder(
              controller: _controller,
              reverse: widget.reverse,
              // 缩放时禁用滑动翻页，避免缩放状态下误翻页
              physics: _zoomed
                  ? const NeverScrollableScrollPhysics()
                  : const PageScrollPhysics(),
              itemCount: widget.itemCount,
              onPageChanged: widget.onIndexChanged,
              itemBuilder: (context, index) => Listener(
                onPointerSignal: _onPointerSignal,
                child: widget.itemBuilder(context, index),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
