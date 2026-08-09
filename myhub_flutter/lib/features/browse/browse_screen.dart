import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/api/api_exception.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
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
import 'package:myhub_flutter/shared/utils/top_snack_bar.dart';
import 'package:myhub_flutter/shared/widgets/comic_reader/comic_reader.dart';
import 'package:myhub_flutter/shared/widgets/image_preview/image_preview.dart';
import 'package:myhub_flutter/shared/widgets/media_player/media_player.dart';
import 'package:myhub_flutter/shared/widgets/novel_reader/epub_reader.dart';
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

class _BrowseScreenState extends ConsumerState<BrowseScreen> {
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

  /// 左边缘滑动手势：起始点全局 x 坐标（用于判断是否从左边缘开始）。
  double? _edgeDragStartDx;

  /// 左边缘滑动手势：起始点全局 y 坐标（保留以便将来扩展）。
  double? _edgeDragStartDy;

  /// 左边缘滑动手势：当前手势是否从左边缘激活。
  ///
  /// 仅当手势在屏幕最左 ~[_kEdgeSwipeZone] px 内启动时置为 true，
  /// 否则视为普通横向滑动（如横向滚动的列表/未来横向元素），不触发返回。
  bool _edgeDragActive = false;

  /// 左边缘滑动激活区宽度（屏幕左边缘起，px）。
  static const double _kEdgeSwipeZone = 30;

  /// 触发返回上一级的水平滑动速度阈值（px/s，正值向右）。
  /// 要求快速右滑，避免慢速横向拖动误触返回。
  static const double _kEdgeSwipeVelocity = 300;

  @override
  void dispose() {
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
      _searchController.clear();
      ref.read(searchQueryProvider.notifier).state = '';
      ref.read(browsePathProvider.notifier).state = item.path;
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
        EpubReaderPage.open(context, sourceId: source.id, file: item);
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
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    // 桌面端自定义标题栏使 Overlay 原点不在全局 (0,0)，需把鼠标全局坐标
    // 转成 Overlay 局部坐标，否则菜单会偏离鼠标位置。
    final local = overlay == null ? position : overlay.globalToLocal(position);
    final left = local.dx;
    final top = local.dy;
    final right = overlay == null ? 0.0 : overlay.size.width - left;
    final bottom = overlay == null ? 0.0 : overlay.size.height - top;
    final action = await showMenu<String>(
      context: context,
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
        const PopupMenuDivider(),
        _menuItem('rename', LucideIcons.pencil, '重命名'),
        _menuItem('move', LucideIcons.folderInput, '移动到…'),
        _menuItem('copy', LucideIcons.copy, '复制到…'),
        const PopupMenuDivider(),
        _menuItem('delete', LucideIcons.trash2, '删除', destructive: true),
      ],
    );
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
                      onSelected: (action) => _onMenuAction(action),
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
                // 左边缘滑动返回上一级（移动端）：包裹文件列表区域，
                // 仅捕获"从左边缘向右的快速滑动"，不影响列表的垂直滚动
                // 与内部横向元素（behavior: translucent 不拦截命中）。
                // 注意：Expanded 必须直接作为 Column(Flex) 的子级，
                // 不能放在 GestureDetector(Listener) 内部，否则抛
                // "Incorrect use of ParentDataWidget" 导致文件区域塌陷为灰色空白。
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragStart: _onEdgeDragStart,
                    onHorizontalDragEnd: _onEdgeDragEnd,
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
                                ref.read(searchQueryProvider.notifier).state =
                                    v,
                          ),
                        ),
                        Positioned.fill(
                          child: DropTarget(
                            onDragDone: (details) => _dropUpload(
                              details.files.map((f) => f.path).toList(),
                            ),
                            child: Container(
                              decoration: BoxDecoration(
                                color: theme.cardTheme.color,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: NotificationListener<ScrollNotification>(
                                onNotification: _onScrollNotify,
                                child: Column(
                                  children: [
                                    // 非根目录时提供 ".." 返回上级
                                    // 网格模式下 ".." 以卡片形式插入网格首位（见 FileGridView）
                                    if (path != '/' &&
                                        viewMode == BrowseViewMode.list)
                                      _ParentEntry(
                                        onTap: () =>
                                            ref
                                                .read(
                                                  browsePathProvider.notifier,
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
                          const Positioned.fill(child: _LocatingOverlay()),
                      ],
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
        final cur = ref.read(viewModeProvider);
        ref.read(viewModeProvider.notifier).state = cur == BrowseViewMode.grid
            ? BrowseViewMode.list
            : BrowseViewMode.grid;
      case _BrowseMenuAction.mkdir:
        _mkdir();
      case _BrowseMenuAction.trash:
        context.push('/trash');
    }
  }

  /// 左边缘滑动手势开始：记录起始点，判断是否在屏幕左边缘激活区。
  ///
  /// 说明：只有当手势从屏幕最左侧（[_kEdgeSwipeZone] px 内）启动，才
  /// 视为"返回上一级"手势；从屏幕其他位置开始的水平滑动保持原样，
  /// 不拦截列表的横向滚动等正常交互。
  void _onEdgeDragStart(DragStartDetails details) {
    final dx = details.globalPosition.dx;
    _edgeDragStartDx = dx;
    _edgeDragStartDy = details.globalPosition.dy;
    _edgeDragActive = dx <= _kEdgeSwipeZone;
  }

  /// 左边缘滑动手势结束：快速右滑时返回上一级目录（或退出多选）。
  void _onEdgeDragEnd(DragEndDetails details) {
    final wasActive = _edgeDragActive;
    _edgeDragActive = false;
    final startDx = _edgeDragStartDx;
    _edgeDragStartDx = null;
    _edgeDragStartDy = null;
    if (!wasActive || startDx == null) return;
    // 仅处理向右的快速滑动，避免慢速横向拖动或向左滑动误触。
    if (details.primaryVelocity == null ||
        details.primaryVelocity! < _kEdgeSwipeVelocity) {
      return;
    }
    // 与系统返回手势（PopScope）一致：多选中先退出多选，否则返回上级目录。
    if (ref.read(selectionModeProvider)) {
      ref.read(selectionProvider.notifier).clear();
    } else {
      final currentPath = ref.read(browsePathProvider);
      if (currentPath != '/') {
        ref.read(browsePathProvider.notifier).state = parentPathOf(currentPath);
      }
    }
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
        final longPressMenu = !isDesktopPlatform && !selectionMode
            ? _showItemMenu
            : null;
        final favoritePaths = ref.watch(favoritePathsProvider);
        final favoriteSourceId = ref.read(effectiveSourceProvider)?.id;
        final favoriteNotifier = ref.read(favoriteListProvider.notifier);
        final highlightPath = ref.watch(highlightFileProvider);
        void toggleFavorite(FileItem f) {
          final sourceId = favoriteSourceId;
          if (sourceId == null) return;
          _run(() => favoriteNotifier.toggle(sourceId, f.path));
        }

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
                  : null,
              onLongPressMenu: longPressMenu,
              favoritePaths: favoritePaths,
              favoriteSourceId: favoriteSourceId,
              onToggleFavorite: toggleFavorite,
              onShowMenu: _showItemMenu,
              highlightPath: highlightPath,
              highlightKey: isGrid ? _highlightKey : null,
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
                  : null,
              onLongPressMenu: longPressMenu,
              favoritePaths: favoritePaths,
              favoriteSourceId: favoriteSourceId,
              onToggleFavorite: toggleFavorite,
              onShowMenu: _showItemMenu,
              highlightPath: highlightPath,
              highlightKey: isGrid ? null : _highlightKey,
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
                  Text(
                    '${_fieldLabel(field)}${asc ? '（升序）' : '（降序）'}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
      ],
    );
    if (picked != null) {
      ref.read(sortProvider.notifier).update(picked);
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
    return InkWell(
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
                // 占位列，对齐普通行右侧三列（大小 / 时间 / 收藏按钮），
                // 视觉上让 "返回上级" 行的右端与下方条目保持同一基准线。
                const Expanded(flex: 2, child: SizedBox()),
                const Expanded(flex: 2, child: SizedBox()),
                const SizedBox(width: 40),
              ],
            ),
          ),
          // 与文件行的分割线保持一致的缩进
          const Divider(height: 1, indent: 54, endIndent: 56),
        ],
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
          // 右侧可横向滚动区域：全选 + 5 个操作按钮。
          // 关闭按钮在左，剩余宽度可能只有 ~210px，
          // 5 个 IconButton 一起放不下，因此整体可横滑。
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
                  IconButton(
                    icon: Icon(
                      LucideIcons.trash2,
                      size: 16,
                      color: colorScheme.error,
                    ),
                    onPressed: onDelete,
                    tooltip: '删除',
                    visualDensity: VisualDensity.compact,
                  ),
                  // 尾部留白，避免最后一个按钮紧贴边缘。
                  const SizedBox(width: 4),
                ],
              ),
            ),
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
