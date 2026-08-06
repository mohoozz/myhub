import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/api/reader_api.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/data/repositories/progress_repository.dart';
import 'package:myhub_flutter/shared/widgets/comic_reader/comic_reader.dart';
import 'package:myhub_flutter/shared/widgets/novel_reader/chapter_drawer.dart';
import 'package:myhub_flutter/shared/widgets/novel_reader/epub_html.dart';
import 'package:myhub_flutter/shared/widgets/novel_reader/epub_page_mode.dart';
import 'package:myhub_flutter/shared/widgets/novel_reader/epub_scroll_mode.dart';
import 'package:myhub_flutter/shared/widgets/novel_reader/novel_reader.dart';

/// EPUB 阅读器主 Widget（TODO 6.2）。
///
/// * 元数据加载：书名、作者、封面、目录（`GET /api/reader/epub/meta`）；
/// * 章节 XHTML 经自建轻量解析器渲染为富文本（见 epub_html.dart），
///   图片/CSS 等静态资源经 `GET /api/reader/epub/resource` 按 href 加载；
/// * 翻页/滚动模式与 TXT 共用阅读器壳交互（epub_page_mode / epub_scroll_mode）；
/// * 图集型 EPUB（is_comic）由漫画阅读器承接（第 7 章）。
class EpubReaderPage extends ConsumerStatefulWidget {
  const EpubReaderPage({
    super.key,
    required this.sourceId,
    required this.file,
  });

  /// 文件所属路径源 ID。
  final int sourceId;

  /// EPUB 文件。
  final FileItem file;

  /// 以独立路由打开阅读器。
  static Future<void> open(
    BuildContext context, {
    required int sourceId,
    required FileItem file,
  }) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => EpubReaderPage(sourceId: sourceId, file: file),
      ),
    );
  }

  @override
  ConsumerState<EpubReaderPage> createState() => _EpubReaderPageState();
}

class _EpubReaderPageState extends ConsumerState<EpubReaderPage> {
  /// 当前阅读样式/模式（来自全局设置，build 时刷新；仅用于视图构建）。
  late ReaderStyle _style;
  late ReaderMode _mode;

  /// 已解析章节所依据的样式签名（字号/行距/主题），变化时清空缓存重解析。
  String _styleSignature = '';

  // ---- 元数据 ----
  bool _loading = true;
  String? _error;
  String _title = '';
  String _author = '';
  String? _coverId;
  bool _isComic = false;
  List<({String title, String href})> _toc = const [];

  /// 是否已进入阅读（false = 封面/信息页）。
  bool _started = false;

  // ---- 章节内容缓存（富文本原子） ----
  int _chapter = 0;
  bool _chapterFromEnd = false;
  final Map<int, List<RichAtom>> _contentCache = {};
  final Set<int> _loadingChapters = {};
  String? _contentError;

  // ---- 阅读进度（6.4） ----
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  int _pageInChapter = 0;
  int _pageCount = 1;
  double _scrollFraction = 0;

  // ---- 静态资源字节缓存 ----
  final Map<String, Future<Uint8List>> _resourceCache = {};

  // ---- 顶栏显隐 ----
  bool _chromeVisible = true;

  @override
  void initState() {
    super.initState();
    _loadMeta();
  }

  @override
  void dispose() {
    _saveProgress(); // 退出阅读器时保存进度（6.4）
    super.dispose();
  }

  // ---------- 阅读进度（6.4） ----------

  /// 全书进度 0.0 ~ 1.0。
  double get _progress {
    if (_toc.isEmpty) return 0;
    if (_mode == ReaderMode.scroll) {
      return _scrollFraction.clamp(0.0, 1.0);
    }
    return ((_chapter + (_pageInChapter + 1) / _pageCount) / _toc.length)
        .clamp(0.0, 1.0);
  }

  /// 保存当前进度：本地 drift + 后端双写（离线时待同步，F-502）。
  void _saveProgress() {
    if (!_started || _isComic || _toc.isEmpty) return;
    // 滚动模式按滚动比例折算章节
    final chapter = _mode == ReaderMode.scroll
        ? (_scrollFraction * (_toc.length - 1)).round()
        : _chapter;
    unawaited(ref.read(progressRepositoryProvider).save(
          sourceId: widget.sourceId,
          filePath: widget.file.path,
          mediaType: 'novel',
          title: _title.isNotEmpty ? _title : widget.file.name,
          progressJson:
              jsonEncode({'chapter': chapter, 'page': _pageInChapter}),
          percent: _progress * 100,
        ));
  }

  /// 恢复上次阅读进度：有进度则跳过封面页直接续读。
  Future<void> _restoreProgress() async {
    try {
      final p = await ref
          .read(progressRepositoryProvider)
          .get(widget.sourceId, widget.file.path);
      if (p == null || p.finished) return;
      if (p.progressJson.isNotEmpty) {
        final decoded = jsonDecode(p.progressJson);
        if (decoded is Map && decoded['chapter'] is num) {
          final chapter = (decoded['chapter'] as num).toInt();
          if (chapter > 0 && chapter < _toc.length && mounted) {
            setState(() {
              _chapter = chapter;
              _started = true;
            });
            _ensureAround(chapter);
          }
        }
      }
    } catch (_) {
      // 进度查询失败：从封面页开始
    }
  }

  /// 图集型 EPUB 转交漫画阅读器（替换当前路由，返回时直接退出）。
  void _openInComicReader() {
    Navigator.of(context, rootNavigator: true).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => ComicReaderPage(
          sourceId: widget.sourceId,
          file: widget.file,
        ),
      ),
    );
  }

  // ---------- 元数据 ----------

  Future<void> _loadMeta() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ref
          .read(readerApiProvider)
          .epubMeta(widget.sourceId, widget.file.path);
      if (!mounted) return;
      // 目录按 href 去重（nav 中同一文件的锚点条目只保留第一个）
      final seen = <String>{};
      final toc = <({String title, String href})>[];
      for (final e in (res['toc'] as List<dynamic>? ?? [])) {
        if (e is! Map<String, dynamic>) continue;
        final href = e['href'] as String? ?? '';
        if (href.isEmpty || !seen.add(href)) continue;
        toc.add((
          title: (e['title'] as String? ?? '').trim(),
          href: href,
        ));
      }
      setState(() {
        _title = res['title'] as String? ?? '';
        _author = res['author'] as String? ?? '';
        final cover = res['cover_id'] as String? ?? '';
        _coverId = cover.isEmpty ? null : cover;
        _isComic = res['is_comic'] == true;
        _toc = toc;
        _loading = false;
      });
      unawaited(_restoreProgress()); // 恢复上次阅读进度（6.4）
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

  Future<void> _ensureChapter(int index) async {
    if (index < 0 || index >= _toc.length) return;
    if (_contentCache.containsKey(index) || _loadingChapters.contains(index)) {
      return;
    }
    _loadingChapters.add(index);
    try {
      final bytes = await ref.read(readerApiProvider).epubChapter(
            widget.sourceId,
            widget.file.path,
            _toc[index].href,
          );
      if (!mounted) return;
      final html = utf8.decode(bytes, allowMalformed: true);
      final atoms = EpubHtmlParser(
        baseStyle: _style.textStyle,
        chapterHref: _toc[index].href,
      ).parse(html);
      setState(() {
        _contentCache[index] = atoms;
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
    if (index < 0 || index >= _toc.length) return;
    setState(() {
      _chapter = index;
      _chapterFromEnd = fromEnd;
      _pageInChapter = 0;
      _contentError = null;
    });
    _ensureAround(index);
  }

  void _retryContent() {
    setState(() => _contentError = null);
    _ensureChapter(_chapter);
  }

  String _chapterTitle(int index) =>
      (index >= 0 && index < _toc.length) ? _toc[index].title : '';

  // ---------- 静态资源 ----------

  /// 资源字节（封面/章节图片），按 href 缓存。
  Future<Uint8List> _resourceBytes(String id) {
    return _resourceCache.putIfAbsent(
      id,
      () => ref
          .read(readerApiProvider)
          .epubResource(widget.sourceId, widget.file.path, id)
          .then((r) => r.$1),
    );
  }

  /// 章节内联图片（固定尺寸盒内 contain 显示）。
  Widget _buildImage(ImgAtom atom) {
    return FutureBuilder<Uint8List>(
      future: _resourceBytes(atom.resourceId),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
            child: Icon(LucideIcons.imageOff, size: 32, color: _style.subtle),
          );
        }
        if (!snap.hasData) {
          return Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: _style.subtle,
              ),
            ),
          );
        }
        return Image.memory(snap.data!, fit: BoxFit.contain);
      },
    );
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    // 全局阅读设置（6.3）：字号/行距/主题/翻页模式
    final settings = ref.watch(readerSettingsProvider);
    // EPUB 章节原子在解析时固化文本样式：样式签名变化需清缓存重解析
    final signature =
        '${settings.fontSize}/${settings.lineHeight}/${settings.theme.name}';
    if (signature != _styleSignature) {
      _styleSignature = signature;
      if (_contentCache.isNotEmpty) {
        _contentCache.clear();
        _ensureAround(_chapter);
      }
    }
    _style = settings.style;
    _mode = settings.mode;
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: _style.background, // 阅读器独立背景色
      // 目录抽屉从右侧滑出（仅顶栏按钮开启，避免与翻页手势冲突）
      endDrawerEnableOpenDragGesture: false,
      endDrawer: ChapterDrawer(
        titles: [for (final t in _toc) t.title],
        currentIndex: _chapter,
        onSelect: (i) {
          // 封面页选章即开始阅读
          if (!_started) {
            setState(() => _started = true);
          }
          _goToChapter(i);
        },
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
          // 底栏：上/下一章 + 进度（6.4，封面页不显示）
          if (_started)
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
                  onNextChapter: _chapter < _toc.length - 1
                      ? () => _goToChapter(_chapter + 1)
                      : null,
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
    final chapterTitle = _started ? _chapterTitle(_chapter) : '';
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
                chapterTitle.isNotEmpty
                    ? chapterTitle
                    : (_title.isNotEmpty ? _title : widget.file.name),
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
            IconButton(
              icon: Icon(LucideIcons.settings2, color: _style.foreground),
              tooltip: '阅读设置',
              onPressed: () => ReaderSettingsSheet.show(context),
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
    if (_error != null) {
      return ReaderErrorView(
        message: _error!,
        style: _style,
        onRetry: _loadMeta,
      );
    }
    // 图集型 EPUB → 漫画阅读器（第 7 章）
    if (_isComic) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.images, size: 44, color: _style.subtle),
              const SizedBox(height: 16),
              Text(
                '该 EPUB 为图集/漫画',
                style: TextStyle(
                  color: _style.foreground,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '请使用漫画阅读器获得更佳体验',
                style: TextStyle(color: _style.subtle, fontSize: 12),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _openInComicReader,
                icon: const Icon(LucideIcons.bookOpen, size: 16),
                label: const Text('在漫画阅读器中打开'),
              ),
            ],
          ),
        ),
      );
    }
    if (_toc.isEmpty) {
      return ReaderErrorView(
        message: 'EPUB 缺少目录',
        style: _style,
        onRetry: _loadMeta,
      );
    }
    if (!_started) {
      return _buildStartView();
    }

    if (_mode == ReaderMode.scroll) {
      return SafeArea(
        child: EpubScrollMode(
          key: ValueKey('epub-scroll-${widget.file.path}'),
          initialChapter: _chapter,
          totalChapters: _toc.length,
          chapterTitle: _chapterTitle,
          contentOf: (i) => _contentCache[i],
          ensureChapter: _ensureChapter,
          style: _style,
          imageBuilder: _buildImage,
          onToggleChrome: () =>
              setState(() => _chromeVisible = !_chromeVisible),
          onProgress: (f) => setState(() => _scrollFraction = f),
        ),
      );
    }

    // 翻页模式
    final atoms = _contentCache[_chapter];
    if (_contentError != null && atoms == null) {
      return ReaderErrorView(
        message: _contentError!,
        style: _style,
        onRetry: _retryContent,
      );
    }
    if (atoms == null) {
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
      child: EpubPageMode(
        key: ValueKey(_chapter),
        atoms: atoms,
        header: _chapterTitle(_chapter),
        style: _style,
        imageBuilder: _buildImage,
        startAtEnd: _chapterFromEnd,
        onPrevChapter: _chapter > 0
            ? () => _goToChapter(_chapter - 1, fromEnd: true)
            : null,
        onNextChapter: _chapter < _toc.length - 1
            ? () => _goToChapter(_chapter + 1)
            : null,
        onToggleChrome: () => setState(() => _chromeVisible = !_chromeVisible),
        onPageProgress: (page, pageCount) {
          setState(() {
            _pageInChapter = page;
            _pageCount = pageCount;
          });
        },
      ),
    );
  }

  /// 封面/信息页：封面图 + 书名 + 作者 + 开始阅读。
  Widget _buildStartView() {
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_coverId != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: 200,
                      maxHeight: 280,
                    ),
                    child: FutureBuilder<Uint8List>(
                      future: _resourceBytes(_coverId!),
                      builder: (context, snap) {
                        if (!snap.hasData) {
                          return const SizedBox(
                            width: 200,
                            height: 280,
                          );
                        }
                        return Image.memory(
                          snap.data!,
                          fit: BoxFit.contain,
                        );
                      },
                    ),
                  ),
                )
              else
                Icon(LucideIcons.bookOpen, size: 64, color: _style.subtle),
              const SizedBox(height: 24),
              Text(
                _title.isNotEmpty ? _title : widget.file.name,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _style.foreground,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  height: 1.4,
                ),
              ),
              if (_author.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  _author,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: _style.subtle, fontSize: 14),
                ),
              ],
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: () {
                  setState(() => _started = true);
                  _ensureAround(_chapter);
                },
                icon: const Icon(LucideIcons.bookOpen, size: 16),
                label: const Text('开始阅读'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
