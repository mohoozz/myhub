import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/api/comic_api.dart';
import 'package:myhub_flutter/core/models/comic.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/data/repositories/progress_repository.dart';
import 'package:myhub_flutter/shared/providers/auth_state_provider.dart';
import 'package:myhub_flutter/shared/widgets/comic_reader/comic_settings.dart';
import 'package:myhub_flutter/shared/widgets/comic_reader/double_page.dart';
import 'package:myhub_flutter/shared/widgets/comic_reader/preloader.dart';
import 'package:myhub_flutter/shared/widgets/comic_reader/single_page.dart';
import 'package:myhub_flutter/shared/widgets/comic_reader/webtoon_mode.dart';

export 'package:myhub_flutter/shared/widgets/comic_reader/comic_settings.dart'
    show ComicReadingDirection, ComicReaderSettings, ComicViewMode;

/// 漫画阅读器主 Widget（TODO 7.1 数据加载 / 7.2 阅读模式）。
///
/// * 页列表加载 `GET /api/reader/comic/pages`（CBZ/ZIP 中央目录、
///   CBR/RAR 顺序扫描、EPUB 图集按 spine，后端统一抽象为页码 0..N-1）；
/// * 单页图片经 `GET /api/reader/comic/page?n=N` 加载，使用
///   `CachedNetworkImage` + JWT 请求头（磁盘缓存，URL 含页码天然分键）；
/// * 阅读模式：单页 single_page.dart / 双页 double_page.dart /
///   条漫 webtoon_mode.dart；未手动选择时横屏/宽屏自动双页；
/// * 预加载见 7.3，进度上报见 7.4。
class ComicReaderPage extends ConsumerStatefulWidget {
  const ComicReaderPage({
    super.key,
    required this.sourceId,
    required this.file,
  });

  /// 文件所属路径源 ID。
  final int sourceId;

  /// 漫画文件（cbz/cbr，或经后端嗅探判定的 zip/rar、图集型 epub）。
  final FileItem file;

  /// 以独立路由打开阅读器。
  static Future<void> open(
    BuildContext context, {
    required int sourceId,
    required FileItem file,
  }) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => ComicReaderPage(sourceId: sourceId, file: file),
      ),
    );
  }

  @override
  ConsumerState<ComicReaderPage> createState() => _ComicReaderPageState();
}

class _ComicReaderPageState extends ConsumerState<ComicReaderPage> {
  // 沉浸式纯黑背景下的文字/辅助色（与全局暗色色板一致）。
  static const Color _foreground = Color(0xFFE0E0E0);
  static const Color _subtle = Color(0xFF888888);

  // ---- 页列表 ----
  bool _loading = true;
  String? _error;
  List<ComicPage> _pages = const [];

  // ---- 浏览状态 ----
  int _current = 0;
  bool _chromeVisible = true;

  /// 图片请求头（JWT）。
  Map<String, String> _headers = const {};

  /// ±3 页预加载器（7.3），页列表就绪后创建。
  ComicPreloader? _preloader;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _preloader?.dispose();
    _saveProgress(); // 退出阅读器时上报页码进度（7.4）
    super.dispose();
  }

  // ---------- 阅读进度（7.4） ----------

  /// 上次阅读页码（0 起）；无记录 / 已读完 / 查询异常返回 null（从头阅读）。
  Future<int?> _lastProgress() async {
    try {
      final p = await ref
          .read(progressRepositoryProvider)
          .get(widget.sourceId, widget.file.path);
      if (p == null || p.finished) return null;
      if (p.progressJson.isNotEmpty) {
        final decoded = jsonDecode(p.progressJson);
        if (decoded is Map && decoded['page'] is num) {
          return (decoded['page'] as num).toInt();
        }
      }
    } catch (_) {
      // 进度查询失败：从头阅读
    }
    return null;
  }

  /// 保存当前页码进度：本地 drift + 后端双写（离线时待同步，F-502）。
  void _saveProgress() {
    if (_pages.isEmpty) return;
    unawaited(ref.read(progressRepositoryProvider).save(
          sourceId: widget.sourceId,
          filePath: widget.file.path,
          mediaType: 'comic',
          title: widget.file.name,
          progressJson: jsonEncode({'page': _current}),
          percent: (_current + 1) / _pages.length * 100,
        ));
  }

  Future<void> _init() async {
    // 图片不走 dio 拦截器，需自行携带 JWT
    final token = await const FlutterSecureStorage().read(
      key: kAccessTokenKey,
    );
    if (!mounted) return;
    _headers = {
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
    await _loadPages();
  }

  // ---------- 页列表 ----------

  Future<void> _loadPages() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 页列表与上次进度并行加载，一并生效——首次构建即定位到
      // 上次页码（7.4；进度查询失败静默，从头阅读）
      final res = await ref
          .read(comicApiProvider)
          .pages(widget.sourceId, widget.file.path);
      final savedPage = await _lastProgress();
      if (!mounted) return;
      final pages = ComicPages.fromJson(res).pages;
      setState(() {
        _loading = false;
        _pages = pages;
        if (pages.isEmpty) {
          _error = '未找到可阅读的漫画页';
        } else if (savedPage != null &&
            savedPage > 0 &&
            savedPage < pages.length) {
          _current = savedPage;
        }
      });
      if (pages.isNotEmpty) {
        // 预加载器与 ComicPageImage 共享同一 headers 实例（缓存命中）
        _preloader = ComicPreloader(
          pageCount: pages.length,
          urlOf: _pageUrl,
          headers: _headers,
        );
        // 初始页 ±3 预加载
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _preloader?.preloadAround(_current, context);
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  String _pageUrl(int page) => ref
      .read(comicApiProvider)
      .pageUrl(widget.sourceId, widget.file.path, page);

  /// 翻页统一回调：更新页码 + 触发 ±3 方向感知预加载（7.3）。
  void _onPageChanged(int page) {
    setState(() => _current = page);
    _preloader?.preloadAround(page, context);
  }

  /// 有效阅读模式：手动选择优先，否则横屏/宽屏自动双页。
  ComicViewMode _effectiveMode(ComicReaderSettings settings) {
    if (settings.viewMode != null) return settings.viewMode!;
    final size = MediaQuery.sizeOf(context);
    final landscapeOrWide = size.width > size.height || size.width >= 840;
    return landscapeOrWide ? ComicViewMode.double : ComicViewMode.single;
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(comicReaderSettingsProvider);
    final mode = _effectiveMode(settings);
    return Scaffold(
      backgroundColor: Colors.black, // 播放器/阅读器统一沉浸纯黑
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildBody(mode, settings),
          // 顶栏：返回 + 标题 + 页码（轻触画面切换显隐）
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _chrome(_buildTopBar(mode, settings)),
          ),
          // 底栏：阅读模式切换（7.2）
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _chrome(_buildModeSwitcher(mode)),
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

  Widget _buildBody(ComicViewMode mode, ComicReaderSettings settings) {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: _subtle,
              ),
            ),
            SizedBox(height: 16),
            Text('加载中...', style: TextStyle(color: _subtle, fontSize: 13)),
          ],
        ),
      );
    }
    if (_error != null) {
      return _ComicErrorView(message: _error!, onRetry: _loadPages);
    }

    // 模式切换时保留当前页（ValueKey 强制重建模式组件）
    final current = _current.clamp(0, _pages.length - 1);
    return KeyedSubtree(
      key: ValueKey(mode),
      child: switch (mode) {
        ComicViewMode.single => ComicSinglePageMode(
            pageCount: _pages.length,
            urlOf: _pageUrl,
            headers: _headers,
            initialPage: current,
            onPageChanged: _onPageChanged,
            onToggleChrome: () =>
                setState(() => _chromeVisible = !_chromeVisible),
          ),
        ComicViewMode.double => ComicDoublePageMode(
            pageCount: _pages.length,
            urlOf: _pageUrl,
            headers: _headers,
            direction: settings.effectiveDirection,
            initialPage: current,
            onPageChanged: _onPageChanged,
            onToggleChrome: () =>
                setState(() => _chromeVisible = !_chromeVisible),
          ),
        ComicViewMode.webtoon => ComicWebtoonMode(
            pageCount: _pages.length,
            urlOf: _pageUrl,
            headers: _headers,
            initialPage: current,
            onPageChanged: _onPageChanged,
            onToggleChrome: () =>
                setState(() => _chromeVisible = !_chromeVisible),
          ),
      },
    );
  }

  Widget _buildTopBar(ComicViewMode mode, ComicReaderSettings settings) {
    return Container(
      color: Colors.black,
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(LucideIcons.arrowLeft, color: _foreground),
              tooltip: '返回',
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: Text(
                widget.file.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _foreground, fontSize: 15),
              ),
            ),
            if (_pages.isNotEmpty)
              Text(
                '${_current + 1} / ${_pages.length}',
                style: const TextStyle(color: _subtle, fontSize: 13),
              ),
            // 双页阅读方向切换（日漫 rtl / 国漫 ltr）
            if (mode == ComicViewMode.double)
              IconButton(
                icon: Icon(
                  settings.effectiveDirection == ComicReadingDirection.rtl
                      ? LucideIcons.arrowRightToLine
                      : LucideIcons.arrowLeftToLine,
                  color: _foreground,
                  size: 20,
                ),
                tooltip: settings.effectiveDirection ==
                        ComicReadingDirection.rtl
                    ? '从右向左（日漫）'
                    : '从左向右',
                onPressed: () {
                  final next =
                      settings.effectiveDirection == ComicReadingDirection.rtl
                          ? ComicReadingDirection.ltr
                          : ComicReadingDirection.rtl;
                  ref
                      .read(comicReaderSettingsProvider.notifier)
                      .setDirection(next);
                },
              ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }

  /// 底部悬浮模式切换：单页 / 双页 / 条漫。
  Widget _buildModeSwitcher(ComicViewMode mode) {
    return SafeArea(
      top: false,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: SegmentedButton<ComicViewMode>(
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(
              backgroundColor: const Color(0xCC1A1A1A),
              foregroundColor: _subtle,
              selectedForegroundColor: Colors.white,
              selectedBackgroundColor: const Color(0xFF2563EB),
              side: const BorderSide(color: Color(0xFF2A2A2A)),
              visualDensity: VisualDensity.compact,
            ),
            segments: const [
              ButtonSegment(
                value: ComicViewMode.single,
                icon: Icon(LucideIcons.fileImage, size: 18),
                label: Text('单页'),
              ),
              ButtonSegment(
                value: ComicViewMode.double,
                icon: Icon(LucideIcons.columns2, size: 18),
                label: Text('双页'),
              ),
              ButtonSegment(
                value: ComicViewMode.webtoon,
                icon: Icon(LucideIcons.rows3, size: 18),
                label: Text('条漫'),
              ),
            ],
            selected: {mode},
            onSelectionChanged: (selected) {
              ref
                  .read(comicReaderSettingsProvider.notifier)
                  .setViewMode(selected.first);
            },
          ),
        ),
      ),
    );
  }
}

/// 错误视图：错误信息 + 重试按钮。
class _ComicErrorView extends StatelessWidget {
  const _ComicErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              LucideIcons.circleAlert,
              size: 44,
              color: Color(0xFF888888),
            ),
            const SizedBox(height: 16),
            const Text(
              '加载失败',
              style: TextStyle(
                color: Color(0xFFE0E0E0),
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
              style: const TextStyle(color: Color(0xFF888888), fontSize: 12),
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
