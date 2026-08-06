import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:myhub_flutter/shared/widgets/comic_reader/comic_page_image.dart';
import 'package:myhub_flutter/shared/widgets/comic_reader/paged_viewer.dart';

/// 单页模式（TODO 7.2）：每屏一张图。
///
/// 交互统一由 [ComicPagedViewer] 提供：左右滑动 / 点击分区 / 键盘 /
/// 滚轮翻页，双指捏合与 Ctrl+滚轮缩放，点击中部切换控制栏显隐。
class ComicSinglePageMode extends StatelessWidget {
  const ComicSinglePageMode({
    super.key,
    required this.pageCount,
    required this.urlOf,
    required this.headers,
    required this.initialPage,
    required this.onPageChanged,
    required this.onToggleChrome,
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

  /// 翻页回调（当前页码，0 起）。
  final ValueChanged<int> onPageChanged;

  /// 轻触画面回调（切换顶/底栏显隐）。
  final VoidCallback onToggleChrome;

  /// 页码跳转通知（进度条拖动，值为页码 0 起）。
  final ValueListenable<int>? jumpTo;

  @override
  Widget build(BuildContext context) {
    return ComicPagedViewer(
      itemCount: pageCount,
      initialIndex: initialPage,
      onIndexChanged: onPageChanged,
      onToggleChrome: onToggleChrome,
      jumpTo: jumpTo,
      itemBuilder: (context, i) => Center(
        child: ComicPageImage(
          url: urlOf(i),
          headers: headers,
          pageNumber: i + 1,
        ),
      ),
    );
  }
}
