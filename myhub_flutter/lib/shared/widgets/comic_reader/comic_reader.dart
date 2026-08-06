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
import 'package:myhub_flutter/features/reading/providers/reading_provider.dart';
import 'package:myhub_flutter/shared/providers/auth_state_provider.dart';
import 'package:myhub_flutter/shared/widgets/comic_reader/comic_settings.dart';
import 'package:myhub_flutter/shared/widgets/comic_reader/double_page.dart';
import 'package:myhub_flutter/shared/widgets/comic_reader/preloader.dart';
import 'package:myhub_flutter/shared/widgets/comic_reader/single_page.dart';
import 'package:myhub_flutter/shared/widgets/comic_reader/webtoon_mode.dart';
import 'package:myhub_flutter/shared/widgets/window_title_bar.dart';

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

  /// 进度条拖动页码跳转通知（值为页码 0 起；-1 表示无跳转）。
  final ValueNotifier<int> _jumpTo = ValueNotifier(-1);

  /// 桌面端沉浸式标题栏开关（阅读器纯黑背景，白底标题栏会突兀）。
  StateController<bool>? _immersiveTitleBar;

  /// 翻页后防抖保存进度的定时器：阅读中持续落盘（对齐视频 5 秒
  /// 节流上报），关窗/强杀等未走 dispose 的场景也不丢进度。
  Timer? _saveDebounce;

  /// 条漫模式实时页内偏移（0~1）：长页内页码不变时的页内漂移量。
  double _pageOffset = 0;

  /// 条漫模式已实测的每页宽高比（页码 → 高/宽），随进度一并
  /// 持久化：与渲染宽度无关、跨会话恒定，重开时可精确重建页高。
  final Map<int, double> _aspects = {};

  /// 服务端下发的每页宽高比（页码 → 高/宽，ZIP/CBZ、EPUB 精确值）。
  final Map<int, double> _serverAspects = {};

  /// 上次保存的条漫进度（仅首次构建恢复用，消费后置空，
  /// 避免阅读中切换模式时误用旧值）。
  double? _savedPageOffset;
  Map<int, double>? _savedAspects;

  /// 旧版进度保存的全局滚动比例（回退用）。
  double? _savedFraction;

  /// 当前生效的阅读模式（保存进度时决定是否附带条漫页内偏移）。
  ComicViewMode? _lastMode;

  @override
  void initState() {
    super.initState();
    if (isDesktopPlatform) {
      // initState 处于组件树锁定阶段，延迟到帧后修改 provider
      _immersiveTitleBar = ref.read(immersiveTitleBarProvider.notifier);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _immersiveTitleBar?.state = true;
      });
    }
    _init();
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _preloader?.dispose();
    _jumpTo.dispose();
    // 退出阅读器，标题栏恢复主题色（dispose 处于锁定阶段，延迟到帧后）
    if (isDesktopPlatform) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _immersiveTitleBar?.state = false;
      });
    }
    unawaited(_saveProgress()); // 退出阅读器时补报页码进度（7.4）
    super.dispose();
  }

  // ---------- 阅读进度（7.4） ----------

  /// 上次阅读进度：页码（0 起）+ 条漫页内偏移 + 每页宽高比表
  /// （均可为 null；fraction 为旧版记录的全局滚动比例，仅回退用）；
  /// 无记录 / 已读完 / 查询异常返回 null（从头阅读）。
  Future<
      ({
        int page,
        double? pageOffset,
        Map<int, double>? aspects,
        double? fraction,
      })?> _lastProgress() async {
    try {
      final p = await ref
          .read(progressRepositoryProvider)
          .get(widget.sourceId, widget.file.path);
      if (p == null || p.finished) return null;
      if (p.progressJson.isNotEmpty) {
        final decoded = jsonDecode(p.progressJson);
        if (decoded is Map && decoded['page'] is num) {
          final pageOffset = decoded['pageOffset'];
          final fraction = decoded['fraction'];
          // 宽高比表：下标即页码，0 表示未知
          Map<int, double>? aspects;
          final rawAspects = decoded['aspects'];
          if (rawAspects is List) {
            aspects = {};
            for (var i = 0; i < rawAspects.length; i++) {
              final v = rawAspects[i];
              if (v is num && v > 0) aspects[i] = v.toDouble();
            }
          }
          return (
            page: (decoded['page'] as num).toInt(),
            pageOffset: pageOffset is num ? pageOffset.toDouble() : null,
            aspects: aspects,
            fraction: fraction is num ? fraction.toDouble() : null,
          );
        }
      }
    } catch (_) {
      // 进度查询失败：从头阅读
    }
    return null;
  }

  /// 保存当前页码进度：本地 drift + 后端双写（离线时待同步，F-502）。
  Future<void> _saveProgress() async {
    if (_pages.isEmpty) return;
    // 条漫模式附带页内偏移（长页页内漂移量）与每页宽高比表
    // （跨会话精确重建滚动位置），百分比含页内偏移更精确；
    // 其他模式仅保存页码
    final webtoon = _lastMode == ComicViewMode.webtoon;
    try {
      await ref.read(progressRepositoryProvider).save(
            sourceId: widget.sourceId,
            filePath: widget.file.path,
            mediaType: 'comic',
            title: widget.file.name,
            progressJson: jsonEncode({
              'page': _current,
              if (webtoon) ...{
                'pageOffset': _pageOffset,
                'aspects': List.generate(
                  _pages.length,
                  (i) => _aspects[i] ?? 0,
                ),
              },
            }),
            percent: webtoon
                ? ((_current + _pageOffset) / _pages.length * 100)
                    .clamp(0.0, 100.0)
                : (_current + 1) / _pages.length * 100,
          );
      // 阅读中保存后刷新"正在阅读"列表（dispose 中调用时 mounted=false，
      // 跳过失效操作，避免使用已销毁的 ref）
      if (mounted) ref.invalidate(readingListProvider);
    } catch (_) {
      // 进度保存失败静默，不打断阅读
    }
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
      final saved = await _lastProgress();
      if (!mounted) return;
      final pages = ComicPages.fromJson(res).pages;
      setState(() {
        _loading = false;
        _pages = pages;
        // 服务端下发的每页宽高比（ZIP/CBZ、EPUB 精确值，RAR 无），
        // 叠加在本地保存的实测值之上（服务端数据为准）
        for (final page in pages) {
          if (page.width > 0 && page.height > 0) {
            _serverAspects[page.index] = page.height / page.width;
          }
        }
        // 本地实测宽高比表继承上次保存值 + 服务端精确值（服务端
        // 为准），避免每次保存只保留本次会话测量值导致表退化
        final savedAspects = saved?.aspects;
        if (savedAspects != null) _aspects.addAll(savedAspects);
        _aspects.addAll(_serverAspects);
        if (pages.isEmpty) {
          _error = '未找到可阅读的漫画页';
        } else if (saved != null &&
            saved.page > 0 &&
            saved.page < pages.length) {
          _current = saved.page;
          _savedPageOffset = saved.pageOffset;
          _savedAspects = saved.aspects;
          _savedFraction = saved.fraction;
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

  /// 翻页统一回调：更新页码 + 触发 ±3 方向感知预加载（7.3），
  /// 并防抖保存阅读进度（7.4：持续落盘，避免仅退出时保存导致
  /// 关窗/强杀场景进度丢失）。
  void _onPageChanged(int page) {
    setState(() => _current = page);
    _preloader?.preloadAround(page, context);
    _scheduleSave();
  }

  /// 条漫页内偏移回调：长页内页码不变也持续更新页内漂移量并
  /// 防抖保存，保证精确进度不丢失。
  void _onWebtoonPageOffset(double offset) {
    _pageOffset = offset;
    _scheduleSave();
  }

  /// 条漫页宽高比实测回调：积累到本地表，随进度一并持久化。
  void _onWebtoonAspect(int page, double aspect) {
    _aspects[page] = aspect;
  }

  /// 防抖保存进度（滚动/翻页停止 1 秒后落盘）。
  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 1), _saveProgress);
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
          // 底栏：可拖动进度条 + 阅读模式切换（7.2）
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _chrome(
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_pages.isNotEmpty) _buildSeekBar(),
                  _buildModeSwitcher(mode),
                ],
              ),
            ),
          ),
          // 沉浸阅读（控制栏隐藏）时的细进度条
          if (_pages.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                ignoring: _chromeVisible,
                child: AnimatedOpacity(
                  opacity: _chromeVisible ? 0 : 1,
                  duration: const Duration(milliseconds: 200),
                  child: LinearProgressIndicator(
                    value: (_current + 1) / _pages.length,
                    minHeight: 3,
                    backgroundColor: const Color(0x26FFFFFF),
                    valueColor:
                        const AlwaysStoppedAnimation(Color(0xFF2563EB)),
                  ),
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
    _lastMode = mode;
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
            jumpTo: _jumpTo,
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
            jumpTo: _jumpTo,
          ),
        ComicViewMode.webtoon => ComicWebtoonMode(
            pageCount: _pages.length,
            urlOf: _pageUrl,
            headers: _headers,
            initialPage: current,
            initialPageOffset: _consumeSavedPageOffset(),
            initialAspects: _mergedInitialAspects(),
            initialFraction: _consumeSavedFraction(),
            onPageChanged: _onPageChanged,
            onPageOffset: _onWebtoonPageOffset,
            onAspectMeasured: _onWebtoonAspect,
            onToggleChrome: () =>
                setState(() => _chromeVisible = !_chromeVisible),
            jumpTo: _jumpTo,
          ),
      },
    );
  }

  // 以下三个取值方法均为一次性消费：仅用于打开阅读器时的首次
  // 恢复，避免阅读中切换到条漫模式时误用旧值。

  double? _consumeSavedPageOffset() {
    final offset = _savedPageOffset;
    _savedPageOffset = null;
    return offset;
  }

  /// 条漫初始宽高比表：本地保存的实测值叠加服务端精确值
  /// （服务端为准；一次性消费本地保存值）。
  Map<int, double>? _mergedInitialAspects() {
    final saved = _savedAspects;
    _savedAspects = null;
    if (saved == null && _serverAspects.isEmpty) return null;
    return {...?saved, ..._serverAspects};
  }

  double? _consumeSavedFraction() {
    final fraction = _savedFraction;
    _savedFraction = null;
    return fraction;
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

  /// 可拖动阅读进度条（控制栏可见时显示）：拖动快速跳转页码，
  /// 目标页由模式组件立即定位并经 onPageChanged 触发 ±3 预加载。
  Widget _buildSeekBar() {
    final total = _pages.length;
    final page = (_current + 1).clamp(1, total);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Text(
              '$page',
              style: const TextStyle(color: _subtle, fontSize: 12),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 12),
                  activeTrackColor: const Color(0xFF2563EB),
                  inactiveTrackColor: const Color(0x26FFFFFF),
                  thumbColor: Colors.white,
                ),
                child: Slider(
                  value: page.toDouble(),
                  min: 1,
                  max: total.toDouble(),
                  divisions: total > 1 ? total - 1 : null,
                  label: '$page',
                  onChanged: (v) {
                    final target = v.round() - 1;
                    if (target == _current) return;
                    setState(() => _current = target);
                    _jumpTo.value = target;
                  },
                ),
              ),
            ),
            Text(
              '$total',
              style: const TextStyle(color: _subtle, fontSize: 12),
            ),
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
