import 'package:flutter/material.dart';
import 'package:myhub_flutter/shared/widgets/comic_reader/comic_page_image.dart';

/// 单页模式（TODO 7.2）：PageView 左右滑动翻页，
/// 每张图 InteractiveViewer 双指缩放/拖拽，轻触切换控制栏显隐。
class ComicSinglePageMode extends StatefulWidget {
  const ComicSinglePageMode({
    super.key,
    required this.pageCount,
    required this.urlOf,
    required this.headers,
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

  /// 起始页码（0 起）。
  final int initialPage;

  /// 翻页回调（当前页码，0 起）。
  final ValueChanged<int> onPageChanged;

  /// 轻触画面回调（切换顶/底栏显隐）。
  final VoidCallback onToggleChrome;

  @override
  State<ComicSinglePageMode> createState() => _ComicSinglePageModeState();
}

class _ComicSinglePageModeState extends State<ComicSinglePageMode> {
  late final PageController _controller;

  @override
  void initState() {
    super.initState();
    _controller = PageController(initialPage: widget.initialPage);
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
        itemCount: widget.pageCount,
        onPageChanged: widget.onPageChanged,
        itemBuilder: (context, i) => InteractiveViewer(
          maxScale: 5,
          child: Center(
            child: ComicPageImage(
              url: widget.urlOf(i),
              headers: widget.headers,
              pageNumber: i + 1,
            ),
          ),
        ),
      ),
    );
  }
}
