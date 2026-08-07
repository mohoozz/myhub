import 'dart:async';

import 'package:flutter/material.dart';
import 'package:myhub_flutter/shared/widgets/novel_reader/novel_reader.dart';

/// 滚动阅读模式（TODO 6.1）。
///
/// * `CustomScrollView` + `center` 键双向无限列表：
///   中心 Sliver 从初始章节向下增长，前向 Sliver 向上反向增长；
/// * 接近边缘且边缘章节内容已加载时扩展窗口（前后各一章），
///   章节间平滑衔接、滚动位置不受前置内容影响；
/// * 内容加载由外部缓存驱动（[ensureChapter] 幂等触发）。
class ReaderScrollMode extends StatefulWidget {
  const ReaderScrollMode({
    super.key,
    required this.initialChapter,
    required this.totalChapters,
    required this.chapterTitle,
    required this.contentOf,
    required this.ensureChapter,
    required this.style,
    this.initialFraction,
    this.onToggleChrome,
    this.onProgress,
  });

  /// 初始章节（列表中心锚点）。
  final int initialChapter;

  /// 章节总数。
  final int totalChapters;

  /// 章节标题。
  final String Function(int index) chapterTitle;

  /// 已缓存的章节内容（null = 未加载，显示占位并等待）。
  final String? Function(int index) contentOf;

  /// 触发章节加载（幂等）。
  final Future<void> Function(int index) ensureChapter;

  /// 文本样式配置。
  final ReaderStyle style;

  /// 初始滚动进度（0.0 ~ 1.0，恢复阅读进度用；null = 从头）。
  /// 无分章（单章"全文"）时也依赖它定位章节内滚动位置。
  final double? initialFraction;

  /// 轻触正文（切换顶栏显隐）。
  final VoidCallback? onToggleChrome;

  /// 滚动进度回调（0.0 ~ 1.0，TODO 6.4）。
  final ValueChanged<double>? onProgress;

  @override
  State<ReaderScrollMode> createState() => _ReaderScrollModeState();
}

class _ReaderScrollModeState extends State<ReaderScrollMode> {
  /// 距底部多少像素时预接下一章。
  static const double _forwardTrigger = 1200;

  /// 距顶部多少像素时预接上一章。
  static const double _backwardTrigger = 200;

  /// 初始窗口：当前章节前后各预渲染 N 章（让用户能立即上下滚动）。
  static const int _initWindow = 2;

  final ScrollController _controller = ScrollController();
  final UniqueKey _centerKey = UniqueKey();

  /// 当前加载窗口 [_first, _last]。
  late int _first = widget.totalChapters > 0
      ? (widget.initialChapter - _initWindow)
          .clamp(0, widget.totalChapters - 1)
      : 0;
  late int _last = widget.totalChapters > 0
      ? (widget.initialChapter + _initWindow)
          .clamp(0, widget.totalChapters - 1)
      : 0;

  @override
  void initState() {
    super.initState();
    // 初始窗口内所有章节立即触发预加载，否则会显示 loading 圈且无法滚动
    for (var i = _first; i <= _last; i++) {
      widget.ensureChapter(i);
    }
    _controller.addListener(_maybeExtend);
    _restoreFraction();
  }

  @override
  void didUpdateWidget(covariant ReaderScrollMode oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 恢复进度异步完成：initialFraction 从 null → 值，此时定位滚动位置
    if (widget.initialFraction != oldWidget.initialFraction) {
      _restoreFraction();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 按 [widget.initialFraction] 定位滚动位置。
  /// 内容可能未布局完成（extent <= 0），延后到下一帧重试。
  void _restoreFraction() {
    final f = widget.initialFraction;
    if (f == null || f <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final pos = _controller.position;
      final extent = pos.maxScrollExtent - pos.minScrollExtent;
      if (extent <= 0) {
        // 章节内容尚未布局（异步加载中），延后重试
        _restoreFraction();
        return;
      }
      _controller.jumpTo(
        pos.minScrollExtent + extent * f.clamp(0.0, 1.0),
      );
    });
  }

  /// 接近列表边缘时扩展窗口（仅当边缘章节内容已就绪，逐章延伸）。
  ///
  /// 当滑到列表两端时，前后已无内容可滑（minScrollExtent/maxScrollExtent），
  /// 此时只要还有未加载的章节就继续扩展——这是用户能持续向上/向下滚动的关键。
  /// 仅在用户实际滚动触发（atTop/atBottom 为 true）时扩展，避免首帧
  /// `pos.pixels == minScrollExtent` 立刻扩展导致一次性把窗口推到 0。
  void _maybeExtend() {
    if (!_controller.hasClients) return;
    final pos = _controller.position;
    final extent = pos.maxScrollExtent - pos.minScrollExtent;
    if (extent > 0) {
      widget.onProgress?.call(
        ((pos.pixels - pos.minScrollExtent) / extent).clamp(0.0, 1.0),
      );
    }
    // 向前扩展：用户滑到顶部 200px 内（实际滚动触发），且还有前向章节
    final atTop = pos.pixels <= pos.minScrollExtent + _backwardTrigger;
    if (atTop &&
        _first > 0 &&
        widget.contentOf(_first) != null) {
      setState(() => _first--);
      unawaited(widget.ensureChapter(_first));
    }
    // 向后扩展：用户滑到底部 1200px 内（实际滚动触发），且还有后向章节
    final atBottom = pos.pixels >= pos.maxScrollExtent - _forwardTrigger;
    if (atBottom &&
        _last < widget.totalChapters - 1 &&
        widget.contentOf(_last) != null) {
      setState(() => _last++);
      unawaited(widget.ensureChapter(_last));
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onToggleChrome,
      child: CustomScrollView(
        controller: _controller,
        center: _centerKey,
        slivers: [
          // 前向（向上）章节：索引 0 紧邻中心，对应 initialChapter - 1
          SliverList.builder(
            itemCount: widget.initialChapter - _first,
            itemBuilder: (context, i) =>
                _buildChapter(widget.initialChapter - 1 - i),
          ),
          // 中心 + 后向（向下）章节
          SliverList.builder(
            key: _centerKey,
            itemCount: _last - widget.initialChapter + 1,
            itemBuilder: (context, i) =>
                _buildChapter(widget.initialChapter + i),
          ),
        ],
      ),
    );
  }

  Widget _buildChapter(int index) {
    final content = widget.contentOf(index);
    final style = widget.style;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.chapterTitle(index),
            style: TextStyle(
              fontSize: style.fontSize + 2,
              fontWeight: FontWeight.w600,
              color: style.foreground,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          if (content == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: style.subtle,
                  ),
                ),
              ),
            )
          else
            Text(content, style: style.textStyle),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
