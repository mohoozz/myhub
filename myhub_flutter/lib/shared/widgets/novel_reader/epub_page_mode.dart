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
    this.initialPage,
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

  /// 初始页码（恢复进度时精确定位到上次阅读的页）。
  final int? initialPage;

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

  /// 当前页码。组件重建时由 [initState] 重新初始化为
  /// `widget.initialPage`（恢复进度时跳到上次阅读的页），其它场景为 0。
  int _page = 0;

  /// startAtEnd 一次性处理：进入章节时若 _page == 0 且要求定位末页，
  /// 帧末 jump 到 _pages.length - 1。
  bool _initialJumpDone = false;
  bool _chapterNavCooldown = false;

  @override
  void initState() {
    super.initState();
    // 恢复进度（widget.initialPage != null）：首帧 _page 初始化为上次阅读页。
    // 不在 initState 中 jumpToPage：此时 _controller 尚未 attach 到 PageView，
    // _pages 也可能未就绪（章节内容异步加载），统一在 [_repaginateIfNeeded]
    // （_pages 已填、PageView 已 attach）里确保 _controller 同步。
    _page = widget.initialPage ?? 0;
  }

  @override
  void didUpdateWidget(covariant EpubPageMode oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 同一组件复用时（恢复流程 setState 触发 build，外部 key 不变）：
    // 外部从"无 initialPage"切换到"有 initialPage"，更新 _page。
    // 不在 _pages 未就绪时 clamp 到 0：保留恢复的页码，由
    // [_repaginateIfNeeded]（_pages 加载完成后）统一负责 _controller 同步。
    if (widget.initialPage != oldWidget.initialPage &&
        widget.initialPage != null &&
        widget.initialPage != _page) {
      _page = widget.initialPage!;
      if (_pages.isNotEmpty) {
        _page = _page.clamp(0, _pages.length - 1);
        if (_controller.hasClients &&
            _controller.page?.round() != _page) {
          _controller.jumpToPage(_page);
        }
      }
    }
  }

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
    // 一次性初始定位：initState / didUpdateWidget 阶段 _controller 尚未 attach、
    // _pages 也不一定就绪，统一的跳页动作推迟到分页后（PageView 已 attach）执行。
    // 优先级：恢复进度（_page != 0） > 末页定位（startAtEnd && _page == 0）> 默认 0。
    if (!_initialJumpDone && _pages.isNotEmpty) {
      _initialJumpDone = true;
      final wantEnd = widget.startAtEnd && _page == 0 && _pages.length > 1;
      if (wantEnd) {
        _page = _pages.length - 1;
      }
      if (_page != 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _controller.hasClients) {
            if (_controller.page?.round() != _page) {
              _controller.jumpToPage(_page);
            }
          }
        });
      }
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
