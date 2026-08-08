import 'dart:async';

import 'package:flutter/material.dart';
import 'package:myhub_flutter/shared/widgets/novel_reader/novel_reader.dart';

/// 滚动阅读模式（TODO 6.1）。
///
/// * `CustomScrollView` + `center` 键双向无限列表：
///   中心 Sliver 从初始章节向下增长，前向 Sliver 向上反向增长；
/// * 接近边缘且边缘章节内容已加载时扩展窗口（前后各一章），
///   章节间平滑衔接、滚动位置不受前置内容影响；
/// * 内容加载由外部缓存驱动（[ensureChapter] 幂等触发）。
class ReaderScrollMode extends StatefulWidget {
  const ReaderScrollMode({
    super.key,
    required this.initialChapter,
    required this.totalChapters,
    required this.chapterTitle,
    required this.contentOf,
    required this.ensureChapter,
    required this.style,
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

  /// 已缓存的章节内容（null = 未加载，显示占位并等待）。
  final String? Function(int index) contentOf;

  /// 触发章节加载（幂等）。
  final Future<void> Function(int index) ensureChapter;

  /// 文本样式配置。
  final ReaderStyle style;

  /// 初始滚动进度（0.0 ~ 1.0，恢复阅读进度用；null = 从头）。
  /// 无分章（单章"全文"）时也依赖它定位章节内滚动位置。
  final double? initialFraction;

  /// 轻触正文（切换顶栏显隐）。
  final VoidCallback? onToggleChrome;

  /// 滚动进度回调（0.0 ~ 1.0，TODO 6.4）。
  final ValueChanged<double>? onProgress;

  @override
  State<ReaderScrollMode> createState() => _ReaderScrollModeState();
}

class _ReaderScrollModeState extends State<ReaderScrollMode> {
  /// 距底部多少像素时预接下一章。
  static const double _forwardTrigger = 1200;

  /// 距顶部多少像素时预接上一章。
  static const double _backwardTrigger = 200;

  /// 初始窗口：当前章节前后各预渲染 N 章（让用户能立即上下滚动）。
  static const int _initWindow = 2;

  final ScrollController _controller = ScrollController();
  final UniqueKey _centerKey = UniqueKey();

  /// 最近一次滚动的时刻。滑动刚结束后的一小段时间内，轻点屏幕用于"暂停"滚动，
  /// 不应触发顶/底栏显隐切换（避免误触菜单）。
  DateTime _lastScrollTime = DateTime.fromMillisecondsSinceEpoch(0);

  /// 恢复进度是否已完成定位。完成后不再重复定位。
  bool _restored = false;

  /// 正在执行 jumpTo 定位（区分定位触发的滚动与用户手动滚动，
  /// 避免把用户手动滚动误判为"放弃恢复"）。
  bool _restoring = false;

  /// 当前加载窗口 [_first, _last]。
  late int _first = widget.totalChapters > 0
      ? (widget.initialChapter - _initWindow)
          .clamp(0, widget.totalChapters - 1)
      : 0;
  late int _last = widget.totalChapters > 0
      ? (widget.initialChapter + _initWindow)
          .clamp(0, widget.totalChapters - 1)
      : 0;

  @override
  void initState() {
    super.initState();
    debugPrint('[scroll_mode] initState: initialChapter=${widget.initialChapter} '
        'totalChapters=${widget.totalChapters} first=$_first last=$_last '
        'initialFraction=${widget.initialFraction}');
    // 初始窗口内所有章节立即触发预加载，否则会显示 loading 圈且无法滚动
    for (var i = _first; i <= _last; i++) {
      widget.ensureChapter(i);
    }
    _controller.addListener(_maybeExtend);
    _restoreFraction();
  }

  @override
  void didUpdateWidget(covariant ReaderScrollMode oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 章节内容异步加载完成会触发本组件 rebuild（contentOf 是新闭包）。
    // 此时主动扩展窗口，解决"滑到底后下一章加载完成却无法继续向下滚动"。
    _syncWindow();
    // 恢复进度：initialFraction 发生变化（null → 值），或内容加载驱动
    // rebuild 后尚未定位成功，则再次尝试定位。这样即使首次定位时章节
    // 尚未加载（extent=0），内容加载完成后也能通过 rebuild 重新定位，
    // 避免"历史记录不生效、总是从头开始"。
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
  /// 直至定位成功（[_restored]）。这样既能避免卡死，又能保证内容加载完成后
  /// 一定完成定位，解决"历史记录不生效、总是从头开始"。
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

  /// 接近列表边缘时扩展窗口（仅当边缘章节内容已就绪，逐章延伸）。
  ///
  /// 当滑到列表两端时，前后已无内容可滑（minScrollExtent/maxScrollExtent），
  /// 此时只要还有未加载的章节就继续扩展——这是用户能持续向上/向下滚动的关键。
  /// 仅在用户实际滚动触发（atTop/atBottom 为 true）时扩展，避免首帧
  /// `pos.pixels == minScrollExtent` 立刻扩展导致一次性把窗口推到 0。
  ///
  /// 滑到边缘时**总是**预加载相邻章节（即使当前边缘内容未就绪），避免用户
  /// 快速下滑到 loading 边缘后因扩展条件 `contentOf(_last) != null` 不满足
  /// 而"卡住"无法继续；相邻章节就绪后窗口即随之扩展。
  /// 内容就绪后主动扩展窗口：前后边缘章节已加载则逐章延伸。
  ///
  /// 窗口扩展**不能只依赖滚动事件**（[_maybeExtend]）：当用户滑到底部、下一章
  /// 内容异步加载完成后，若没有新滚动事件，窗口就不会扩展、`maxScrollExtent`
  /// 不增长，导致"向下滚动不了"。因此内容加载完成触发 rebuild 时（见
  /// [didUpdateWidget]）调用本方法，把已就绪的边缘章节纳入窗口。
  /// 因内容逐章异步就绪，每次最多扩展少量章节，不会一次推到底。
  bool _syncWindow() {
    var changed = false;
    // 向后扩展：下一章内容已就绪则纳入窗口
    while (_last < widget.totalChapters - 1 &&
        widget.contentOf(_last + 1) != null) {
      _last++;
      unawaited(widget.ensureChapter(_last + 1));
      changed = true;
    }
    // 向前扩展：上一章内容已就绪则纳入窗口
    while (_first > 0 && widget.contentOf(_first - 1) != null) {
      _first--;
      unawaited(widget.ensureChapter(_first - 1));
      changed = true;
    }
    if (changed) {
      debugPrint('[scroll_mode] _syncWindow: first=$_first last=$_last');
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
    // 向前：滑到顶部附近，预加载上一章（窗口扩展由 _syncWindow 在内容就绪后处理）
    final atTop = pos.pixels <= pos.minScrollExtent + _backwardTrigger;
    if (atTop && _first > 0) {
      unawaited(widget.ensureChapter(_first - 1));
    }
    // 向后：滑到底部附近，预加载下一章（窗口扩展由 _syncWindow 在内容就绪后处理）
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
      child: CustomScrollView(
        controller: _controller,
        center: _centerKey,
        slivers: [
          // 前向（向上）章节：索引 0 紧邻中心，对应 initialChapter - 1
          SliverList.builder(
            itemCount: widget.initialChapter - _first,
            itemBuilder: (context, i) =>
                _buildChapter(widget.initialChapter - 1 - i),
          ),
          // 中心 + 后向（向下）章节
          SliverList.builder(
            key: _centerKey,
            itemCount: _last - widget.initialChapter + 1,
            itemBuilder: (context, i) =>
                _buildChapter(widget.initialChapter + i),
          ),
        ],
      ),
    );
  }

  Widget _buildChapter(int index) {
    final content = widget.contentOf(index);
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
          if (content == null)
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
            Text(content, style: style.textStyle),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
