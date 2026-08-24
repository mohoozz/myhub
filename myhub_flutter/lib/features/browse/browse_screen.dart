import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/api/api_exception.dart';
import 'package:myhub_flutter/core/api/dio_client.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/core/models/reading_progress.dart';
import 'package:myhub_flutter/core/settings/server_config_provider.dart';
import 'package:myhub_flutter/core/settings/settings_provider.dart';
import 'package:myhub_flutter/core/theme/app_theme.dart' show AppTheme;
import 'package:myhub_flutter/data/repositories/progress_repository.dart';
import 'package:myhub_flutter/features/browse/providers/browse_progress.dart';
import 'package:myhub_flutter/features/browse/providers/browse_provider.dart';
import 'package:myhub_flutter/features/browse/providers/file_actions.dart';
import 'package:myhub_flutter/features/browse/widgets/breadcrumb_bar.dart';
import 'package:myhub_flutter/features/browse/widgets/file_dialogs.dart';
import 'package:myhub_flutter/features/browse/widgets/file_grid.dart';
import 'package:myhub_flutter/features/browse/widgets/file_list.dart';
import 'package:myhub_flutter/features/browse/widgets/move_target_picker.dart';
import 'package:myhub_flutter/features/browse/widgets/upload_sheet.dart';
import 'package:myhub_flutter/features/favorites/providers/favorite_provider.dart';
import 'package:myhub_flutter/shared/providers/source_provider.dart';
import 'package:myhub_flutter/shared/utils/downloader.dart';
import 'package:myhub_flutter/shared/utils/open_media.dart';
import 'package:myhub_flutter/shared/utils/top_snack_bar.dart';
import 'package:myhub_flutter/shared/widgets/comic_reader/comic_reader.dart';
import 'package:myhub_flutter/shared/widgets/image_preview/image_preview.dart';
import 'package:myhub_flutter/shared/widgets/media_player/media_player.dart';
import 'package:myhub_flutter/shared/widgets/novel_reader/novel_reader.dart';
import 'package:myhub_flutter/shared/widgets/source_selector.dart';
import 'package:myhub_flutter/shared/widgets/text_viewer/text_viewer.dart';
import 'package:myhub_flutter/shared/widgets/window_title_bar.dart'
    show isDesktopPlatform;

/// 头部「...」菜单项：上传 / 排序 / 多选 / 刷新 / 切换视图 / 新建文件夹 / 回收站。
enum _BrowseMenuAction {
  upload,
  sort,
  select,
  refresh,
  toggleView,
  mkdir,
  trash,
}

/// File browser page：路径源选择 + 面包屑 + 搜索 + 排序 + 网格/列表视图。
class BrowseScreen extends ConsumerStatefulWidget {
  const BrowseScreen({super.key});

  @override
  ConsumerState<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends ConsumerState<BrowseScreen>
    with TickerProviderStateMixin {
  final TextEditingController _searchController = TextEditingController();

  /// 正在打开阅读器：防止网络慢时频繁点击产生并发打开。
  bool _opening = false;

  /// 高亮定位项的 GlobalKey（绑定到匹配文件，用于滚动定位）。
  final GlobalKey _highlightKey = GlobalKey();

  /// 头部「...」按钮的 GlobalKey：从「排序」二级菜单触发时需要用它
  /// 获取按钮位置，让排序菜单锚定在「...」按钮正下方。
  final GlobalKey _moreMenuKey = GlobalKey();

  /// 网格/列表滚动控制器。
  ///
  /// 注意：`IndexedStack` 会把两个子视图都参与 layout（仅 paint 当前 index），
  /// 因此两个可滚动视图必须各自使用独立的 [ScrollController]，
  /// 不能共享同一个 —— 否则一个 controller 同时 attach 到两个
  /// ScrollPosition 会冲突，导致滚动/定位失效。
  final ScrollController _gridScrollController = ScrollController();
  final ScrollController _listScrollController = ScrollController();

  /// 已滚动定位过的高亮路径（避免列表重建时反复滚动）。
  String? _scrolledHighlight;

  /// 高亮呼吸灯边框的熄灭定时器："定位到源路径"的边框提示只亮 10 秒。
  Timer? _highlightTimer;

  /// 高亮滚动重试次数（目标项未挂载时逐帧逼近，达到上限则放弃）。
  int _scrollRetries = 0;

  static const int _kMaxScrollRetries = 24;

  /// 是否正在"定位中"：从阅读页跳转定位时显示浮层动画，
  /// 定位完成或超时后自动消失。
  bool _locating = false;

  /// 浮起搜索框可见性：列表向下滚动超过 [_kSearchShowThreshold]
  /// 时显示；滚回到顶部时隐藏。配合 [AnimatedSlide] 做丝滑过渡。
  bool _searchBarVisible = false;

  /// 上一次滚动像素位置，用于判断滚动方向。
  double _lastScrollOffset = 0;

  /// 触发浮起的滚动阈值：避免在顶部轻微 bounce 触发。
  static const double _kSearchShowThreshold = 80;

  /// 左边缘交互式返回：手势是否处于激活状态。
  ///
  /// 仅当手势在屏幕最左 ~[_kEdgeSwipeZone] px 内启动、且当前有可返回的
  /// 层级（子目录 / 多选模式）时激活；否则视为普通横向滑动（如横向滚动
  /// 的列表），不触发返回。
  bool _edgeBackActive = false;

  /// 左边缘滑动激活区宽度（屏幕左边缘起，px）。
  static const double _kEdgeSwipeZone = 30;

  /// 松手时判定"完成返回"的水平滑动速度阈值（px/s，正值向右）。
  static const double _kEdgeSwipeCommitVelocity = 320;

  /// 松手时判定"完成返回"的拖动进度阈值（0~1）。
  static const double _kEdgeSwipeCommitRatio = 0.35;

  /// 交互式返回动画控制器：value ∈ [0,1]。
  /// 0 = 未拖动（当前目录界面在原位），1 = 当前界面完全滑出、上一级
  /// 内容完全露出。拖动中直接赋值跟手；松手后 animateTo 0（回弹）或
  /// 1（完成返回，动画结束后真正切换目录）。
  late final AnimationController _edgeBackController;

  /// 交互式返回预览：露出的上一级目录文件列表快照（来自缓存）。
  /// 多选模式下"滑出"的是退出多选，预览为当前目录列表（无勾选态）。
  /// null 表示无缓存（预览层仅显示卡片底色）。
  List<FileItem>? _backPreviewItems;

  /// 交互式返回预览是否为"退出多选"场景（区别于"返回上级目录"）。
  bool _backPreviewExitSelection = false;

  /// 预览层滚动控制器（常驻；随预览层挂载/卸载自动 attach/detach）。
  final ScrollController _previewScrollController = ScrollController();

  /// 各目录的滚动位置记忆（path -> 滚动 offset）：进入子目录前记录
  /// 当前位置，返回该目录时恢复，让浏览位置前后接续。
  final Map<String, double> _scrollOffsetsByPath = {};

  /// 滑动区域的当前宽度（LayoutBuilder 中记录，用于把拖动像素换算为进度）。
  double _swipeAreaWidth = 1;

  @override
  void initState() {
    super.initState();
    _edgeBackController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      value: 0,
    );
    // 打开浏览页时把远端阅读进度合并回本地缓存（本地 drift 为进度圆环
    // 的实时数据源），保证其他设备上的阅读记录也能在浏览页显示进度。
    // 失败静默：离线时用本地缓存即可。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        ref
            .read(progressRepositoryProvider)
            .listMerged()
            .catchError((_) => <ReadingProgress>[]),
      );
    });
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _edgeBackController.dispose();
    _previewScrollController.dispose();
    _searchController.dispose();
    _gridScrollController.dispose();
    _listScrollController.dispose();
    super.dispose();
  }

  /// 当前视图模式对应的滚动控制器（IndexedStack 中网格/列表各一个）。
  ScrollController get _activeScrollController =>
      ref.read(viewModeProvider) == BrowseViewMode.grid
      ? _gridScrollController
      : _listScrollController;

  /// 高亮定位滚动。
  ///
  /// 大目录下 GridView/ListView 是懒加载的，目标文件可能排在第几百项，
  /// 其 widget 尚未 build，`_highlightKey.currentContext` 为 null，
  /// 直接 ensureVisible 会静默失败。因此这里采用"渐进逼近"策略：
  ///
  /// 1. 用 [ScrollPosition.maxScrollExtent] 与目标索引估算滚动位置并 jumpTo，
  ///    促使懒加载列表 build 出目标项；
  /// 2. 下一帧检查 GlobalKey 是否挂载：挂载则 ensureVisible 精确对齐；
  /// 3. 未挂载则继续逼近（每次拉近差距），直至命中或达到最大重试次数。
  ///
  /// 注意：必须用 `jumpTo`（而非 `animateTo`），因为只有同步跳转后下一帧
  /// 才会真正触发被跳过项的 build/measure，从而让 ensureVisible 有 context
  /// 可以对齐。
  void _scrollToHighlight(List<FileItem> items, String highlightPath) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _highlightKey.currentContext;
      if (ctx != null) {
        // 目标项已挂载：精确滚动到可见区域，定位完成，收起"定位中"浮层
        _scrollRetries = 0;
        if (_locating) {
          setState(() => _locating = false);
        }
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut,
          alignment: 0.3,
        );
        return;
      }
      // 目标项尚未被懒加载 build：按索引比例估算并 jumpTo，促使列表 build
      final index = items.indexWhere((f) => f.path == highlightPath);
      final controller = _activeScrollController;
      if (controller.hasClients && index >= 0 && items.isNotEmpty) {
        final pos = controller.position;
        final maxScroll = pos.maxScrollExtent;
        if (maxScroll > 0) {
          pos.jumpTo(
            (maxScroll * (index / items.length)).clamp(0.0, maxScroll),
          );
        }
        // 首帧 layout 还没完成（maxScrollExtent=0）时不下发 jumpTo，
        // 由下方重试在下一帧 maxScroll 就绪后继续逼近。
      }
      // 仍未挂载：下一帧继续逼近（list 重新 layout 后 maxScroll 会更新，
      // 同时 jumpTo 也促使目标项进入 cacheExtent 并被 build）
      if (_scrollRetries < _kMaxScrollRetries) {
        _scrollRetries++;
        // 首帧后强制触发一次 rebuild，让"定位中"浮层真正显示出来
        // （_locating 是在 build 阶段赋值，本身不会触发重建）。
        if (_scrollRetries == 1 && _locating) {
          setState(() {});
        }
        _scrollToHighlight(items, highlightPath);
      } else {
        // 达到重试上限仍未定位到：收起"定位中"浮层，避免一直空转
        if (_locating) {
          setState(() => _locating = false);
        }
      }
    });
  }

  void _openItem(FileItem item) {
    if (item.isDir) {
      // 延迟到下一帧再切换目录：让 InkWell 的水波纹点击动画先渲染出来。
      // 否则同步切换路径会导致列表立即重建，动画被截断/推迟到新目录
      // 渲染后才出现，造成"先跳转、后出现点击动画"的观感。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _searchController.clear();
        ref.read(searchQueryProvider.notifier).state = '';
        ref.read(browsePathProvider.notifier).state = item.path;
      });
      return;
    }
    if (item.isVideo || item.isAudio) {
      final source = ref.read(effectiveSourceProvider);
      if (source == null) return;
      // 迷你条在播时保持迷你模式直接切歌，否则进全屏播放页
      MediaPlayerPage.openOrMini(context, ref, sourceId: source.id, file: item);
      return;
    }
    if (item.isNovel) {
      // 后端 novel 类型即 txt/epub。
      // 默认：epub 走 EPUB 阅读器，txt 走纯文本阅读器；
      // 需要记录阅读进度时可在右键菜单选择"以小说阅读器打开"。
      final source = ref.read(effectiveSourceProvider);
      if (source == null) return;
      if (item.name.toLowerCase().endsWith('.epub')) {
        // 路由前先检测图集型（漫画），避免闪现 EPUB 阅读器再跳转
        if (_opening) return; // 防重复点击
        _opening = true;
        unawaited(
          openEpubFile(
            context,
            ref,
            sourceId: source.id,
            file: item,
          ).whenComplete(() => _opening = false),
        );
      } else {
        PlainTextViewerPage.open(context, sourceId: source.id, file: item);
      }
      return;
    }
    if (item.isComic || item.isArchive) {
      // cbz/cbr 直接进入阅读器；zip/rar 等普通压缩包由阅读器内部
      // 先嗅探判定是否为漫画再加载（立即展示加载界面，避免网络慢
      // 时点击无反馈、反复点击产生并发请求）
      final source = ref.read(effectiveSourceProvider);
      if (source == null) return;
      if (_opening) return; // 防重复点击
      _opening = true;
      unawaited(
        ComicReaderPage.open(
          context,
          sourceId: source.id,
          file: item,
        ).whenComplete(() => _opening = false),
      );
      return;
    }
    if (item.isImage) {
      // 纯图片：进入独立预览页，携带同目录全部图片以便切换上下张
      final source = ref.read(effectiveSourceProvider);
      if (source == null) return;
      if (_opening) return; // 防重复点击
      _opening = true;
      final images = (ref.read(visibleFilesProvider).valueOrNull ?? [])
          .where((f) => f.isImage)
          .toList();
      // item 本身来自当前目录列表，索引必然存在；找不到时兜底为 0
      final rawIndex = images.indexWhere((f) => f.path == item.path);
      unawaited(
        ImagePreviewPage.open(
          context,
          sourceId: source.id,
          file: item,
          images: images,
          initialIndex: rawIndex < 0 ? 0 : rawIndex,
        ).whenComplete(() => _opening = false),
      );
      return;
    }
    // 不支持预览的文件：底部拉起菜单栏，提供"以纯文本打开"入口
    _showUnsupportedMenu(item);
  }

  /// 不支持预览的文件：底部弹出菜单栏，含"以纯文本打开"选项。
  void _showUnsupportedMenu(FileItem item) {
    final source = ref.read(effectiveSourceProvider);
    if (source == null) return;
    if (_opening) return; // 防重复点击
    _opening = true;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(LucideIcons.download),
              title: const Text('下载'),
              subtitle: Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(_downloadItem(item));
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.fileText),
              title: const Text('以纯文本打开'),
              subtitle: Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () {
                Navigator.of(sheetContext).pop();
                PlainTextViewerPage.open(
                  context,
                  sourceId: source.id,
                  file: item,
                );
              },
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    ).whenComplete(() => _opening = false);
  }

  /// 下载文件到本地：桌面端存系统「下载」目录，移动端存应用文档目录
  /// （iOS 可在「文件」App 的 Myhub/Downloads 中查看）。
  Future<void> _downloadItem(FileItem item) async {
    if (kIsWeb) {
      if (mounted) showTopSnackBar(context, '当前平台暂不支持下载');
      return;
    }
    final sourceId = ref.read(effectiveSourceProvider)?.id;
    if (sourceId == null) return;
    // 先提示开始下载（toast 自动消失，慢速网络下载大文件期间也有反馈）
    if (mounted) showTopSnackBar(context, '正在下载 ${item.name}…');
    try {
      final dir = await DownloadSaver.resolveDir();
      final saved = await downloadRemoteFile(
        dio: ref.read(dioProvider),
        baseUrl: ref.read(apiBaseUrlProvider),
        sourceId: sourceId,
        path: item.path,
        fileName: item.name,
        destDir: dir,
      );
      if (!mounted) return;
      showTopSnackBar(context, DownloadSaver.savedHint(saved));
    } catch (e) {
      _showError(e);
    }
  }

  void _showError(Object e) {
    if (!mounted) return;
    showTopSnackBar(context, e is ApiException ? e.message : '操作失败：$e');
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      _showError(e);
    }
  }

  /// 文件选择器上传。
  Future<void> _pickAndUpload() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    final paths =
        result?.paths.whereType<String>().toList() ?? const <String>[];
    if (paths.isEmpty || !mounted) return;
    await UploadSheet.show(context);
    await _run(() => ref.read(fileActionsProvider).upload(paths));
  }

  /// 拖拽上传。
  Future<void> _dropUpload(List<String> paths) async {
    if (paths.isEmpty || !mounted) return;
    await UploadSheet.show(context);
    await _run(() => ref.read(fileActionsProvider).upload(paths));
  }

  Future<void> _mkdir() async {
    final name = await showMkdirDialog(context);
    if (name == null) return;
    await _run(() => ref.read(fileActionsProvider).mkdir(name));
  }

  Future<void> _renameSelected(String path) async {
    final item = ref
        .read(visibleFilesProvider)
        .valueOrNull
        ?.where((f) => f.path == path)
        .firstOrNull;
    if (item == null) return;
    final name = await showRenameDialog(context, item.name);
    if (name == null || name == item.name) return;
    await _run(() => ref.read(fileActionsProvider).rename(item, name));
    ref.read(selectionProvider.notifier).clear();
  }

  Future<void> _moveSelected() async {
    final paths = ref.read(selectionProvider).toList();
    final target = await MoveTargetPicker.show(context, title: '移动到…');
    if (target == null) return;
    await _run(() => ref.read(fileActionsProvider).move(paths, target));
  }

  Future<void> _copySelected() async {
    final paths = ref.read(selectionProvider).toList();
    final target = await MoveTargetPicker.show(context, title: '复制到…');
    if (target == null) return;
    await _run(() => ref.read(fileActionsProvider).copy(paths, target));
  }

  Future<void> _deleteSelected() async {
    final paths = ref.read(selectionProvider).toList();
    final confirmed = await showDeleteConfirmDialog(context, paths.length);
    if (!(confirmed ?? false)) return;
    await _run(() => ref.read(fileActionsProvider).delete(paths));
  }

  Future<void> _favoriteSelected() async {
    final paths = ref.read(selectionProvider);
    final items =
        ref
            .read(visibleFilesProvider)
            .valueOrNull
            ?.where((f) => paths.contains(f.path))
            .toList() ??
        [];
    await _run(() async {
      for (final item in items) {
        await ref.read(fileActionsProvider).favorite(item);
      }
      ref.read(selectionProvider.notifier).clear();
    });
    if (mounted) {
      showTopSnackBar(context, '已加入收藏');
    }
  }

  /// 条目上下文菜单（桌面端右键 / 移动端长按）：
  /// 打开/收藏/重命名/移动/复制/删除。
  Future<void> _showItemMenu(FileItem item, Offset position) async {
    final sourceId = ref.read(effectiveSourceProvider)?.id;
    final isFav =
        sourceId != null &&
        ref.read(favoritePathsProvider).contains('$sourceId|${item.path}');
    // 移动端菜单项较多，用 showMenu 弹出的浮层在窄屏上高度不够，
    // 末尾的「删除」会被顶出屏幕外不可见。移动端改用可滚动的底部抽屉，
    // 桌面端保持右键锚定的 showMenu。
    final String? action = isDesktopPlatform
        ? await _showItemMenuDesktop(item, sourceId, isFav, position)
        : await _showItemMenuMobile(item, sourceId, isFav);
    if (action == null || !mounted) return;
    switch (action) {
      case 'open':
        _openItem(item);
      case 'openAsNovel':
        final source = ref.read(effectiveSourceProvider);
        if (source != null) {
          unawaited(
            NovelReaderPage.open(context, sourceId: source.id, file: item),
          );
        }
      case 'favorite':
        if (sourceId != null) {
          await _run(
            () => ref
                .read(favoriteListProvider.notifier)
                .toggle(sourceId, item.path),
          );
        }
      case 'download':
        await _downloadItem(item);
      case 'rename':
        final name = await showRenameDialog(context, item.name);
        if (name == null || name == item.name || !mounted) return;
        await _run(() => ref.read(fileActionsProvider).rename(item, name));
      case 'move':
        final target = await MoveTargetPicker.show(context, title: '移动到…');
        if (target == null || !mounted) return;
        await _run(
          () => ref.read(fileActionsProvider).move([item.path], target),
        );
      case 'copy':
        final target = await MoveTargetPicker.show(context, title: '复制到…');
        if (target == null || !mounted) return;
        await _run(
          () => ref.read(fileActionsProvider).copy([item.path], target),
        );
      case 'delete':
        final confirmed = await showDeleteConfirmDialog(context, 1);
        if (!(confirmed ?? false) || !mounted) return;
        await _run(() => ref.read(fileActionsProvider).delete([item.path]));
    }
  }

  PopupMenuItem<String> _menuItem(
    String value,
    IconData icon,
    String label, {
    bool destructive = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = destructive ? colorScheme.error : colorScheme.onSurface;
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 10),
          Text(label, style: TextStyle(color: color)),
        ],
      ),
    );
  }

  /// 桌面端右键菜单：锚定在鼠标位置弹出 showMenu。
  Future<String?> _showItemMenuDesktop(
    FileItem item,
    int? sourceId,
    bool isFav,
    Offset position,
  ) {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    // 桌面端自定义标题栏使 Overlay 原点不在全局 (0,0)，需把鼠标全局坐标
    // 转成 Overlay 局部坐标，否则菜单会偏离鼠标位置。
    final local = overlay == null ? position : overlay.globalToLocal(position);
    final left = local.dx;
    final top = local.dy;
    final right = overlay == null ? 0.0 : overlay.size.width - left;
    final bottom = overlay == null ? 0.0 : overlay.size.height - top;
    return showMenu<String>(
      context: context,
      popUpAnimationStyle: AppTheme.menuPopUpAnimation,
      position: RelativeRect.fromLTRB(left, top, right, bottom),
      items: [
        _menuItem('open', LucideIcons.squareArrowOutUpRight, '打开'),
        // txt 文件额外提供"以小说阅读器打开"：记录章节/页内阅读进度
        if (item.isNovel &&
            !item.name.toLowerCase().endsWith('.epub') &&
            !item.isDir)
          _menuItem('openAsNovel', LucideIcons.bookOpen, '以小说阅读器打开'),
        if (!item.isDir && sourceId != null)
          _menuItem('favorite', LucideIcons.star, isFav ? '取消收藏' : '收藏'),
        if (!item.isDir)
          _menuItem('download', LucideIcons.download, '下载'),
        const PopupMenuDivider(),
        _menuItem('rename', LucideIcons.pencil, '重命名'),
        _menuItem('move', LucideIcons.folderInput, '移动到…'),
        _menuItem('copy', LucideIcons.copy, '复制到…'),
        const PopupMenuDivider(),
        _menuItem('delete', LucideIcons.trash2, '删除', destructive: true),
      ],
    );
  }

  /// 移动端长按 / 「...」按钮菜单：底部抽屉，内容可滚动，
  /// 保证「删除」等末尾项不会因菜单过长被顶出屏幕。
  Future<String?> _showItemMenuMobile(
    FileItem item,
    int? sourceId,
    bool isFav,
  ) {
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _sheetTile(
                  sheetContext,
                  LucideIcons.squareArrowOutUpRight,
                  '打开',
                  () => Navigator.of(sheetContext).pop('open'),
                ),
                if (item.isNovel &&
                    !item.name.toLowerCase().endsWith('.epub') &&
                    !item.isDir)
                  _sheetTile(
                    sheetContext,
                    LucideIcons.bookOpen,
                    '以小说阅读器打开',
                    () => Navigator.of(sheetContext).pop('openAsNovel'),
                  ),
                if (!item.isDir && sourceId != null)
                  _sheetTile(
                    sheetContext,
                    LucideIcons.star,
                    isFav ? '取消收藏' : '收藏',
                    () => Navigator.of(sheetContext).pop('favorite'),
                  ),
                if (!item.isDir)
                  _sheetTile(
                    sheetContext,
                    LucideIcons.download,
                    '下载',
                    () => Navigator.of(sheetContext).pop('download'),
                  ),
                _sheetTile(
                  sheetContext,
                  LucideIcons.pencil,
                  '重命名',
                  () => Navigator.of(sheetContext).pop('rename'),
                ),
                _sheetTile(
                  sheetContext,
                  LucideIcons.folderInput,
                  '移动到…',
                  () => Navigator.of(sheetContext).pop('move'),
                ),
                _sheetTile(
                  sheetContext,
                  LucideIcons.copy,
                  '复制到…',
                  () => Navigator.of(sheetContext).pop('copy'),
                ),
                _sheetTile(
                  sheetContext,
                  LucideIcons.trash2,
                  '删除',
                  destructive: true,
                  () => Navigator.of(sheetContext).pop('delete'),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 移动端底部抽屉菜单项（与桌面端 _menuItem 风格一致的列表项）。
  Widget _sheetTile(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool destructive = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = destructive ? colorScheme.error : colorScheme.onSurface;
    return ListTile(
      leading: Icon(icon, size: 20, color: color),
      title: Text(label, style: TextStyle(color: color)),
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final source = ref.watch(effectiveSourceProvider);
    final path = ref.watch(browsePathProvider);
    final viewMode = ref.watch(viewModeProvider);
    final sort = ref.watch(sortProvider);
    final filesAsync = ref.watch(visibleFilesProvider);
    final selection = ref.watch(selectionProvider);
    final selectionMode = ref.watch(selectionModeProvider);

    // 切换目录/路径源或高亮目标变化后，重置已滚动标记，
    // 保证从"正在阅读"页跳转定位时总能自动滚动到目标文件。
    ref.listen(browsePathProvider, (prev, next) {
      if (prev != next) {
        // 记录离开目录的滚动位置；恢复目标目录离开前的位置
        // （未访问过的目录回顶部），返回时接续浏览。
        if (prev != null) _rememberScrollOffset(prev);
        _restoreScrollOffset(next);
        _scrolledHighlight = null;
        _scrollRetries = 0;
        // 进入新目录时清空多选状态：旧目录的 selectedPaths 是相对路径，
        // 跨目录继续保留会导致操作按钮(移动/复制/删除)作用在错误目录上。
        ref.read(selectionProvider.notifier).clear();
      }
    });
    ref.listen(highlightFileProvider, (prev, next) {
      if (prev != next) {
        _scrolledHighlight = null;
        _scrollRetries = 0;
      }
      // 高亮边框只提示 10 秒：新目标重置计时，到点自动熄灭
      // （清空高亮目标，边框随状态消失，呼吸动画组件同步销毁）。
      _highlightTimer?.cancel();
      if (next != null) {
        _highlightTimer = Timer(const Duration(seconds: 10), () {
          if (!mounted) return;
          ref.read(highlightFileProvider.notifier).state = null;
        });
      }
    });
    ref.listen(effectiveSourceProvider, (prev, next) {
      if (prev?.id != next?.id) {
        _scrolledHighlight = null;
        _scrollRetries = 0;
        // 切换路径源时同样清空多选：新路径源的 selectedPaths 没有意义。
        ref.read(selectionProvider.notifier).clear();
      }
    });

    // 系统返回手势兼容：多选中 → 退出多选；子目录 → 回上级；否则正常出栈
    return PopScope(
      canPop: !selectionMode && path == '/',
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (selectionMode) {
          ref.read(selectionProvider.notifier).clear();
        } else {
          ref.read(browsePathProvider.notifier).state = parentPathOf(path);
        }
      },
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(7, 6, 7, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 1. 顶部标题栏：路径源选择器（左，可横滑）+ 「...」菜单（右）。
                //    把原本独立的"排序 / 上传"按钮都收纳进「...」菜单，
                //    头部仅保留一行，避免 iOS 窄屏上两排控件 + 面包屑过于拥挤。
                Row(
                  children: [
                    Expanded(
                      child: SourceSelector(
                        onChanged: (_) =>
                            ref.read(browsePathProvider.notifier).state = '/',
                      ),
                    ),
                    const SizedBox(width: 4),
                    PopupMenuButton<_BrowseMenuAction>(
                      key: _moreMenuKey,
                      icon: const Icon(LucideIcons.ellipsisVertical, size: 16),
                      tooltip: '更多',
                      position: PopupMenuPosition.under,
                      popUpAnimationStyle: AppTheme.menuPopUpAnimation,
                      onSelected: _onMenuAction,
                      itemBuilder: (context) => [
                        _buildMenuItem(
                          icon: LucideIcons.upload,
                          label: '上传',
                          value: _BrowseMenuAction.upload,
                        ),
                        _buildMenuItem(
                          icon: LucideIcons.arrowDownUp,
                          label: '排序',
                          // 二级菜单显示当前排序：让用户知道当前生效的规则，
                          // 同时也可作为入口引导到排序弹窗。
                          subtitle:
                              '${sort.label}${sort.ascending ? ' ↑' : ' ↓'}',
                          value: _BrowseMenuAction.sort,
                        ),
                        _buildMenuItem(
                          icon: LucideIcons.checkSquare,
                          label: selectionMode ? '退出多选' : '多选',
                          value: _BrowseMenuAction.select,
                        ),
                        _buildMenuItem(
                          icon: LucideIcons.rotateCw,
                          label: '刷新',
                          value: _BrowseMenuAction.refresh,
                        ),
                        const PopupMenuDivider(),
                        _buildMenuItem(
                          icon: viewMode == BrowseViewMode.grid
                              ? LucideIcons.list
                              : LucideIcons.layoutGrid,
                          label: viewMode == BrowseViewMode.grid
                              ? '切换为列表视图'
                              : '切换为网格视图',
                          value: _BrowseMenuAction.toggleView,
                        ),
                        _buildMenuItem(
                          icon: LucideIcons.folderPlus,
                          label: '新建文件夹',
                          value: _BrowseMenuAction.mkdir,
                        ),
                        _buildMenuItem(
                          icon: LucideIcons.trash2,
                          label: '回收站',
                          value: _BrowseMenuAction.trash,
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // 2. 当前路径（搜索框改为滚动列表时浮起，见下方 _SlidingSearchBar）
                //    移动端隐藏：iOS / Android 顶部安全区 + 路径源 chip 已经占据
                //    头部较多空间，再加面包屑会让窄屏头部过于拥挤。
                //    移动端用户可通过 `..` 返回上级，路径信息可在多选/收藏
                //    等对话框里查看，无需常驻头部。
                if (isDesktopPlatform)
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: BreadcrumbBar(
                      rootLabel: source?.name ?? '路径源',
                      path: path,
                      onNavigate: (target) =>
                          ref.read(browsePathProvider.notifier).state = target,
                    ),
                  ),
                if (isDesktopPlatform) const SizedBox(height: 8),
                // 左边缘交互式滑动返回上一级（iOS 返回手势风格）：
                // 手指从屏幕左边缘向右拖动时，当前目录界面跟手滑出，
                // 被划过的区域显示上一级目录内容（缓存快照 + 视差动画）。
                // behavior: translucent 保证不影响列表的垂直滚动与内部
                // 横向元素的正常命中。
                // 注意：Expanded 必须直接作为 Column(Flex) 的子级，
                // 不能放在 GestureDetector(Listener) 内部，否则抛
                // "Incorrect use of ParentDataWidget" 导致文件区域塌陷为灰色空白。
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragStart: _onEdgeDragStart,
                    onHorizontalDragUpdate: _onEdgeDragUpdate,
                    onHorizontalDragEnd: _onEdgeDragEnd,
                    onHorizontalDragCancel: _onEdgeDragCancel,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        // 滑动区域宽度：拖动像素 → [0,1] 进度换算用
                        _swipeAreaWidth = constraints.maxWidth;
                        final width = constraints.maxWidth;
                        return Stack(
                          children: [
                            // 底层：上一级目录预览（iOS 返回手势式视差
                            // 滑入）。仅在拖动/回弹动画进行中挂载，
                            // 平时零开销。
                            Positioned.fill(
                              child: IgnorePointer(
                                child: AnimatedBuilder(
                                  animation: _edgeBackController,
                                  builder: (context, _) {
                                    final t = _edgeBackController.value;
                                    if (t <= 0.001) {
                                      return const SizedBox.shrink();
                                    }
                                    // 视差：预览层从左侧 30% 处
                                    // 随滑出进度逐渐滑到原位
                                    return Transform.translate(
                                      offset: Offset(-width * 0.3 * (1 - t), 0),
                                      child: _buildEdgeBackPreview(),
                                    );
                                  },
                                ),
                              ),
                            ),
                            // 上层：当前目录界面，跟手向右滑出。
                            // child（文件区 Stack）只 build 一次，
                            // 拖动期间每帧仅更新 Transform，不重建列表。
                            AnimatedBuilder(
                              animation: _edgeBackController,
                              child: Stack(
                                children: [
                                  // 浮起的搜索栏：默认隐藏，用户向下滚动列表超过
                                  // [_kSearchShowThreshold] 时滑入，回到顶部时滑出。
                                  // 直接放在 Stack 顶而非 Column，是因为它要覆盖在
                                  // 列表上方而不是挤掉列表的空间。
                                  Positioned(
                                    top: 0,
                                    left: 0,
                                    right: 0,
                                    child: _SlidingSearchBar(
                                      visible: _searchBarVisible,
                                      controller: _searchController,
                                      onChanged: (v) =>
                                          ref
                                                  .read(
                                                    searchQueryProvider
                                                        .notifier,
                                                  )
                                                  .state =
                                              v,
                                    ),
                                  ),
                                  Positioned.fill(
                                    child: DropTarget(
                                      onDragDone: (details) => _dropUpload(
                                        details.files
                                            .map((f) => f.path)
                                            .toList(),
                                      ),
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: theme.cardTheme.color,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        clipBehavior: Clip.antiAlias,
                                        child: NotificationListener<ScrollNotification>(
                                          onNotification: _onScrollNotify,
                                          child: Column(
                                            children: [
                                              // 非根目录时提供 ".." 返回上级
                                              // 网格模式下 ".." 以卡片形式插入网格首位（见 FileGridView）
                                              if (path != '/' &&
                                                  viewMode ==
                                                      BrowseViewMode.list)
                                                _ParentEntry(
                                                  onTap: () =>
                                                      ref
                                                          .read(
                                                            browsePathProvider
                                                                .notifier,
                                                          )
                                                          .state = parentPathOf(
                                                        path,
                                                      ),
                                                ),
                                              Expanded(
                                                child: _buildContent(
                                                  filesAsync,
                                                  viewMode,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  // "定位中"浮层：从阅读页跳转定位时，目录可能较大，
                                  // 加载+滚动定位需要一定时间，用半透明遮罩+动画提示用户。
                                  if (_locating)
                                    const Positioned.fill(
                                      child: _LocatingOverlay(),
                                    ),
                                ],
                              ),
                              builder: (context, child) => Transform.translate(
                                offset: Offset(
                                  width * _edgeBackController.value,
                                  0,
                                ),
                                child: child,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
                if (selectionMode)
                  _SelectionActionBar(
                    count: selection.length,
                    onSelectAll: () => ref
                        .read(selectionProvider.notifier)
                        .selectAll(filesAsync.valueOrNull ?? []),
                    onMove: _moveSelected,
                    onCopy: _copySelected,
                    onRename: selection.length == 1
                        ? () => _renameSelected(selection.first)
                        : null,
                    onFavorite: _favoriteSelected,
                    onDelete: _deleteSelected,
                    onClose: () => ref.read(selectionProvider.notifier).clear(),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// "..." 菜单点击统一处理。
  void _onMenuAction(_BrowseMenuAction action) {
    switch (action) {
      case _BrowseMenuAction.upload:
        _pickAndUpload();
      case _BrowseMenuAction.sort:
        // 排序是二级菜单：从「...」菜单选中后关闭它，再独立弹出排序菜单。
        _showSortMenu();
      case _BrowseMenuAction.select:
        final selectionMode = ref.read(selectionModeProvider);
        if (selectionMode) {
          ref.read(selectionProvider.notifier).clear();
        } else {
          ref.read(selectionModeProvider.notifier).enter();
        }
      case _BrowseMenuAction.refresh:
        ref.read(fileListProvider.notifier).refresh();
      case _BrowseMenuAction.toggleView:
        ref.read(viewModeProvider.notifier).toggle();
      case _BrowseMenuAction.mkdir:
        _mkdir();
      case _BrowseMenuAction.trash:
        context.push('/trash');
    }
  }

  /// 左边缘交互式返回手势开始：起点在屏幕左边缘激活区内、且存在可
  /// 返回的层级（子目录 / 多选）时激活，并准备好预览层（上一级目录
  /// 缓存快照 / 当前目录无多选态）。
  void _onEdgeDragStart(DragStartDetails details) {
    final selectionMode = ref.read(selectionModeProvider);
    final path = ref.read(browsePathProvider);
    final active =
        details.globalPosition.dx <= _kEdgeSwipeZone &&
        (selectionMode || path != '/');
    if (!active) {
      _edgeBackActive = false;
      return;
    }
    if (_edgeBackController.isAnimating) _edgeBackController.stop();
    _edgeBackActive = true;
    _backPreviewExitSelection = selectionMode;
    if (selectionMode) {
      // 退出多选：预览 = 当前目录列表（无勾选状态）
      _backPreviewItems =
          ref.read(visibleFilesProvider).valueOrNull ?? const <FileItem>[];
    } else {
      // 返回上级：预览 = 父目录的缓存快照（null → 仅显示卡片底色）
      final source = ref.read(effectiveSourceProvider);
      final parent = parentPathOf(path);
      _backPreviewItems = source == null
          ? null
          : ref.read(directoryCacheProvider)['${source.id}|$parent'];
    }
    // 预览列表滚动到该目录上次浏览的位置（与主列表恢复行为一致，
    // 保证松手完成返回时预览与主界面无缝衔接）。
    final previewPath = selectionMode ? path : parentPathOf(path);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_edgeBackActive) return;
      if (!_previewScrollController.hasClients) return;
      final recorded = _scrollOffsetsByPath[previewPath] ?? 0;
      final pos = _previewScrollController.position;
      pos.jumpTo(recorded.clamp(0.0, pos.maxScrollExtent));
    });
    // 重建预览层（新快照）；t 仍为 0，预览保持隐藏。
    setState(() {});
  }

  /// 左边缘交互式返回拖动中：当前目录界面跟手向右滑出。
  void _onEdgeDragUpdate(DragUpdateDetails details) {
    if (!_edgeBackActive) return;
    final width = _swipeAreaWidth;
    if (width <= 0) return;
    _edgeBackController.value =
        (_edgeBackController.value + details.primaryDelta! / width).clamp(
          0.0,
          1.0,
        );
  }

  /// 左边缘交互式返回松手：按滑动速度/拖动进度判定完成返回或回弹。
  Future<void> _onEdgeDragEnd(DragEndDetails details) async {
    if (!_edgeBackActive) return;
    _edgeBackActive = false;
    final velocity = details.primaryVelocity ?? 0;
    final shouldCommit =
        velocity > _kEdgeSwipeCommitVelocity ||
        _edgeBackController.value >= _kEdgeSwipeCommitRatio;
    if (shouldCommit) {
      // 完成：当前界面滑出屏幕，动画结束后真正切换目录/退出多选。
      await _edgeBackController.animateTo(
        1,
        curve: Curves.easeOutCubic,
        duration: const Duration(milliseconds: 200),
      );
      if (!mounted) return;
      _commitEdgeBack();
    } else {
      // 回弹：未达阈值，当前界面滑回原位，预览随之滑出。
      await _edgeBackController.animateTo(
        0,
        curve: Curves.easeOutCubic,
        duration: const Duration(milliseconds: 220),
      );
    }
  }

  /// 手势被打断（如来电、系统手势接管）：回弹复位。
  void _onEdgeDragCancel() {
    if (!_edgeBackActive) return;
    _edgeBackActive = false;
    _edgeBackController.animateTo(
      0,
      curve: Curves.easeOutCubic,
      duration: const Duration(milliseconds: 220),
    );
  }

  /// 完成返回：滑出动画结束后真正切换状态。
  ///
  /// 此刻上一级目录的列表已通过 FileListNotifier 的缓存优先策略同步
  /// 就位，把滑出进度重置为 0 后界面内容不变、位置无缝衔接。
  void _commitEdgeBack() {
    if (ref.read(selectionModeProvider)) {
      ref.read(selectionProvider.notifier).clear();
    } else {
      final currentPath = ref.read(browsePathProvider);
      if (currentPath != '/') {
        _searchController.clear();
        ref.read(searchQueryProvider.notifier).state = '';
        ref.read(browsePathProvider.notifier).state = parentPathOf(currentPath);
      }
    }
    _edgeBackController.value = 0;
    _backPreviewItems = null;
  }

  /// 构建左边缘滑动返回时露出的"上一级目录"预览层（只读，不可交互）。
  ///
  /// * 返回上级：渲染父目录的缓存快照，与滑动完成后主界面显示的内容
  ///   一致，保证动画收尾无缝；
  /// * 退出多选：渲染当前目录列表（无勾选状态）。
  Widget _buildEdgeBackPreview() {
    final theme = Theme.of(context);
    final sourceId = ref.read(effectiveSourceProvider)?.id;
    final viewMode = ref.read(viewModeProvider);
    final nameLines = ref.read(fileNameLinesProvider);
    final progressRaw = ref.watch(browseProgressProvider).valueOrNull;
    final progressPercent = progressRaw == null
        ? const <String, double?>{}
        : <String, double?>{
            for (final e in progressRaw.entries) e.key: e.value.percent,
          };
    final items = _backPreviewItems;
    final currentPath = ref.read(browsePathProvider);
    final previewPath = _backPreviewExitSelection
        ? currentPath
        : parentPathOf(currentPath);

    Widget body;
    if (items == null) {
      // 父目录无缓存（如冷启动直达子目录）：仅显示卡片底色
      body = const SizedBox.expand();
    } else if (items.isEmpty) {
      body = const _EmptyState();
    } else {
      final isGrid = viewMode == BrowseViewMode.grid;
      body = Column(
        children: [
          // 列表模式下与主界面一致：非根目录顶部渲染 ".." 条目
          if (!isGrid && previewPath != '/') _ParentEntry(onTap: _noop),
          Expanded(
            child: isGrid
                ? FileGridView(
                    items: items,
                    controller: _previewScrollController,
                    onOpen: (_) {},
                    onParentTap: previewPath == '/' ? null : _noop,
                    coverSourceId: sourceId,
                    nameLines: nameLines,
                    progressByPath: progressPercent,
                  )
                : FileListView(
                    items: items,
                    controller: _previewScrollController,
                    onOpen: (_) {},
                    coverSourceId: sourceId,
                    nameLines: nameLines,
                    progressByPath: progressPercent,
                  ),
          ),
        ],
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: body,
    );
  }

  static void _noop() {}

  /// 记录目录 [path] 的当前滚动位置（离开目录前调用）。
  void _rememberScrollOffset(String path) {
    final controller = _activeScrollController;
    if (controller.hasClients) {
      _scrollOffsetsByPath[path] = controller.offset;
    }
  }

  /// 恢复目录 [path] 的滚动位置（进入目录后下一帧调用）。
  /// 未访问过的目录回到顶部；clamp 防止列表变短后越界。
  void _restoreScrollOffset(String path) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = _activeScrollController;
      if (!controller.hasClients) return;
      final target = _scrollOffsetsByPath[path] ?? 0;
      final pos = controller.position;
      pos.jumpTo(target.clamp(0.0, pos.maxScrollExtent));
    });
  }

  /// 生成一个带图标+文字的菜单项（统一风格）。
  PopupMenuItem<_BrowseMenuAction> _buildMenuItem({
    required IconData icon,
    required String label,
    required _BrowseMenuAction value,
    String? subtitle,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return PopupMenuItem<_BrowseMenuAction>(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 16, color: colorScheme.onSurface),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label),
                if (subtitle != null) ...[
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 列表滚动的搜索框可见性监听。
  ///
  /// 设计：仅在明显向下滚动时显示浮起搜索框，避免滚动顶端"轻微 bounce"
  /// 造成的闪烁。`metrics.axis == Axis.vertical` 排除横向滚动工具栏
  /// 等事件导致的误判。
  bool _onScrollNotify(ScrollNotification notification) {
    if (notification is! ScrollUpdateNotification) return false;
    if (notification.metrics.axis != Axis.vertical) return false;
    final pos = notification.metrics.pixels;
    final delta = pos - _lastScrollOffset;
    _lastScrollOffset = pos;
    final shouldShow = pos > _kSearchShowThreshold;
    if (shouldShow != _searchBarVisible) {
      setState(() => _searchBarVisible = shouldShow);
    } else if (delta < -120 && _searchBarVisible) {
      // 明显向下滑回顶部时立即收起（清掉之前的展示）。
      // delta < -120 是为了过滤掉 TouchSlop / 偶发反向抖动。
      setState(() => _searchBarVisible = false);
    }
    return false;
  }

  Widget _buildContent(
    AsyncValue<List<FileItem>> filesAsync,
    BrowseViewMode viewMode,
  ) {
    return filesAsync.when(
      loading: () => const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      error: (err, _) => _ErrorState(
        message: err.toString(),
        onRetry: () => ref.read(fileListProvider.notifier).refresh(),
      ),
      data: (items) {
        if (items.isEmpty) {
          return const _EmptyState();
        }
        final selection = ref.watch(selectionProvider);
        final path = ref.watch(browsePathProvider);
        final selectionNotifier = ref.read(selectionProvider.notifier);
        final selectionMode = ref.watch(selectionModeProvider);
        // 移动端无右键，长按（非多选模式）弹出与 PC 右键相同的上下文菜单；
        // 桌面端长按保留"进入多选模式"（长按手势与菜单手势互斥，需按平台二选一）。
        final favoriteSourceId = ref.read(effectiveSourceProvider)?.id;
        final highlightPath = ref.watch(highlightFileProvider);
        final nameLines = ref.watch(fileNameLinesProvider);
        // 当前路径源下各文件的阅读进度（本地库实时流），
        // 用于行尾/卡片角上的进度圆环展示。
        final progressByPath = ref.watch(browseProgressProvider).valueOrNull;
        final progressPercent = <String, double?>{
          for (final f in items) f.path: progressByPath?[f.path]?.percent,
        };

        // 高亮定位：目标文件出现在当前目录时，自动滚动到该文件。
        // 大目录懒加载下目标项可能尚未 build，见 _scrollToHighlight 处理。
        final hasHighlight =
            highlightPath != null && items.any((f) => f.path == highlightPath);
        if (hasHighlight && _scrolledHighlight != highlightPath) {
          _scrolledHighlight = highlightPath;
          _scrollRetries = 0;
          // 启动定位：标记"定位中"（浮层由 _scrollToHighlight 在首帧后触发
          // rebuild 显示，定位完成/超时后自动收起）。
          // 注意：此处正处于 build 阶段，不能直接 setState，仅做字段赋值。
          _locating = true;
          _scrollToHighlight(items, highlightPath);
        }

        // IndexedStack 会把两个子视图都 build（仅 paint 当前 index）。
        // 因此 GlobalKey 与 ScrollController 都只能绑定到当前显示的视图，
        // 否则同一个 key 会同时在树中出现两次（Duplicate GlobalKey 异常），
        // 或同一个 controller attach 到两个 ScrollPosition（滚动失效）。
        final isGrid = viewMode == BrowseViewMode.grid;
        return IndexedStack(
          // 必须 expand 填满父级（Expanded），否则内部 ListView/GridView
          // 在 StackFit.loose 下会把 IndexedStack 高度收缩为 0，
          // 导致文件区域只剩外层卡片背景（灰色）而无任何内容。
          sizing: StackFit.expand,
          index: isGrid ? 0 : 1,
          children: [
            FileGridView(
              items: items,
              controller: isGrid ? _gridScrollController : null,
              onOpen: _openItem,
              onParentTap: path == '/'
                  ? null
                  : () => ref.read(browsePathProvider.notifier).state =
                        parentPathOf(path),
              onRefresh: () => ref.read(fileListProvider.notifier).refresh(),
              selectionMode: selectionMode,
              selectedPaths: selection,
              onToggleSelect: (f) => selectionNotifier.toggle(f.path),
              onLongPress: selectionMode
                  ? (f) => selectionNotifier.toggle(f.path)
                  : isDesktopPlatform
                  ? (f) => selectionNotifier.enter(f.path)
                  : (f) => unawaited(_showItemMenu(f, Offset.zero)),
              coverSourceId: favoriteSourceId,
              onShowMenu: _showItemMenu,
              highlightPath: highlightPath,
              highlightKey: isGrid ? _highlightKey : null,
              nameLines: nameLines,
              progressByPath: progressPercent,
            ),
            FileListView(
              items: items,
              controller: isGrid ? null : _listScrollController,
              onOpen: _openItem,
              onRefresh: () => ref.read(fileListProvider.notifier).refresh(),
              selectionMode: selectionMode,
              selectedPaths: selection,
              onToggleSelect: (f) => selectionNotifier.toggle(f.path),
              onLongPress: selectionMode
                  ? (f) => selectionNotifier.toggle(f.path)
                  : isDesktopPlatform
                  ? (f) => selectionNotifier.enter(f.path)
                  : (f) => unawaited(_showItemMenu(f, Offset.zero)),
              coverSourceId: favoriteSourceId,
              onShowMenu: _showItemMenu,
              highlightPath: highlightPath,
              highlightKey: isGrid ? null : _highlightKey,
              nameLines: nameLines,
              progressByPath: progressPercent,
            ),
          ],
        );
      },
    );
  }

  /// 显示排序二级菜单：锚定在「...」按钮正下方，展示当前排序 + 各升降序选项。
  ///
  /// 设计：浏览页头部把排序按钮收纳进「...」菜单后，「排序」子项再嵌套一个
  /// `showMenu` 会让交互层级过深。因此改为：从「...」菜单选中「排序」后，
  /// 关闭「...」菜单，再独立弹出本菜单；位置取「...」按钮的全局坐标，
  /// 与「...」菜单弹出的方向一致（向下）。
  Future<void> _showSortMenu() async {
    final theme = Theme.of(context);
    final sort = ref.read(sortProvider);
    final box = _moreMenuKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    // 与浏览页右键菜单相同的处理：自定义标题栏使 Overlay 原点不在 (0,0)，
    // 需把全局坐标转成 Overlay 局部坐标，否则菜单会偏离按钮位置。
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final local = overlay.globalToLocal(topLeft);
    final left = local.dx;
    final top = local.dy + box.size.height;
    final right = overlay.size.width - (left + box.size.width);
    final bottom = overlay.size.height - top;

    final picked = await showMenu<SortSpec>(
      context: context,
      popUpAnimationStyle: AppTheme.menuPopUpAnimation,
      position: RelativeRect.fromLTRB(left, top, right, bottom),
      items: [
        for (final field in SortField.values)
          for (final asc in [true, false])
            PopupMenuItem<SortSpec>(
              value: SortSpec(field: field, ascending: asc),
              child: Row(
                children: [
                  if (sort.field == field && sort.ascending == asc)
                    Icon(
                      LucideIcons.check,
                      size: 15,
                      color: theme.colorScheme.primary,
                    )
                  else
                    const SizedBox(width: 15),
                  const SizedBox(width: 8),
                  Text('${_fieldLabel(field)}${asc ? '（升序）' : '（降序）'}'),
                ],
              ),
            ),
      ],
    );
    if (picked != null) {
      unawaited(ref.read(sortProvider.notifier).update(picked));
    }
  }

  String _fieldLabel(SortField field) => switch (field) {
    SortField.name => '名称',
    SortField.size => '大小',
    SortField.modTime => '时间',
  };
}

/// ".." 返回上级条目（目录列表顶部）。
class _ParentEntry extends StatelessWidget {
  const _ParentEntry({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 局部 Material：ink 悬停高亮绘制在本行表面，不被外层卡片容器遮挡。
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  // 与 _FileRow 中 SizedBox(32, 32) 保持一致，保证行高与图标
                  // 水平基线对齐。
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: Center(
                      child: Icon(
                        LucideIcons.folderUp,
                        size: 20,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 4,
                    child: Text(
                      '..',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: isDesktopPlatform
                          ? theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w500,
                            )
                          : theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                    ),
                  ),
                  // 占位列，对齐普通行右侧两列（大小 / 时间），
                  // 视觉上让 "返回上级" 行的右端与下方条目保持同一基准线。
                  const Expanded(flex: 2, child: SizedBox()),
                  const Expanded(flex: 2, child: SizedBox()),
                ],
              ),
            ),
            // 与文件行的分割线保持一致的缩进
            const Divider(height: 1, indent: 54, endIndent: 16),
          ],
        ),
      ),
    );
  }
}

/// 多选操作栏（多选模式时浮现于底部）。
class _SelectionActionBar extends StatelessWidget {
  const _SelectionActionBar({
    required this.count,
    required this.onSelectAll,
    required this.onMove,
    required this.onCopy,
    required this.onRename,
    required this.onFavorite,
    required this.onDelete,
    required this.onClose,
  });

  final int count;
  final VoidCallback onSelectAll;
  final VoidCallback onMove;
  final VoidCallback onCopy;
  final VoidCallback? onRename;
  final VoidCallback onFavorite;
  final VoidCallback onDelete;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(12),
      ),
      // iPhone 窄屏下按钮非常多（移动/复制/重命名/收藏/删除 5 个图标），
      // 把它们整体放进横向滚动区域；左侧只保留"取消 + 已选N项"两个
      // 核心信息，避免被挤掉或截断。
      child: Row(
        children: [
          // 左侧固定区域：取消 + 已选数。
          // 用紧凑的 IconButton + 短文案，保证窄屏上一定可显示。
          IconButton(
            icon: const Icon(LucideIcons.x, size: 16),
            onPressed: onClose,
            tooltip: '取消多选',
            visualDensity: VisualDensity.compact,
          ),
          Text('已选 $count 项', style: theme.textTheme.bodySmall),
          // 右侧可横向滚动区域：全选 + 移动/复制/重命名/收藏。
          // 「删除」单独固定在最右侧，避免窄屏上被挤进滚动区、
          // 需横向滑动才能看到。
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: onSelectAll,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: const Text('全选'),
                  ),
                  IconButton(
                    icon: const Icon(LucideIcons.folderInput, size: 16),
                    onPressed: onMove,
                    tooltip: '移动',
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    icon: const Icon(LucideIcons.copy, size: 16),
                    onPressed: onCopy,
                    tooltip: '复制',
                    visualDensity: VisualDensity.compact,
                  ),
                  if (onRename != null)
                    IconButton(
                      icon: const Icon(LucideIcons.pencil, size: 16),
                      onPressed: onRename,
                      tooltip: '重命名',
                      visualDensity: VisualDensity.compact,
                    ),
                  IconButton(
                    icon: const Icon(LucideIcons.star, size: 16),
                    onPressed: onFavorite,
                    tooltip: '收藏',
                    visualDensity: VisualDensity.compact,
                  ),
                  // 尾部留白，避免最后一个按钮紧贴边缘。
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),
          // 固定在最右侧的「删除」按钮：始终可见，不会被横向滚动截断。
          IconButton(
            icon: Icon(LucideIcons.trash2, size: 16, color: colorScheme.error),
            onPressed: onDelete,
            tooltip: '删除',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

/// "定位中"浮层：从阅读页跳转定位时，覆盖在文件列表上，
/// 提示用户正在加载并滚动定位到目标文件。
class _LocatingOverlay extends StatelessWidget {
  const _LocatingOverlay();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return IgnorePointer(
      child: Container(
        color: colorScheme.surface.withValues(alpha: 0.5),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '正在定位…',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.folderOpen,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 10),
          Text(
            '此目录为空',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.cloudOff,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 10),
          Text(
            '加载失败',
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

/// 浮起的搜索框：默认隐藏在屏幕外（向上偏移自身高度），仅当
/// [visible] 为 true 时滑入。它覆盖在列表之上，背景半透明 + 模糊，
/// 配合搜索图标按钮形成 macOS Spotlight 式的"按住下拉出现搜索栏"。
class _SlidingSearchBar extends StatelessWidget {
  const _SlidingSearchBar({
    required this.visible,
    required this.controller,
    required this.onChanged,
  });

  final bool visible;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        // 隐藏时完全滑到顶部外；显示时归位。
        offset: visible ? Offset.zero : const Offset(0, -1),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 220),
          opacity: visible ? 1 : 0,
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              decoration: BoxDecoration(
                // 半透明 + 模糊背景：让覆盖在文件卡片上仍能看清下方内容
                // 一行（视觉上是"漂浮"在列表顶部而非遮挡）。
                color: colorScheme.surface.withValues(alpha: 0.85),
                border: Border(
                  bottom: BorderSide(
                    color: colorScheme.outline.withValues(alpha: 0.4),
                  ),
                ),
              ),
              child: SizedBox(
                height: 36,
                child: TextField(
                  controller: controller,
                  onChanged: onChanged,
                  style: theme.textTheme.bodyMedium,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: '搜索...',
                    hintStyle: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                    prefixIcon: Icon(
                      LucideIcons.search,
                      size: 16,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    isDense: true,
                    filled: true,
                    fillColor: colorScheme.surfaceContainerHigh,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide(
                        color: colorScheme.primary,
                        width: 1.2,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
