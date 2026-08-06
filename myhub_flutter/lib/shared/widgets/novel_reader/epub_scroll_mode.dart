import 'dart:async';

import 'package:flutter/material.dart';
import 'package:myhub_flutter/shared/widgets/novel_reader/epub_html.dart';
import 'package:myhub_flutter/shared/widgets/novel_reader/novel_reader.dart';

/// EPUB 滚动阅读模式（TODO 6.2，结构与 TXT 滚动模式一致）。
///
/// `CustomScrollView` + `center` 键双向无限列表，章节间平滑衔接；
/// 富文本原子直接以 Text.rich 渲染，图片固定尺寸盒内嵌。
class EpubScrollMode extends StatefulWidget {
  const EpubScrollMode({
    super.key,
    required this.initialChapter,
    required this.totalChapters,
    required this.chapterTitle,
    required this.contentOf,
    required this.ensureChapter,
    required this.style,
    required this.imageBuilder,
    this.onToggleChrome,
    this.onProgress,
  });

  /// 初始章节（列表中心锚点）。
  final int initialChapter;

  /// 章节总数。
  final int totalChapters;

  /// 章节标题。
  final String Function(int index) chapterTitle;

  /// 已缓存的章节原子（null = 未加载，显示占位并等待）。
  final List<RichAtom>? Function(int index) contentOf;

  /// 触发章节加载（幂等）。
  final Future<void> Function(int index) ensureChapter;

  /// 文本样式配置。
  final ReaderStyle style;

  /// 图片内容构建（固定尺寸盒内）。
  final Widget Function(ImgAtom atom) imageBuilder;

  /// 轻触正文（切换顶栏显隐）。
  final VoidCallback? onToggleChrome;

  /// 滚动进度回调（0.0 ~ 1.0，TODO 6.4）。
  final ValueChanged<double>? onProgress;

  @override
  State<EpubScrollMode> createState() => _EpubScrollModeState();
}

class _EpubScrollModeState extends State<EpubScrollMode> {
  static const double _forwardTrigger = 1200;
  static const double _backwardTrigger = 200;

  final ScrollController _controller = ScrollController();
  final UniqueKey _centerKey = UniqueKey();

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
      child: LayoutBuilder(
        builder: (context, constraints) {
          final contentWidth = constraints.maxWidth - 32;
          final imgHeight = constraints.maxHeight * 0.6;
          return CustomScrollView(
            controller: _controller,
            center: _centerKey,
            slivers: [
              SliverList.builder(
                itemCount: widget.initialChapter - _first,
                itemBuilder: (context, i) => _buildChapter(
                  widget.initialChapter - 1 - i,
                  contentWidth,
                  imgHeight,
                ),
              ),
              SliverList.builder(
                key: _centerKey,
                itemCount: _last - widget.initialChapter + 1,
                itemBuilder: (context, i) => _buildChapter(
                  widget.initialChapter + i,
                  contentWidth,
                  imgHeight,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildChapter(int index, double contentWidth, double imgHeight) {
    final atoms = widget.contentOf(index);
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
          if (atoms == null)
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
            Text.rich(
              TextSpan(
                children: buildRichSpans(
                  atoms,
                  imgWidth: contentWidth,
                  imgHeight: imgHeight,
                  imageBuilder: widget.imageBuilder,
                ),
                style: style.textStyle,
              ),
            ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
