import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/api/file_api.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/shared/providers/auth_headers_provider.dart';
import 'package:myhub_flutter/shared/widgets/window_title_bar.dart';

/// 纯图片文件预览页（与漫画阅读器区分开）。
///
/// * 接收同目录图片列表 [images] 与起始下标 [initialIndex]，支持
///   左右滑动 / 点击分区 / 键盘方向键 / 浮动按钮切换上一张、下一张；
/// * [images] 为空（收藏页、正在阅读页等无列表场景）时仅展示单张
///   图片，隐藏切换按钮与分区翻页；
/// * 原图经 `GET /api/files/image` 加载（CachedNetworkImage 磁盘缓存，
///   URL 含 path 天然分键），非 dio 请求自动附带 JWT。
class ImagePreviewPage extends ConsumerStatefulWidget {
  const ImagePreviewPage({
    super.key,
    required this.sourceId,
    required this.file,
    this.images = const [],
    this.initialIndex = 0,
  });

  /// 文件所属路径源 ID。
  final int sourceId;

  /// 当前展示的图片文件。
  final FileItem file;

  /// 同目录下的全部图片（按浏览顺序）；为空时仅显示 [file] 一张。
  final List<FileItem> images;

  /// [images] 中的起始下标（打开时的当前图片）。
  final int initialIndex;

  /// 以独立路由打开预览页。
  static Future<void> open(
    BuildContext context, {
    required int sourceId,
    required FileItem file,
    List<FileItem> images = const [],
    int initialIndex = 0,
  }) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => ImagePreviewPage(
          sourceId: sourceId,
          file: file,
          images: images,
          initialIndex: initialIndex,
        ),
      ),
    );
  }

  @override
  ConsumerState<ImagePreviewPage> createState() => _ImagePreviewPageState();
}

class _ImagePreviewPageState extends ConsumerState<ImagePreviewPage> {
  // 沉浸式纯黑背景下的文字/辅助色（与漫画阅读器一致）。
  static const Color _foreground = Color(0xFFE0E0E0);
  static const Color _subtle = Color(0xFF888888);

  late final List<FileItem> _images;
  late final PageController _controller;
  final TransformationController _zoom = TransformationController();
  late int _current;

  bool _chromeVisible = true;
  bool _zoomed = false;

  /// 桌面端沉浸式标题栏开关（纯黑背景，白底标题栏会突兀）。
  StateController<bool>? _immersiveTitleBar;

  /// 是否可切换（列表多于 1 张）。
  bool get _canNavigate => _images.length > 1;

  @override
  void initState() {
    super.initState();
    // 列表为空时以当前文件作为唯一一张
    _images = widget.images.isEmpty ? [widget.file] : widget.images;
    _current = widget.initialIndex.clamp(0, _images.length - 1);
    _controller = PageController(initialPage: _current);
    _zoom.addListener(_onZoomChanged);
    if (isDesktopPlatform) {
      // initState 处于组件树锁定阶段，延迟到帧后修改 provider
      _immersiveTitleBar = ref.read(immersiveTitleBarProvider.notifier);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _immersiveTitleBar?.state = true;
      });
    }
  }

  @override
  void dispose() {
    _zoom.dispose();
    _controller.dispose();
    // 退出预览，标题栏恢复主题色（dispose 处于锁定阶段，延迟到帧后）
    if (isDesktopPlatform) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _immersiveTitleBar?.state = false;
      });
    }
    super.dispose();
  }

  String _urlOf(FileItem item) =>
      ref.read(fileApiProvider).imageUrl(widget.sourceId, item.path);

  void _onZoomChanged() {
    final zoomed = _zoom.value.getMaxScaleOnAxis() > 1.001;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  void _goTo(int index) {
    if (!_controller.hasClients) return;
    final target = index.clamp(0, _images.length - 1);
    if (target == _current) return;
    _zoom.value = Matrix4.identity(); // 切换图片时还原缩放
    _controller.animateToPage(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _next() => _goTo(_current + 1);

  void _prev() => _goTo(_current - 1);

  // ---------- 点击分区 ----------

  void _onTapUp(TapUpDetails details) {
    if (!_canNavigate) {
      setState(() => _chromeVisible = !_chromeVisible);
      return;
    }
    final width = context.size?.width ?? 0;
    if (width <= 0) {
      setState(() => _chromeVisible = !_chromeVisible);
      return;
    }
    final fraction = details.localPosition.dx / width;
    if (fraction < 0.25) {
      _prev();
    } else if (fraction > 0.75) {
      _next();
    } else {
      setState(() => _chromeVisible = !_chromeVisible);
    }
  }

  // ---------- 键盘 ----------

  Map<ShortcutActivator, VoidCallback> get _shortcuts => {
        const SingleActivator(LogicalKeyboardKey.arrowRight): _next,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): _prev,
        const SingleActivator(LogicalKeyboardKey.arrowDown): _next,
        const SingleActivator(LogicalKeyboardKey.arrowUp): _prev,
        const SingleActivator(LogicalKeyboardKey.pageDown): _next,
        const SingleActivator(LogicalKeyboardKey.pageUp): _prev,
        const SingleActivator(LogicalKeyboardKey.space): _next,
      };

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    final headers = ref.watch(authHeadersProvider).valueOrNull ?? const {};
    return Scaffold(
      backgroundColor: Colors.black, // 预览器统一沉浸纯黑
      body: CallbackShortcuts(
        bindings: _shortcuts,
        child: Focus(
          autofocus: true,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildBody(headers),
              // 顶栏：返回 + 文件名 + 页码（轻触画面切换显隐）
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _chrome(_buildTopBar()),
              ),
              // 左右浮动切换按钮（仅多图时显示）
              if (_canNavigate) ...[
                Positioned(
                  left: 12,
                  top: 0,
                  bottom: 0,
                  child: Center(child: _chrome(_navButton(isNext: false))),
                ),
                Positioned(
                  right: 12,
                  top: 0,
                  bottom: 0,
                  child: Center(child: _chrome(_navButton(isNext: true))),
                ),
              ],
            ],
          ),
        ),
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

  Widget _buildBody(Map<String, String> headers) {
    return GestureDetector(
      onTapUp: _onTapUp,
      child: PageView.builder(
        controller: _controller,
        // 预构建相邻页，滑动时图片提前开始加载
        allowImplicitScrolling: true,
        itemCount: _images.length,
        onPageChanged: (i) => setState(() {
          _current = i;
          _zoom.value = Matrix4.identity(); // 滑动切换也还原缩放
        }),
        itemBuilder: (context, i) {
          final item = _images[i];
          return InteractiveViewer(
            transformationController: _zoom,
            maxScale: 5,
            // 未缩放时横向拖拽交给 PageView 翻页，缩放后才平移浏览
            panEnabled: _zoomed,
            child: Center(
              child: CachedNetworkImage(
                imageUrl: _urlOf(item),
                httpHeaders: headers,
                fit: BoxFit.contain,
                fadeInDuration: const Duration(milliseconds: 150),
                placeholder: (context, _) => const _ImagePlaceholder(),
                errorWidget: (context, _, _) => const _ImageError(),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTopBar() {
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
                _images[_current].name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _foreground, fontSize: 15),
              ),
            ),
            Text(
              '${_current + 1} / ${_images.length}',
              style: const TextStyle(color: _subtle, fontSize: 13),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }

  /// 上一张 / 下一张浮动按钮（首尾禁用）。
  Widget _navButton({required bool isNext}) {
    final atEdge = isNext ? _current >= _images.length - 1 : _current <= 0;
    return IconButton(
      icon: Icon(
        isNext ? LucideIcons.chevronRight : LucideIcons.chevronLeft,
        color: Colors.white,
        size: 30,
      ),
      tooltip: isNext ? '下一张' : '上一张',
      onPressed: atEdge ? null : (isNext ? _next : _prev),
      style: IconButton.styleFrom(
        backgroundColor: const Color(0x66000000),
        disabledBackgroundColor: const Color(0x22000000),
        disabledForegroundColor: const Color(0x44FFFFFF),
      ),
    );
  }
}

/// 图片加载中的占位（居中加载圈）。
class _ImagePlaceholder extends StatelessWidget {
  const _ImagePlaceholder();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 48,
      height: 48,
      child: CircularProgressIndicator(
        strokeWidth: 2.5,
        color: Color(0xFF888888),
      ),
    );
  }
}

/// 图片加载失败视图。
class _ImageError extends StatelessWidget {
  const _ImageError();

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(LucideIcons.imageOff, color: Color(0xFF888888), size: 44),
        SizedBox(height: 12),
        Text(
          '图片加载失败',
          style: TextStyle(color: Color(0xFF888888), fontSize: 13),
        ),
      ],
    );
  }
}
