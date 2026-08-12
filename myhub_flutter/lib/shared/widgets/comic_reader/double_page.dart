import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:myhub_flutter/shared/widgets/comic_reader/comic_page_image.dart';
import 'package:myhub_flutter/shared/widgets/comic_reader/comic_settings.dart';
import 'package:myhub_flutter/shared/widgets/comic_reader/paged_viewer.dart';

/// 双页模式（TODO 7.2）：每屏左右排列两张图，横屏/平板适用。
///
/// 阅读方向由 [direction] 决定：rtl（日漫，默认）从右向左阅读——
/// PageView 反向滑动，组内先读右页再读左页；ltr 反之。
/// 交互统一由 [ComicPagedViewer] 提供：滑动 / 点击分区 / 键盘 / 滚轮
/// 翻页（rtl 时点击与左右键的前后映射反转），双指捏合与 Ctrl+滚轮
/// 缩放，点击中部切换控制栏显隐。
class ComicDoublePageMode extends StatelessWidget {
  const ComicDoublePageMode({
    super.key,
    required this.pageCount,
    required this.urlOf,
    required this.headers,
    required this.direction,
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

  /// 阅读方向。
  final ComicReadingDirection direction;

  /// 起始页码（0 起）。
  final int initialPage;

  /// 翻页回调（当前组第一张图页码，0 起）。
  final ValueChanged<int> onPageChanged;

  /// 轻触画面回调（切换顶/底栏显隐）。
  final VoidCallback onToggleChrome;

  /// 页码跳转通知（进度条拖动，值为页码 0 起）。
  final ValueListenable<int>? jumpTo;

  bool get _rtl => direction == ComicReadingDirection.rtl;

  /// 双页组合数（两图一组，末组可能缺页）。
  int get _groupCount => (pageCount + 1) ~/ 2;

  @override
  Widget build(BuildContext context) {
    return ComicPagedViewer(
      itemCount: _groupCount,
      initialIndex: initialPage ~/ 2,
      // 末组以最后一页上报：组内第一页页码，偶数页时末组为 N-2
      //（此时用户已看到最后一页 N-1），若不上报 N-1 则进度永远
      // <100%，无法标记"已读完"。
      onIndexChanged: (group) => onPageChanged(
        group >= _groupCount - 1 ? pageCount - 1 : group * 2,
      ),
      onToggleChrome: onToggleChrome,
      reverse: _rtl, // 日漫：从右向左翻页
      rtl: _rtl,
      jumpTo: jumpTo,
      indexOfPage: (page) => page ~/ 2, // 页码 → 双页组下标
      itemBuilder: (context, group) {
        final first = group * 2;
        final second = first + 1;
        final hasSecond = second < pageCount;
        // rtl：先读右页（first 在右，second 在左）；ltr 反之
        final left = _rtl ? second : first;
        final right = _rtl ? first : second;
        return Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _page(left, visible: _rtl ? hasSecond : true),
              _page(right, visible: _rtl ? true : hasSecond),
            ],
          ),
        );
      },
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
        url: urlOf(page),
        headers: headers,
        pageNumber: page + 1,
      ),
    );
  }
}
