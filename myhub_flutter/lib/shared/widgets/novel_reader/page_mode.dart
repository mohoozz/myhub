import 'dart:async';

import 'package:flutter/material.dart';
import 'package:myhub_flutter/shared/widgets/novel_reader/novel_reader.dart';

/// 翻页阅读模式（TODO 6.1）。
///
/// * 按可用区域用 [TextPainter] 将章节正文切分为页（行边界切分，不出半行）；
/// * `PageView.builder` 左右滑动翻页（默认滑动动画）；
/// * 左/右 30% 轻触翻页，中部轻触切换顶栏；
/// * 末页继续前翻 → 下一章，首页后翻 → 上一章（定位末页）。
class ReaderPageMode extends StatefulWidget {
  const ReaderPageMode({
    super.key,
    required this.content,
    required this.header,
    required this.style,
    this.startAtEnd = false,
    this.onPrevChapter,
    this.onNextChapter,
    this.onToggleChrome,
    this.onPageProgress,
  });

  /// 当前章节正文。
  final String content;

  /// 页眉小字（章节标题）。
  final String header;

  /// 文本样式配置。
  final ReaderStyle style;

  /// 初始定位到末页（从下一章回退进入时）。
  final bool startAtEnd;

  /// 越过首页（null = 无上一章）。
  final VoidCallback? onPrevChapter;

  /// 越过末页（null = 无下一章）。
  final VoidCallback? onNextChapter;

  /// 中部轻触（切换顶栏显隐）。
  final VoidCallback? onToggleChrome;

  /// 页码变化回调（页内进度，TODO 6.4）。
  final void Function(int page, int pageCount)? onPageProgress;

  @override
  State<ReaderPageMode> createState() => _ReaderPageModeState();
}

class _ReaderPageModeState extends State<ReaderPageMode> {
  static const double _padH = 16;
  static const double _padTop = 8;
  static const double _padBottom = 12;
  static const double _headerHeight = 26;

  final PageController _controller = PageController();

  List<String> _pages = const [];
  String _cacheKey = '';
  int _page = 0;
  bool _initialJumpDone = false;

  /// 章节切换冷却：防止越界手势连发。
  bool _chapterNavCooldown = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 分页缓存键：内容 / 可用区域 / 字号任一变化即重排。
  String _keyOf(double width, double height) =>
      '${widget.content.length}@${width.toStringAsFixed(1)}x'
      '${height.toStringAsFixed(1)}/${widget.style.fontSize}';

  void _repaginateIfNeeded(double textWidth, double textHeight) {
    final key = _keyOf(textWidth, textHeight);
    if (key == _cacheKey) return;
    _cacheKey = key;
    _pages = paginateText(
      widget.content,
      widget.style.textStyle,
      textWidth,
      textHeight,
    );
    if (_page >= _pages.length) {
      _page = _pages.length - 1;
    }
    // 初始定位末页（等首帧布局完成后跳转）
    if (widget.startAtEnd && !_initialJumpDone && _pages.isNotEmpty) {
      _initialJumpDone = true;
      _page = _pages.length - 1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controller.hasClients) {
          _controller.jumpToPage(_pages.length - 1);
        }
      });
    }
    // 页数可能变化（重排/切章），帧末上报页内进度
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onPageProgress?.call(_page, _pages.length);
      }
    });
  }

  void _turnPage(int delta) {
    final target = _page + delta;
    if (target < 0) {
      widget.onPrevChapter?.call();
      return;
    }
    if (target >= _pages.length) {
      widget.onNextChapter?.call();
      return;
    }
    _controller.animateToPage(
      target,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _onTapUp(TapUpDetails details, double width) {
    final dx = details.localPosition.dx;
    if (dx < width * 0.3) {
      _turnPage(-1);
    } else if (dx > width * 0.7) {
      _turnPage(1);
    } else {
      widget.onToggleChrome?.call();
    }
  }

  /// 越界滑动切章（PageView 到边后产生的 Overscroll 通知）。
  bool _onOverscroll(OverscrollNotification n) {
    if (_chapterNavCooldown || _pages.isEmpty) return false;
    if (n.overscroll > 0 &&
        _page == _pages.length - 1 &&
        widget.onNextChapter != null) {
      _chapterNavCooldown = true;
      widget.onNextChapter!.call();
    } else if (n.overscroll < 0 &&
        _page == 0 &&
        widget.onPrevChapter != null) {
      _chapterNavCooldown = true;
      widget.onPrevChapter!.call();
    } else {
      return false;
    }
    // 600ms 冷却，避免一次手势触发多次切章
    Timer(const Duration(milliseconds: 600), () {
      _chapterNavCooldown = false;
    });
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final textWidth = constraints.maxWidth - _padH * 2;
        final textHeight =
            constraints.maxHeight - _padTop - _padBottom - _headerHeight;
        _repaginateIfNeeded(textWidth, textHeight);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _onTapUp(d, constraints.maxWidth),
          child: NotificationListener<OverscrollNotification>(
            onNotification: _onOverscroll,
            child: PageView.builder(
              controller: _controller,
              itemCount: _pages.length,
              onPageChanged: (i) {
                setState(() => _page = i);
                widget.onPageProgress?.call(i, _pages.length);
              },
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.fromLTRB(
                  _padH,
                  _padTop,
                  _padH,
                  _padBottom,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 页眉：章节标题 + 页码
                    SizedBox(
                      height: _headerHeight - 8,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              widget.header,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: widget.style.subtle,
                                fontSize: 11,
                              ),
                            ),
                          ),
                          Text(
                            '${i + 1}/${_pages.length}',
                            style: TextStyle(
                              color: widget.style.subtle,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: Text(
                          _pages[i],
                          style: widget.style.textStyle,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 将正文按可用区域切分为页。
///
/// 用 [TextPainter] 测量：取高度边界处的文本位置，再回退/对齐到完整
/// 行边界（避免页面底部出现半行）。页首的换行符会被跳过，防止空白首行。
List<String> paginateText(
  String content,
  TextStyle style,
  double width,
  double height,
) {
  if (content.isEmpty || width <= 0 || height <= 0) {
    return const [''];
  }
  final pages = <String>[];
  var rest = content;
  while (rest.isNotEmpty) {
    // 跳过页首换行，避免空白首行
    while (rest.startsWith('\n') || rest.startsWith('\r')) {
      rest = rest.substring(1);
    }
    if (rest.isEmpty) break;

    final tp = TextPainter(
      text: TextSpan(text: rest, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);

    if (tp.height <= height) {
      pages.add(rest);
      break;
    }

    // 高度边界处的字符位置（相对 rest）
    var end = tp.getPositionForOffset(Offset(width, height)).offset;
    if (end <= 0) {
      end = 1; // 防御：保证每次前进
    } else {
      // 对齐行边界：命中行若底部超出可用高度，则回退到该行行首
      final line = tp.getLineBoundary(TextPosition(offset: end));
      if (line.start > 0 && line.end > line.start) {
        final boxes = tp.getBoxesForSelection(
          TextSelection(baseOffset: line.start, extentOffset: line.end - 1),
        );
        end = (boxes.isNotEmpty && boxes.last.bottom <= height + 0.5)
            ? line.end
            : line.start;
      }
    }
    pages.add(rest.substring(0, end));
    rest = rest.substring(end);
  }
  return pages.isEmpty ? const [''] : pages;
}
