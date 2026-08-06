import 'dart:async';

import 'package:flutter/material.dart';
import 'package:myhub_flutter/shared/widgets/novel_reader/epub_html.dart';
import 'package:myhub_flutter/shared/widgets/novel_reader/novel_reader.dart';

/// EPUB 翻页阅读模式（TODO 6.2，交互与 TXT 翻页一致）。
///
/// 富文本原子经 [TextPainter] 一次排版后按页高切分（行边界对齐），
/// 图片以固定尺寸占位盒参与排版，渲染尺寸与排版尺寸一致。
class EpubPageMode extends StatefulWidget {
  const EpubPageMode({
    super.key,
    required this.atoms,
    required this.header,
    required this.style,
    required this.imageBuilder,
    this.startAtEnd = false,
    this.onPrevChapter,
    this.onNextChapter,
    this.onToggleChrome,
    this.onPageProgress,
  });

  /// 当前章节的富文本原子。
  final List<RichAtom> atoms;

  /// 页眉小字（章节标题）。
  final String header;

  /// 文本样式配置。
  final ReaderStyle style;

  /// 图片内容构建（固定尺寸盒内）。
  final Widget Function(ImgAtom atom) imageBuilder;

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
  State<EpubPageMode> createState() => _EpubPageModeState();
}

class _EpubPageModeState extends State<EpubPageMode> {
  static const double _padH = 16;
  static const double _padTop = 8;
  static const double _padBottom = 12;
  static const double _headerHeight = 26;

  /// 图片占位盒高度占文本区高度比例。
  static const double _imgHeightFactor = 0.6;

  final PageController _controller = PageController();

  List<List<RichAtom>> _pages = const [];
  String _cacheKey = '';
  int _page = 0;
  bool _initialJumpDone = false;
  bool _chapterNavCooldown = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _keyOf(double width, double height) =>
      '${widget.atoms.length}@${width.toStringAsFixed(1)}x'
      '${height.toStringAsFixed(1)}/${widget.style.fontSize}';

  void _repaginateIfNeeded(double textWidth, double textHeight) {
    final key = _keyOf(textWidth, textHeight);
    if (key == _cacheKey) return;
    _cacheKey = key;
    _pages = paginateRichAtoms(
      widget.atoms,
      widget.style.textStyle,
      textWidth,
      textHeight,
      textHeight * _imgHeightFactor,
    );
    if (_page >= _pages.length) {
      _page = _pages.length - 1;
    }
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
                        child: Text.rich(
                          TextSpan(
                            children: buildRichSpans(
                              _pages[i],
                              imgWidth: textWidth,
                              imgHeight: textHeight * _imgHeightFactor,
                              imageBuilder: widget.imageBuilder,
                            ),
                            style: widget.style.textStyle,
                          ),
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

/// 将富文本原子按可用区域分页（行边界对齐，不出半行）。
///
/// 图片以固定尺寸（width × imgHeight）占位盒参与排版；
/// 单次排版后按"页首字符行顶 y + 页高"迭代求分页点。
List<List<RichAtom>> paginateRichAtoms(
  List<RichAtom> atoms,
  TextStyle baseStyle,
  double width,
  double height,
  double imgHeight,
) {
  if (atoms.isEmpty || width <= 0 || height <= 0) {
    return const [[]];
  }
  final fullText = richAtomsText(atoms);
  final spans = buildRichSpans(
    atoms,
    imgWidth: width,
    imgHeight: imgHeight,
    imageBuilder: (_) => const SizedBox.shrink(),
  );
  final tp = TextPainter(
    text: TextSpan(children: spans, style: baseStyle),
    textDirection: TextDirection.ltr,
  );
  // WidgetSpan 占位尺寸需与渲染尺寸一致，分页才准确
  final dims = <PlaceholderDimensions>[
    for (final a in atoms)
      if (a is ImgAtom)
        PlaceholderDimensions(
          size: Size(width, imgHeight),
          alignment: PlaceholderAlignment.bottom,
        ),
  ];
  if (dims.isNotEmpty) {
    tp.setPlaceholderDimensions(dims);
  }
  tp.layout(maxWidth: width);
  if (tp.height <= height) {
    return [atoms];
  }

  final pages = <List<RichAtom>>[];
  var start = 0;
  while (start < fullText.length) {
    // 当前页首字符所在行的行顶 y
    final startBoxes = tp.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: start + 1),
    );
    final top = startBoxes.isEmpty ? 0.0 : startBoxes.first.top;
    var end = tp.getPositionForOffset(Offset(width, top + height)).offset;
    if (end <= start) {
      end = start + 1; // 防御：保证前进
    } else {
      // 对齐行边界：命中行若底部超出可用高度，回退到该行行首
      final line = tp.getLineBoundary(TextPosition(offset: end));
      if (line.start > start && line.end > line.start) {
        final boxes = tp.getBoxesForSelection(
          TextSelection(baseOffset: line.start, extentOffset: line.end - 1),
        );
        end = (boxes.isNotEmpty && boxes.last.bottom <= top + height + 0.5)
            ? line.end
            : line.start;
      }
    }
    final page = sliceRichAtoms(atoms, start, end);
    if (page.isNotEmpty) {
      pages.add(page);
    }
    start = end;
  }
  return pages.isEmpty ? const [[]] : pages;
}
