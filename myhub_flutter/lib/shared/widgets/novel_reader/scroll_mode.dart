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

  final ScrollController _controller = ScrollController();
  final UniqueKey _centerKey = UniqueKey();

  /// 当前加载窗口 [_first, _last]。
  late int _first = widget.initialChapter;
  late int _last = widget.initialChapter;

  @override
  void initState() {
    super.initState();
    widget.ensureChapter(widget.initialChapter);
    _controller.addListener(_maybeExtend);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 接近列表边缘时扩展窗口（仅当边缘章节内容已就绪，逐章延伸）。
  void _maybeExtend() {
    if (!_controller.hasClients) return;
    final pos = _controller.position;
    final extent = pos.maxScrollExtent - pos.minScrollExtent;
    if (extent > 0) {
      widget.onProgress?.call(
        ((pos.pixels - pos.minScrollExtent) / extent).clamp(0.0, 1.0),
      );
    }
    if (pos.pixels > pos.maxScrollExtent - _forwardTrigger &&
        _last < widget.totalChapters - 1 &&
        widget.contentOf(_last) != null) {
      setState(() => _last++);
      unawaited(widget.ensureChapter(_last));
    }
    if (pos.pixels < pos.minScrollExtent + _backwardTrigger &&
        _first > 0 &&
        widget.contentOf(_first) != null) {
      setState(() => _first--);
      unawaited(widget.ensureChapter(_first));
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
