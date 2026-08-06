import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/shared/widgets/comic_reader/comic_page_image.dart';
import 'package:myhub_flutter/shared/widgets/comic_reader/comic_settings.dart';

/// 条漫模式（TODO 7.2）：纵向连续滚动，每张图按宽度占比显示。
///
/// 整体包一层 InteractiveViewer（panEnabled: false）：单指/滚轮滚动归
/// ListView，双指捏合缩放整页（内置滚轮缩放经 scaleFactor=∞ 屏蔽，
/// 避免滚轮被劫持成放大）；桌面端 Ctrl/⌘+滚轮调节条漫宽度占比
/// （30%~100%，持久化到阅读器设置）。
///
/// 页码定位与进度恢复基于每页**宽高比**（图片解码后实测，高/宽，
/// 与渲染宽度无关、跨会话恒定）：已知页按 宽度×宽高比 精确计算
/// 页高，未知页用已知页均值估算；进度保存 页码+页内偏移+宽高比表，
/// 重新打开时可精确重建滚动位置。
class ComicWebtoonMode extends ConsumerStatefulWidget {
  const ComicWebtoonMode({
    super.key,
    required this.pageCount,
    required this.urlOf,
    required this.headers,
    required this.initialPage,
    required this.onPageChanged,
    required this.onToggleChrome,
    this.initialPageOffset,
    this.initialAspects,
    this.initialFraction,
    this.onPageOffset,
    this.onAspectMeasured,
    this.jumpTo,
  });

  /// 总页数。
  final int pageCount;

  /// 按页码（0 起）构建图片 URL。
  final String Function(int page) urlOf;

  /// 图片请求头（JWT）。
  final Map<String, String> headers;

  /// 起始页码（0 起）。
  final int initialPage;

  /// 恢复的页内偏移（0~1，页内漂移量；配合 [initialAspects]
  /// 可精确定位到长图中部）。
  final double? initialPageOffset;

  /// 恢复的每页宽高比表（页码 → 高/宽），来自上次保存的进度。
  final Map<int, double>? initialAspects;

  /// 旧版进度的全局滚动比例（0~1；仅无页内偏移记录时的回退）。
  final double? initialFraction;

  /// 页内偏移回调（0~1），滚动时随页码一并上报，供进度精确保存。
  final ValueChanged<double>? onPageOffset;

  /// 每页宽高比实测回调（页码，高/宽），供进度持久化。
  final void Function(int page, double aspect)? onAspectMeasured;

  /// 滚动页码回调（按累计页高定位，0 起）。
  final ValueChanged<int> onPageChanged;

  /// 轻触画面回调（切换顶/底栏显隐）。
  final VoidCallback onToggleChrome;

  /// 页码跳转通知（进度条拖动，值为页码 0 起）。
  final ValueListenable<int>? jumpTo;

  @override
  ConsumerState<ComicWebtoonMode> createState() => _ComicWebtoonModeState();
}

class _ComicWebtoonModeState extends ConsumerState<ComicWebtoonMode> {
  /// 条漫宽度占比下限（Ctrl+滚轮缩小）。
  static const double _minWidthFactor = 0.3;

  /// Ctrl+滚轮每格调节的宽度占比步长。
  static const double _widthStep = 0.05;

  /// 未知页的兜底宽高比（条漫页常见 1:1.4）。
  static const double _fallbackAspect = 1.4;

  /// 页码/页内偏移的锚点位置（视口上部比例）：页码定位、进度
  /// 保存与恢复必须使用同一锚点，否则恢复位置会固定偏移
  /// 锚点高度的距离。
  static const double _anchorRatio = 0.3;

  final ScrollController _controller = ScrollController();
  int _reportedPage = -1;

  /// 初始滚动恢复是否仍待执行（用户滚动后放弃恢复，避免争抢）。
  bool _restorePending = false;

  /// 每页宽高比（页码 → 高/宽）：图片解码后实测，并可从上次
  /// 进度恢复；与渲染宽度无关，任意宽度下都能精确重建页高。
  final Map<int, double> _aspects = {};

  /// 当前页渲染宽度（build 时更新：屏宽 × 条漫宽度占比）。
  double _itemWidth = 0;

  /// 未测量页的估算宽高比：已测页均值，无实测值时用兜底值。
  double get _estimatedAspect {
    if (_aspects.isEmpty) return _fallbackAspect;
    var sum = 0.0;
    for (final a in _aspects.values) {
      sum += a;
    }
    return sum / _aspects.length;
  }

  /// 页渲染高度：宽度 × 宽高比（未测页用均值估算）。
  double _heightOf(int page) =>
      _itemWidth * (_aspects[page] ?? _estimatedAspect);

  /// 页码起始滚动偏移（累计页高）。
  double _offsetOfPage(int page) {
    var sum = 0.0;
    for (var i = 0; i < page && i < widget.pageCount; i++) {
      sum += _heightOf(i);
    }
    return sum;
  }

  /// 滚动偏移 → 页码（按累计页高定位，而非均匀比例估算）。
  int _pageAtOffset(double offset) {
    if (offset <= 0) return 0;
    var sum = 0.0;
    for (var i = 0; i < widget.pageCount; i++) {
      sum += _heightOf(i);
      if (offset < sum) return i;
    }
    return widget.pageCount - 1;
  }

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    _reportedPage = widget.initialPage;
    widget.jumpTo?.addListener(_onJumpTo);
    // 恢复上次保存的每页宽高比（精确重建页高的基础）
    final aspects = widget.initialAspects;
    if (aspects != null) _aspects.addAll(aspects);
    // 恢复上次阅读位置：页码 + 页内偏移（旧记录回退全局滚动比例）
    if (widget.initialPage > 0 ||
        (widget.initialPageOffset ?? 0) > 0 ||
        (widget.initialFraction ?? 0) > 0) {
      _restorePending = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _restoreScroll());
    }
  }

  /// 跳到上次阅读位置；首帧布局尚未产生可滚动范围时逐帧重试，
  /// 用户滚动后放弃恢复。
  void _restoreScroll() {
    if (!mounted || !_restorePending || !_controller.hasClients) return;
    final max = _controller.position.maxScrollExtent;
    if (max <= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _restoreScroll());
      return;
    }
    _restorePending = false;
    // 锚点偏移量：保存的页内偏移基于 滚动偏移+锚点 计算，
    // 恢复时需减回锚点才是实际滚动位置
    final anchorDelta =
        _controller.position.viewportDimension * _anchorRatio;
    final pageOffset = widget.initialPageOffset;
    final fraction = widget.initialFraction;
    final double target;
    if (pageOffset != null && pageOffset > 0) {
      // 页码起始偏移 + 页内漂移量（宽高比已知时精确）− 锚点
      target = _offsetOfPage(widget.initialPage) +
          pageOffset * _heightOf(widget.initialPage) -
          anchorDelta;
    } else if (fraction != null && fraction > 0) {
      // 旧版进度回退：全局滚动比例
      target = fraction * max;
    } else {
      target = _offsetOfPage(widget.initialPage) - anchorDelta;
    }
    _controller.jumpTo(target.clamp(0.0, max));
  }

  @override
  void dispose() {
    widget.jumpTo?.removeListener(_onJumpTo);
    _controller.dispose();
    super.dispose();
  }

  /// 进度条拖动跳转：目标页起始对齐锚点（已测页精确，未测页
  /// 按均值估算），使页码显示与拖动目标一致。
  void _onJumpTo() {
    final page = widget.jumpTo?.value ?? -1;
    if (page < 0 || !_controller.hasClients) return;
    final max = _controller.position.maxScrollExtent;
    if (max <= 0) return;
    final anchorDelta =
        _controller.position.viewportDimension * _anchorRatio;
    _controller.jumpTo(
      (_offsetOfPage(page) - anchorDelta).clamp(0.0, max),
    );
  }

  void _onScroll() {
    if (!_controller.hasClients) return;
    _reportPage();
  }

  /// 按当前滚动位置（视口上部 [_anchorRatio] 处为锚点，减少页边界
  /// 抖动）依据累计页高定位页码与页内偏移并上报。
  void _reportPage() {
    final anchor = _controller.offset +
        _controller.position.viewportDimension * _anchorRatio;
    final page = _pageAtOffset(anchor);
    final height = _heightOf(page);
    final pageOffset = height > 0
        ? ((anchor - _offsetOfPage(page)) / height).clamp(0.0, 1.0)
        : 0.0;
    widget.onPageOffset?.call(pageOffset);
    if (page != _reportedPage) {
      _reportedPage = page;
      widget.onPageChanged(page);
    }
  }

  /// 图片解码完成：记录宽高比（渲染宽度无关），并按当前位置
  /// 重新估算页码（不触发滚动）。
  void _onPageAspect(int page, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final aspect = size.height / size.width;
    final old = _aspects[page];
    if (old != null && (old - aspect).abs() < 0.001) return;
    _aspects[page] = aspect;
    widget.onAspectMeasured?.call(page, aspect);
    if (_controller.hasClients) _reportPage();
  }

  /// Ctrl/⌘+滚轮调节条漫宽度占比；普通滚轮不拦截，归 ListView 滚动。
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final ctrl = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (!ctrl) return;
    // 本 Listener 位于 Scrollable 内部下层，先向 PointerSignalResolver
    // 注册即胜出，阻止 Ctrl+滚轮触发列表滚动
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final settings = ref.read(comicReaderSettingsProvider);
      final next = (settings.effectiveWebtoonWidthFactor -
              event.scrollDelta.dy.sign * _widthStep)
          .clamp(_minWidthFactor, 1.0);
      if (next != settings.webtoonWidthFactor) {
        ref.read(comicReaderSettingsProvider.notifier)
            .setWebtoonWidthFactor(next);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // 条漫宽度占比（持久化在 comicReaderSettingsProvider）
    final widthFactor =
        ref.watch(comicReaderSettingsProvider).effectiveWebtoonWidthFactor;
    _itemWidth = MediaQuery.sizeOf(context).width * widthFactor;
    return GestureDetector(
      onTap: widget.onToggleChrome,
      child: InteractiveViewer(
        panEnabled: false, // 单指交还给 ListView 滚动，双指捏合缩放
        maxScale: 3,
        // 屏蔽内置滚轮缩放（scaleChange=exp(-dy/∞)=1），滚轮归 ListView 滚动
        scaleFactor: double.infinity,
        child: Center(
          child: FractionallySizedBox(
            widthFactor: widthFactor,
            child: ListView.builder(
              controller: _controller,
              itemCount: widget.pageCount,
              // 占位高度按每页各自的宽高比计算（未测页用均值
              // 估算）：已测页重建时高度与真实渲染一致，避免
              // 滚回视口时先按均值撑高再缩小造成的跳动/震荡
              itemBuilder: (context, i) => Listener(
                onPointerSignal: _onPointerSignal,
                child: ComicPageImage(
                  url: widget.urlOf(i),
                  headers: widget.headers,
                  pageNumber: i + 1,
                  fit: BoxFit.fitWidth,
                  placeholderHeight: _heightOf(i),
                  onImageSize: (size) => _onPageAspect(i, size),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
