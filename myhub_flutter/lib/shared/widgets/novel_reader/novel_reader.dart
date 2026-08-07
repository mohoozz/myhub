import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/api/reader_api.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/data/repositories/progress_repository.dart';
import 'package:myhub_flutter/features/reading/providers/reading_provider.dart';
import 'package:myhub_flutter/shared/widgets/novel_reader/chapter_drawer.dart';
import 'package:myhub_flutter/shared/widgets/novel_reader/page_mode.dart';
import 'package:myhub_flutter/shared/widgets/novel_reader/reader_settings.dart';
import 'package:myhub_flutter/shared/widgets/novel_reader/scroll_mode.dart';

// 阅读样式/模式/设置定义于 reader_settings.dart（6.3），此处再导出
// 供各阅读模式文件使用。
export 'package:myhub_flutter/shared/widgets/novel_reader/reader_settings.dart'
    show
        ReaderStyle,
        ReaderMode,
        ReaderTheme,
        ReaderSettings,
        readerSettingsProvider,
        ReaderSettingsSheet;

/// TXT 阅读器主 Widget（TODO 6.1）。
///
/// * 章节列表加载 `GET /api/reader/novel/chapters`；大文件后台建索引
///   期间 `ready=false`，前端 2s 轮询直至就绪（约 60s 超时）；
/// * 章节内容按需加载 `GET /api/reader/novel/content?chapter=N`，
///   内存缓存 + 当前章节 ±1 预加载；
/// * 翻页模式见 page_mode.dart，滚动模式见 scroll_mode.dart；
/// * 目录抽屉 / 进度显示与上报见 6.4。
class NovelReaderPage extends ConsumerStatefulWidget {
  const NovelReaderPage({
    super.key,
    required this.sourceId,
    required this.file,
  });

  /// 文件所属路径源 ID。
  final int sourceId;

  /// 小说文件（txt；epub 见 6.2）。
  final FileItem file;

  /// 以独立路由打开阅读器。
  static Future<void> open(
    BuildContext context, {
    required int sourceId,
    required FileItem file,
  }) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => NovelReaderPage(sourceId: sourceId, file: file),
      ),
    );
  }

  @override
  ConsumerState<NovelReaderPage> createState() => _NovelReaderPageState();
}

class _NovelReaderPageState extends ConsumerState<NovelReaderPage> {
  /// 章节索引轮询间隔（后端大文件后台建索引）。
  static const Duration _pollInterval = Duration(seconds: 2);

  /// 轮询上限（2s * 30 = 60s）。
  static const int _pollMax = 30;

  /// 当前阅读样式/模式（来自全局设置，build 时刷新；仅用于视图构建）。
  late ReaderStyle _style;
  late ReaderMode _mode;

  // ---- 章节列表 ----
  bool _loading = true;
  String? _error;
  bool _indexing = false; // 后端索引构建中（轮询中）
  int _pollCount = 0;
  Timer? _pollTimer;
  List<({int index, String title})> _chapters = const [];

  // ---- 章节内容缓存 ----
  int _chapter = 0;
  bool _chapterFromEnd = false; // 向前翻章时定位末页
  final Map<int, String> _contentCache = {};
  final Set<int> _loadingChapters = {};
  String? _contentError;

  // ---- 阅读进度（6.4） ----
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  int _pageInChapter = 0;
  int _pageCount = 1;
  double _scrollFraction = 0;

  /// 翻页/滚动/切章后防抖保存：阅读中持续落盘（对齐漫画 1s 防抖），
  /// 关窗/强杀等未走 dispose 的场景也不丢进度。
  Timer? _saveDebounce;

  /// 恢复进度时跳到的页码（首帧定位后消费）。
  int? _pendingPage;

  // ---- 顶栏显隐 ----
  bool _chromeVisible = true;

  @override
  void initState() {
    super.initState();
    _loadChapters();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _saveDebounce?.cancel();
    _saveProgress(); // 退出阅读器时同步落盘（6.4）
    super.dispose();
  }

  // ---------- 阅读进度（6.4） ----------

  /// 全书进度 0.0 ~ 1.0。
  double get _progress {
    if (_chapters.isEmpty) return 0;
    if (_mode == ReaderMode.scroll) {
      return _scrollFraction.clamp(0.0, 1.0);
    }
    return ((_chapter + (_pageInChapter + 1) / _pageCount) /
            _chapters.length)
        .clamp(0.0, 1.0);
  }

  /// 保存当前进度：本地 drift + 后端双写（离线时待同步，F-502）。
  ///
  /// 进度 JSON 记录：
  /// * chapter：最近阅读的章节（滚动模式按滚动比例折算）；
  /// * page：章节内页码（仅翻页模式，恢复时精确定位到上次页）；
  /// * scroll：全书滚动比例（仅滚动模式，0.0~1.0）。无分章（单章"全文"）
  ///   时 chapter 恒为 0、page 不更新，必须依赖 scroll 恢复章节内位置。
  Future<void> _saveProgress() async {
    if (_chapters.isEmpty) return;
    final isScroll = _mode == ReaderMode.scroll;
    // 滚动模式按滚动比例折算章节
    final chapter =
        isScroll ? (_scrollFraction * (_chapters.length - 1)).round() : _chapter;
    final page = isScroll ? 0 : _pageInChapter;
    final scroll = isScroll ? _scrollFraction : 0.0;
    final percent = _progress * 100;
    try {
      await ref.read(progressRepositoryProvider).save(
            sourceId: widget.sourceId,
            filePath: widget.file.path,
            mediaType: 'novel',
            title: widget.file.name,
            progressJson: jsonEncode({
              'chapter': chapter,
              'page': page,
              'scroll': scroll,
            }),
            percent: percent,
          );
      if (mounted) ref.invalidate(readingListProvider);
    } catch (_) {
      // 进度保存失败静默，不打断阅读
    }
  }

  /// 防抖保存进度：翻页/滚动/切章停止 1 秒后落盘。
  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 1), _saveProgress);
  }

  /// 打开时恢复上次阅读章节（已读完或小于第 1 章则不跳）。
  ///
  /// 同步记录 chapter + page：chapter > 0 时跳到对应章节并定位到 _pendingPage；
  /// page > 0 时直接传给翻页模式首帧。page_mode 的 initState 会消费 [_pendingPage]
  /// 初始化 _page，并通过 didUpdateWidget 处理后续 initialPage 变化。
  /// [_pendingRestore] 在恢复流程期间为 true，区分恢复与用户主动切章（_goToChapter
  /// 在 _pendingRestore=true 时使用 _pendingPage 初始化页码，结束后清空标志）。
  bool _pendingRestore = false;

  Future<void> _restoreProgress() async {
    try {
      final p = await ref
          .read(progressRepositoryProvider)
          .get(widget.sourceId, widget.file.path);
      if (p == null || p.finished) return;
      if (p.progressJson.isNotEmpty) {
        final decoded = jsonDecode(p.progressJson);
        if (decoded is! Map || mounted == false) return;
        final chapter =
            decoded['chapter'] is num ? (decoded['chapter'] as num).toInt() : 0;
        final page =
            decoded['page'] is num ? (decoded['page'] as num).toInt() : 0;
        final scroll = decoded['scroll'] is num
            ? (decoded['scroll'] as num).toDouble()
            : null;

        // 滚动模式：优先恢复全书滚动比例（含无分章单章"全文"场景，
        // chapter 恒 0、page 不更新，只能靠 scroll 定位）。
        // 兼容旧进度：仅 chapter > 0 时跳到对应章节。
        if (_mode == ReaderMode.scroll) {
          if (scroll != null) {
            setState(() {
              _scrollFraction = scroll.clamp(0.0, 1.0);
              _pageInChapter = 0;
            });
            // scroll_mode 通过 didUpdateWidget 消费 _scrollFraction 定位
            return;
          }
          if (chapter > 0 && chapter < _chapters.length) {
            _pendingRestore = true;
            _goToChapter(chapter);
            _pendingRestore = false;
          }
          return;
        }

        // 翻页模式：chapter > 0 跳到章节，page > 0 定位章节内页码
        if (chapter >= 0 && chapter < _chapters.length) {
          _pendingRestore = true;
          _pendingPage = page;
          if (chapter > 0) {
            _goToChapter(chapter);
          } else if (page > 0) {
            // 首章节有页内进度：触发一次同步以更新底栏百分比
            setState(() => _pageInChapter = page);
          }
          // 恢复流程结束：清空 _pendingRestore（保留 _pendingPage 在 state 中
          // 供 page_mode 通过 didUpdateWidget 消费；用户首次翻页后再清空）。
          _pendingRestore = false;
        }
      }
    } catch (_) {
      // 进度查询失败：从头阅读
    }
  }

  // ---------- 章节列表 ----------

  Future<void> _loadChapters() async {
    _pollTimer?.cancel();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ref
          .read(readerApiProvider)
          .novelChapters(widget.sourceId, widget.file.path);
      if (!mounted) return;
      if (res['ready'] == true) {
        final list = (res['chapters'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .map((e) => (
                  index: e['index'] as int? ?? 0,
                  title: e['title'] as String? ?? '',
                ))
            .toList();
        setState(() {
          _chapters = list;
          _loading = false;
          _indexing = false;
        });
        _ensureAround(_chapter);
        unawaited(_restoreProgress()); // 恢复上次阅读进度（6.4）
        return;
      }
      // 索引构建中：轮询
      if (_pollCount >= _pollMax) {
        setState(() {
          _loading = false;
          _indexing = false;
          _error = '章节索引构建超时，请点击重试';
        });
        return;
      }
      _pollCount++;
      setState(() => _indexing = true);
      _pollTimer = Timer(_pollInterval, _loadChapters);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  // ---------- 章节内容（缓存 + ±1 预加载） ----------

  void _ensureAround(int index) {
    _ensureChapter(index - 1);
    _ensureChapter(index);
    _ensureChapter(index + 1);
  }

  Future<void> _ensureChapter(int index, [int attempt = 0]) async {
    if (index < 0 || index >= _chapters.length) return;
    if (_contentCache.containsKey(index) || _loadingChapters.contains(index)) {
      return;
    }
    _loadingChapters.add(index);
    try {
      final res = await ref.read(readerApiProvider).novelContent(
            widget.sourceId,
            widget.file.path,
            index,
          );
      if (!mounted) return;
      if (res['ready'] != true) {
        // 与章节列表的竞态（索引刚过期重建等）：有限次延迟重试
        _loadingChapters.remove(index);
        if (attempt < 5) {
          unawaited(Future.delayed(_pollInterval, () {
            if (mounted) _ensureChapter(index, attempt + 1);
          }));
        }
        return;
      }
      setState(() {
        _contentCache[index] = res['content'] as String? ?? '';
        _loadingChapters.remove(index);
        if (index == _chapter) _contentError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingChapters.remove(index);
        // 预加载失败静默；当前章节失败显示错误
        if (index == _chapter) _contentError = '$e';
      });
    }
  }

  void _goToChapter(int index, {bool fromEnd = false}) {
    if (index < 0 || index >= _chapters.length) return;
    setState(() {
      _chapter = index;
      _chapterFromEnd = fromEnd;
      // 恢复流程：用 _pendingPage 初始化页码；用户主动切章：从首/末页开始。
      _pageInChapter = _pendingRestore ? (_pendingPage ?? 0) : 0;
      _contentError = null;
    });
    if (!_pendingRestore) {
      // 用户主动切章：清空 _pendingPage，下次 build 时 page_mode 用 0 初始化
      _pendingPage = null;
    }
    _ensureAround(index);
    _scheduleSave(); // 切章即落盘候选：1s 内若不再翻页则触发
  }

  void _retryContent() {
    setState(() => _contentError = null);
    _ensureChapter(_chapter);
  }

  String _chapterTitle(int index) =>
      (index >= 0 && index < _chapters.length) ? _chapters[index].title : '';

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    // 全局阅读设置（6.3）：字号/行距/主题/翻页模式
    final settings = ref.watch(readerSettingsProvider);
    _style = settings.style;
    _mode = settings.mode;
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: _style.background, // 阅读器独立背景色
      // 目录抽屉从右侧滑出（仅顶栏按钮开启，避免与翻页手势冲突）
      endDrawerEnableOpenDragGesture: false,
      endDrawer: ChapterDrawer(
        titles: [for (final c in _chapters) c.title],
        currentIndex: _chapter,
        onSelect: _goToChapter,
        style: _style,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildBody(),
          // 顶栏：返回 + 章节标题（轻触正文切换显隐）
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _chrome(_buildTopBar()),
          ),
          // 底栏：上/下一章 + 进度/设置（设置按钮位于中央底部，对齐漫画/视频播放器）
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _chrome(
              ReaderBottomBar(
                style: _style,
                progress: _progress,
                onPrevChapter: _chapter > 0
                    ? () => _goToChapter(_chapter - 1, fromEnd: true)
                    : null,
                onNextChapter: _chapter < _chapters.length - 1
                    ? () => _goToChapter(_chapter + 1)
                    : null,
                onOpenSettings: () => ReaderSettingsSheet.show(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 顶/底栏共用显隐过渡包装。
  Widget _chrome(Widget child) {
    return IgnorePointer(
      ignoring: !_chromeVisible,
      child: AnimatedOpacity(
        opacity: _chromeVisible ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: child,
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      color: _style.background,
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            IconButton(
              icon: Icon(LucideIcons.arrowLeft, color: _style.foreground),
              tooltip: '返回',
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: Text(
                widget.file.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: _style.foreground, fontSize: 15),
              ),
            ),
            IconButton(
              icon: Icon(LucideIcons.list, color: _style.foreground),
              tooltip: '目录',
              onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: _style.subtle,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _indexing ? '章节索引构建中...' : '加载中...',
              style: TextStyle(color: _style.subtle, fontSize: 13),
            ),
          ],
        ),
      );
    }
    if (_error != null) {
      return ReaderErrorView(
        message: _error!,
        style: _style,
        onRetry: () {
          _pollCount = 0;
          _loadChapters();
        },
      );
    }

    if (_mode == ReaderMode.scroll) {
      return SafeArea(
        child: ReaderScrollMode(
          key: ValueKey('scroll-${widget.file.path}'),
          initialChapter: _chapter,
          totalChapters: _chapters.length,
          chapterTitle: _chapterTitle,
          contentOf: (i) => _contentCache[i],
          ensureChapter: _ensureChapter,
          style: _style,
          // 恢复进度：_scrollFraction > 0 时定位到上次滚动位置
          initialFraction: _scrollFraction > 0 ? _scrollFraction : null,
          onToggleChrome: () =>
              setState(() => _chromeVisible = !_chromeVisible),
          onProgress: (f) {
            setState(() => _scrollFraction = f);
            _scheduleSave();
          },
        ),
      );
    }

    // 翻页模式
    final content = _contentCache[_chapter];
    if (_contentError != null && content == null) {
      return ReaderErrorView(
        message: _contentError!,
        style: _style,
        onRetry: _retryContent,
      );
    }
    if (content == null) {
      return Center(
        child: SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: _style.subtle,
          ),
        ),
      );
    }
    return SafeArea(
      child: ReaderPageMode(
        // 章节级 key：章节切换触发 page_mode 重建，initState 重新初始化 _page。
        // 恢复进度的 _pendingPage 通过 initialPage 传入，由 didUpdateWidget 消费。
        key: ValueKey(_chapter),
        content: content,
        header: _chapterTitle(_chapter),
        style: _style,
        startAtEnd: _chapterFromEnd,
        initialPage: _pendingPage,
        onPrevChapter:
            _chapter > 0 ? () => _goToChapter(_chapter - 1, fromEnd: true) : null,
        onNextChapter:
            _chapter < _chapters.length - 1 ? () => _goToChapter(_chapter + 1) : null,
        onToggleChrome: () => setState(() => _chromeVisible = !_chromeVisible),
        onPageProgress: (page, pageCount) {
          setState(() {
            _pageInChapter = page;
            _pageCount = pageCount;
            // 用户首次翻页后清空 _pendingPage，避免后续 build 中 initialPage
            // 干扰 page_mode（didUpdateWidget 会跳过 initialPage != _page 判断）。
            _pendingPage = null;
          });
          _scheduleSave();
        },
      ),
    );
  }
}

/// 阅读器错误视图：错误信息 + 重试按钮（TXT/EPUB 阅读器共用）。
class ReaderErrorView extends StatelessWidget {
  const ReaderErrorView({
    super.key,
    required this.message,
    required this.style,
    required this.onRetry,
  });

  final String message;
  final ReaderStyle style;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.circleAlert, size: 44, color: style.subtle),
            const SizedBox(height: 16),
            Text(
              '加载失败',
              style: TextStyle(
                color: style.foreground,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(color: style.subtle, fontSize: 12),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(LucideIcons.rotateCw, size: 16),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
