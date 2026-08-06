import 'package:flutter/material.dart';
import 'package:myhub_flutter/shared/widgets/comic_reader/comic_page_image.dart';
import 'package:myhub_flutter/shared/widgets/comic_reader/comic_settings.dart';

/// 双页模式（TODO 7.2）：每屏左右排列两张图，横屏/平板适用。
///
/// 阅读方向由 [direction] 决定：rtl（日漫，默认）从右向左阅读——
/// PageView 反向滑动，组内先读右页再读左页；ltr 反之。
/// 整个双页组合共用一个 InteractiveViewer，两图同步缩放/拖拽。
class ComicDoublePageMode extends StatefulWidget {
  const ComicDoublePageMode({
    super.key,
    required this.pageCount,
    required this.urlOf,
    required this.headers,
    required this.direction,
    required this.initialPage,
    required this.onPageChanged,
    required this.onToggleChrome,
  });

  /// 总页数。
  final int pageCount;

  /// 按页码（0 起）构建图片 URL。
  final String Function(int page) urlOf;

  /// 图片请求头（JWT）。
  final Map<String, String> headers;

  /// 阅读方向。
  final ComicReadingDirection direction;

  /// 起始页码（0 起）。
  final int initialPage;

  /// 翻页回调（当前组第一张图页码，0 起）。
  final ValueChanged<int> onPageChanged;

  /// 轻触画面回调（切换顶/底栏显隐）。
  final VoidCallback onToggleChrome;

  @override
  State<ComicDoublePageMode> createState() => _ComicDoublePageModeState();
}

class _ComicDoublePageModeState extends State<ComicDoublePageMode> {
  late final PageController _controller;

  bool get _rtl => widget.direction == ComicReadingDirection.rtl;

  /// 双页组合数（两图一组，末组可能缺页）。
  int get _groupCount => (widget.pageCount + 1) ~/ 2;

  @override
  void initState() {
    super.initState();
    _controller = PageController(initialPage: widget.initialPage ~/ 2);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onToggleChrome,
      child: PageView.builder(
        controller: _controller,
        reverse: _rtl, // 日漫：从右向左翻页
        itemCount: _groupCount,
        onPageChanged: (group) => widget.onPageChanged(group * 2),
        itemBuilder: (context, group) {
          final first = group * 2;
          final second = first + 1;
          final hasSecond = second < widget.pageCount;
          // rtl：先读右页（first 在右，second 在左）；ltr 反之
          final left = _rtl ? second : first;
          final right = _rtl ? first : second;
          return InteractiveViewer(
            maxScale: 5,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _page(left, visible: _rtl ? hasSecond : true),
                  _page(right, visible: _rtl ? true : hasSecond),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 组内一页；[visible] 为 false 时渲染等宽占位（保持布局居中）。
  Widget _page(int page, {required bool visible}) {
    if (!visible) {
      // 末组缺页：透明占位撑住另一半
      return const Expanded(child: SizedBox.shrink());
    }
    return Expanded(
      child: ComicPageImage(
        url: widget.urlOf(page),
        headers: widget.headers,
        pageNumber: page + 1,
      ),
    );
  }
}
