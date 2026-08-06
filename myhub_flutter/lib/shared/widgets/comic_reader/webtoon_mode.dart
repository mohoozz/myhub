import 'package:flutter/material.dart';
import 'package:myhub_flutter/shared/widgets/comic_reader/comic_page_image.dart';

/// 条漫模式（TODO 7.2）：纵向连续滚动，每张图全宽显示。
///
/// 整体包一层 InteractiveViewer（panEnabled: false）：单指滚动归
/// ListView，双指捏合缩放整页；当前页码按滚动比例估算回传。
class ComicWebtoonMode extends StatefulWidget {
  const ComicWebtoonMode({
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

  /// 起始页码（0 起；条漫页高不定，仅作页码显示初值，
  /// 精确滚动恢复随 7.4 进度上报一并处理）。
  final int initialPage;

  /// 滚动页码回调（按滚动比例估算，0 起）。
  final ValueChanged<int> onPageChanged;

  /// 轻触画面回调（切换顶/底栏显隐）。
  final VoidCallback onToggleChrome;

  @override
  State<ComicWebtoonMode> createState() => _ComicWebtoonModeState();
}

class _ComicWebtoonModeState extends State<ComicWebtoonMode> {
  final ScrollController _controller = ScrollController();
  int _reportedPage = -1;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    _reportedPage = widget.initialPage;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_controller.hasClients) return;
    final max = _controller.position.maxScrollExtent;
    if (max <= 0) return;
    // 页高不一致（图片自适应高度），按比例粗估当前页
    final fraction = (_controller.offset / max).clamp(0.0, 1.0);
    final page = (fraction * (widget.pageCount - 1)).round();
    if (page != _reportedPage) {
      _reportedPage = page;
      widget.onPageChanged(page);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 条漫页常见宽高比约 1:1.4，作加载前占位避免列表跳动
    final placeholderHeight = MediaQuery.sizeOf(context).width * 1.4;
    return GestureDetector(
      onTap: widget.onToggleChrome,
      child: InteractiveViewer(
        panEnabled: false, // 单指交还给 ListView 滚动，双指捏合缩放
        maxScale: 3,
        child: ListView.builder(
          controller: _controller,
          itemCount: widget.pageCount,
          itemBuilder: (context, i) => ComicPageImage(
            url: widget.urlOf(i),
            headers: widget.headers,
            pageNumber: i + 1,
            fit: BoxFit.fitWidth,
            placeholderHeight: placeholderHeight,
          ),
        ),
      ),
    );
  }
}
