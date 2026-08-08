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
    this.initialFraction,
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

  /// 初始滚动进度（0.0 ~ 1.0，恢复阅读进度用；null = 从头）。
  /// 无分章（单章"全文"）时也依赖它定位章节内滚动位置。
  final double? initialFraction;

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

  /// 最近一次滚动的时刻。滑动刚结束后的一小段时间内，轻点屏幕用于"暂停"滚动，
  /// 不应触发顶/底栏显隐切换（避免误触菜单）。
  DateTime _lastScrollTime = DateTime.fromMillisecondsSinceEpoch(0);

  /// 恢复进度是否已完成定位。完成后不再重复定位。
  bool _restored = false;

  /// 正在执行 jumpTo 定位（区分定位触发的滚动与用户手动滚动）。
  bool _restoring = false;

  late int _first = widget.initialChapter;
  late int _last = widget.initialChapter;

  @override
  void initState() {
    super.initState();
    debugPrint('[epub_scroll_mode] initState: initialChapter=${widget.initialChapter} '
        'totalChapters=${widget.totalChapters} first=$_first last=$_last '
        'initialFraction=${widget.initialFraction}');
    widget.ensureChapter(widget.initialChapter);
    _controller.addListener(_maybeExtend);
    _restoreFraction();
  }

  @override
  void didUpdateWidget(covariant EpubScrollMode oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 章节内容异步加载完成会触发本组件 rebuild（contentOf 是新闭包）。
    // 此时主动扩展窗口，解决"滑到底后下一章加载完成却无法继续向下滚动"。
    _syncWindow();
    // 恢复进度：initialFraction 发生变化（null → 值），或内容加载驱动
    // rebuild 后尚未定位成功，则再次尝试定位，避免内容加载慢导致
    // 恢复失败、总是从头开始。
    if (!_restored &&
        widget.initialFraction != null &&
        widget.initialFraction! > 0) {
      _restoreFraction();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 按 [widget.initialFraction] 定位滚动位置。
  ///
  /// 不做无限递归重试（避免每帧堆积 post-frame callback 导致界面卡死）；
  /// 仅尝试一次：若内容尚未布局（extent <= 0，章节异步加载中）则本次放弃，
  /// 由 [didUpdateWidget] 在内容加载完成触发 rebuild 时再次调用本方法重试，
  /// 直至定位成功（[_restored]），解决"历史记录不生效、总是从头开始"。
  void _restoreFraction() {
    final f = widget.initialFraction;
    if (f == null || f <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients || _restored) return;
      final pos = _controller.position;
      final extent = pos.maxScrollExtent - pos.minScrollExtent;
      if (extent <= 0) return; // 内容未就绪，等下次 rebuild 再试
      _restoring = true;
      _controller.jumpTo(
        pos.minScrollExtent + extent * f.clamp(0.0, 1.0),
      );
      _restoring = false;
      _restored = true;
    });
  }

  /// 内容就绪后主动扩展窗口：前后边缘章节已加载则逐章延伸。
  ///
  /// 窗口扩展**不能只依赖滚动事件**（[_maybeExtend]）：当用户滑到底部、下一章
  /// 内容异步加载完成后，若没有新滚动事件，窗口就不会扩展、`maxScrollExtent`
  /// 不增长，导致"向下滚动不了"。因此内容加载完成触发 rebuild 时（见
  /// [didUpdateWidget]）调用本方法，把已就绪的边缘章节纳入窗口。
  bool _syncWindow() {
    var changed = false;
    while (_last < widget.totalChapters - 1 &&
        widget.contentOf(_last + 1) != null) {
      _last++;
      unawaited(widget.ensureChapter(_last + 1));
      changed = true;
    }
    while (_first > 0 && widget.contentOf(_first - 1) != null) {
      _first--;
      unawaited(widget.ensureChapter(_first - 1));
      changed = true;
    }
    if (changed) {
      debugPrint('[epub_scroll_mode] _syncWindow: first=$_first last=$_last');
    }
    return changed;
  }

  void _maybeExtend() {
    if (!_controller.hasClients) return;
    final pos = _controller.position;
    final extent = pos.maxScrollExtent - pos.minScrollExtent;
    _lastScrollTime = DateTime.now();
    // 用户手动滚动（非恢复定位触发）：放弃进度恢复，避免后续定位把位置拉回。
    if (!_restoring && !_restored) {
      _restored = true;
    }
    if (extent > 0) {
      widget.onProgress?.call(
        ((pos.pixels - pos.minScrollExtent) / extent).clamp(0.0, 1.0),
      );
    }
    // 向前：滑到顶部附近，预加载上一章（窗口扩展由 _syncWindow 处理）
    final atTop = pos.pixels <= pos.minScrollExtent + _backwardTrigger;
    if (atTop && _first > 0) {
      unawaited(widget.ensureChapter(_first - 1));
    }
    // 向后：滑到底部附近，预加载下一章（窗口扩展由 _syncWindow 处理）
    final atBottom = pos.pixels >= pos.maxScrollExtent - _forwardTrigger;
    if (atBottom && _last < widget.totalChapters - 1) {
      unawaited(widget.ensureChapter(_last + 1));
    }
    // 预加载可能已让内容就绪，立即尝试扩展窗口
    if ((atTop || atBottom) && _syncWindow() && mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        // 滑动刚结束（350ms 内）的轻点用于"暂停"滚动，不切换顶/底栏菜单，
        // 避免滑动过程中误触弹菜单。
        if (DateTime.now().difference(_lastScrollTime) <
            const Duration(milliseconds: 350)) {
          return;
        }
        widget.onToggleChrome?.call();
      },
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
