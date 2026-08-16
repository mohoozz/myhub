import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/api/file_api.dart';
import 'package:myhub_flutter/core/models/reading_progress.dart';
import 'package:myhub_flutter/core/models/source.dart';
import 'package:myhub_flutter/core/router/app_router.dart';
import 'package:myhub_flutter/core/settings/settings_provider.dart';
import 'package:myhub_flutter/data/repositories/progress_repository.dart';
import 'package:myhub_flutter/features/browse/providers/browse_provider.dart';
import 'package:myhub_flutter/features/browse/widgets/file_dialogs.dart';
import 'package:myhub_flutter/features/reading/providers/reading_provider.dart';
import 'package:myhub_flutter/shared/providers/source_provider.dart';
import 'package:myhub_flutter/shared/utils/format.dart';
import 'package:myhub_flutter/shared/utils/open_media.dart';
import 'package:myhub_flutter/shared/utils/top_snack_bar.dart';
import 'package:myhub_flutter/shared/widgets/reading_card.dart';
import 'package:myhub_flutter/shared/widgets/window_title_bar.dart'
    show isDesktopPlatform;

/// "正在阅读"首页：全部阅读进度卡片（含已读完），支持网格/列表视图；
/// 点击续读，长按或"多选"按钮进入多选模式后可批量删除阅读记录；
/// PC 端右键弹出上下文菜单，支持定位到源路径位置 / 删除阅读记录。
class ReadingScreen extends ConsumerStatefulWidget {
  const ReadingScreen({super.key});

  @override
  ConsumerState<ReadingScreen> createState() => _ReadingScreenState();
}

/// PC 端右键 / 移动端长按菜单项。
enum _ReadingMenuAction { info, locate, delete }

/// 标题栏「...」菜单项：多选 / 刷新。
enum _HeaderMenuAction { toggleView, select, refresh }

class _ReadingScreenState extends ConsumerState<ReadingScreen> {
  /// 多选选中集合，key 为 "sourceId|filePath"。
  final Set<String> _selected = {};

  /// 强制多选模式：允许空选状态下也展示多选操作栏（由"一键多选"按钮进入）。
  bool _forceSelectionMode = false;

  bool get _selectionMode => _forceSelectionMode || _selected.isNotEmpty;

  String _key(ReadingProgress p) => '${p.sourceId}|${p.filePath}';

  /// 一键进入多选模式（不预选任何条目）。
  void _enterSelectionEmpty() {
    if (_selectionMode) return;
    setState(() {
      _forceSelectionMode = true;
    });
  }

  void _toggleSelect(ReadingProgress p) {
    final k = _key(p);
    setState(() {
      if (!_selected.add(k)) _selected.remove(k);
    });
  }

  void _selectAll(List<ReadingProgress> items) {
    setState(() {
      _forceSelectionMode = true;
      _selected
        ..clear()
        ..addAll(items.map(_key));
    });
  }

  void _clearSelection() {
    if (_selected.isEmpty && !_forceSelectionMode) return;
    setState(() {
      _selected.clear();
      _forceSelectionMode = false;
    });
  }

  /// 进入对应阅读器/播放器（进度由各页面自行恢复），返回后刷新列表。
  /// 从阅读历史进入的 txt：直接走小说阅读器（记录阅读进度，且能恢复历史进度）。
  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    ReadingProgress p,
  ) async {
    await openMediaItem(
      context,
      ref,
      sourceId: p.sourceId,
      filePath: p.filePath,
      mediaType: p.mediaType,
      novelReader: true,
    );
    if (!context.mounted) return;
    await ref.read(readingListProvider.notifier).refresh();
  }

  /// 批量删除阅读记录（先确认，再逐个删除；离线时本地标记待同步删除）。
  Future<void> _deleteSelected() async {
    final items = ref.read(readingListProvider).valueOrNull ?? const [];
    final selectedItems = items
        .where((p) => _selected.contains(_key(p)))
        .toList(growable: false);
    if (selectedItems.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除阅读记录'),
        content: Text('将删除选中的 ${selectedItems.length} 条阅读记录，确定删除吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final notifier = ref.read(readingListProvider.notifier);
    try {
      for (final p in selectedItems) {
        await notifier.delete(p.sourceId, p.filePath);
      }
    } catch (e) {
      if (mounted) showTopSnackBar(context, '操作失败：$e');
    }
    if (mounted) _clearSelection();
  }

  /// 批量删除源文件（与浏览页"删除"一致：移入回收站，可在回收站还原），
  /// 并联动清理对应文件的本地阅读记录。阅读记录可能来自多个路径源，
  /// 因此按 sourceId 分组逐个调用删除接口。
  Future<void> _deleteSourceFiles() async {
    final items = ref.read(readingListProvider).valueOrNull ?? const [];
    final selectedItems = items
        .where((p) => _selected.contains(_key(p)))
        .toList(growable: false);
    if (selectedItems.isEmpty) return;

    final confirmed = await showDeleteConfirmDialog(context, selectedItems.length);
    if (!(confirmed ?? false) || !mounted) return;

    final api = ref.read(fileApiProvider);
    final progressRepo = ref.read(progressRepositoryProvider);
    final bySource = <int, List<String>>{};
    for (final p in selectedItems) {
      bySource.putIfAbsent(p.sourceId, () => []).add(p.filePath);
    }
    try {
      for (final e in bySource.entries) {
        await api.deleteFiles(e.key, e.value);
        // 清理被删文件的本地阅读记录，避免"正在阅读"仍展示已删除文件。
        for (final path in e.value) {
          await progressRepo.deleteByPath(e.key, path);
        }
      }
      await ref.read(readingListProvider.notifier).refresh();
    } catch (e) {
      if (mounted) showTopSnackBar(context, '删除失败：$e');
    }
    if (mounted) _clearSelection();
  }

  /// PC 端右键 / 移动端长按：在对应位置弹出上下文菜单（信息/定位/删除）。
  Future<void> _showContextMenu(ReadingProgress p, Offset position) async {
    // 桌面端：锚定在鼠标位置的 showMenu 浮层。
    // 移动端：改为底部抽屉，避免菜单项过多时末尾项被顶出屏幕外不可见。
    final _ReadingMenuAction? action = isDesktopPlatform
        ? await _showContextMenuDesktop(p, position)
        : await _showContextMenuMobile(p);
    if (!mounted) return;
    switch (action) {
      case _ReadingMenuAction.info:
        await _showFileInfo(p);
      case _ReadingMenuAction.locate:
        _locateInBrowser(p);
      case _ReadingMenuAction.delete:
        await _confirmAndDeleteOne(p);
      case null:
        break;
    }
  }

  /// 桌面端右键菜单：锚定在鼠标位置弹出 showMenu。
  Future<_ReadingMenuAction?> _showContextMenuDesktop(
    ReadingProgress p,
    Offset position,
  ) {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    // 桌面端自定义标题栏使 Overlay 原点不在全局 (0,0)，需把鼠标全局坐标
    // 转成 Overlay 局部坐标，否则菜单会偏离鼠标位置。
    final local =
        overlay == null ? position : overlay.globalToLocal(position);
    final left = local.dx;
    final top = local.dy;
    final right = overlay == null ? 0.0 : overlay.size.width - left;
    final bottom = overlay == null ? 0.0 : overlay.size.height - top;
    return showMenu<_ReadingMenuAction>(
      context: context,
      position: RelativeRect.fromLTRB(left, top, right, bottom),
      items: const [
        PopupMenuItem(
          value: _ReadingMenuAction.info,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(LucideIcons.info, size: 16),
            title: Text('文件信息'),
          ),
        ),
        PopupMenuItem(
          value: _ReadingMenuAction.locate,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(LucideIcons.locateFixed, size: 16),
            title: Text('定位到源路径位置'),
          ),
        ),
        PopupMenuItem(
          value: _ReadingMenuAction.delete,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(LucideIcons.trash2, size: 16),
            title: Text('删除阅读记录'),
          ),
        ),
      ],
    );
  }

  /// 移动端长按菜单：底部抽屉，内容可滚动，所有项都能触达。
  Future<_ReadingMenuAction?> _showContextMenuMobile(ReadingProgress p) {
    return showModalBottomSheet<_ReadingMenuAction>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _sheetMenuTile(
                  sheetContext,
                  LucideIcons.info,
                  '文件信息',
                  () => Navigator.of(sheetContext)
                      .pop(_ReadingMenuAction.info),
                ),
                _sheetMenuTile(
                  sheetContext,
                  LucideIcons.locateFixed,
                  '定位到源路径位置',
                  () => Navigator.of(sheetContext)
                      .pop(_ReadingMenuAction.locate),
                ),
                _sheetMenuTile(
                  sheetContext,
                  LucideIcons.trash2,
                  '删除阅读记录',
                  destructive: true,
                  () => Navigator.of(sheetContext)
                      .pop(_ReadingMenuAction.delete),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 移动端底部抽屉菜单项（与浏览页 _sheetTile 风格保持一致）。
  Widget _sheetMenuTile(
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

  /// 展示文件属性：路径源名称、文件路径、名称、大小、修改时间、媒体类型、阅读进度。
  Future<void> _showFileInfo(ReadingProgress p) async {
    final sources = ref.read(sourceListProvider).valueOrNull ?? const [];
    final source = sources.where((s) => s.id == p.sourceId).firstOrNull;
    final sourceName = source?.name ?? '未知';
    final name = p.title.isNotEmpty ? p.title : p.filePath.split('/').last;
    final fileInfoFuture = ref
        .read(fileApiProvider)
        .fileInfo(p.sourceId, p.filePath);

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('文件信息'),
        content: SizedBox(
          width: 380,
          child: FutureBuilder<Map<String, dynamic>>(
            future: fileInfoFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const SizedBox(
                  height: 120,
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                );
              }
              if (snapshot.hasError) {
                return Text(
                  '加载失败：${snapshot.error}',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                );
              }
              final info = snapshot.data ?? <String, dynamic>{};
              final size = (info['size'] as num?)?.toInt() ?? 0;
              final modTime = info['mod_time'] is String
                  ? DateTime.tryParse(info['mod_time'] as String)
                  : null;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _InfoRow(label: '名称', value: name),
                  _InfoRow(label: '路径源', value: sourceName),
                  _InfoRow(label: '文件路径', value: p.filePath),
                  _InfoRow(label: '大小', value: formatBytes(size)),
                  _InfoRow(label: '修改时间', value: formatModTime(modTime)),
                  _InfoRow(
                    label: '媒体类型',
                    value: _mediaTypeLabel(info['media_type'] as String?),
                  ),
                  _InfoRow(
                    label: '阅读进度',
                    value: p.finished
                        ? '已读完'
                        : '${p.percent.toStringAsFixed(0)}%',
                  ),
                  _InfoRow(label: '记录时间', value: formatModTime(p.updatedAt)),
                ],
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 单条删除（弹确认对话框后执行）。
  Future<void> _confirmAndDeleteOne(ReadingProgress p) async {
    final title = p.title.isNotEmpty ? p.title : p.filePath.split('/').last;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除阅读记录'),
        content: Text('将删除「$title」的阅读记录，确定删除吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref
          .read(readingListProvider.notifier)
          .delete(p.sourceId, p.filePath);
    } catch (e) {
      if (mounted) showTopSnackBar(context, '操作失败：$e');
    }
  }

  /// 跳转到浏览页并定位到该记录对应的源文件：
  /// 切换到所属路径源 → 进入文件所在目录 → 高亮提示该文件。
  void _locateInBrowser(ReadingProgress p) {
    final sources = ref.read(sourceListProvider).valueOrNull ?? const [];
    final source = sources.where((s) => s.id == p.sourceId).firstOrNull;
    if (source == null) {
      showTopSnackBar(context, '对应的路径源不存在或已被删除');
      return;
    }
    // 依次切换路径源、进入所在目录、标记高亮目标，再切到浏览 Tab
    ref.read(currentSourceProvider.notifier).state = source;
    ref.read(browsePathProvider.notifier).state = parentPathOf(p.filePath);
    // 先重置为 null 再设置：即使对同一个文件重复"定位到浏览页"，
    // 也能强制触发 highlightFileProvider 变化，从而让浏览页重新滚动定位
    // （否则 provider 值不变，ref.listen 不会回调，第二次起定位失效）。
    ref.read(highlightFileProvider.notifier).state = null;
    ref.read(highlightFileProvider.notifier).state = p.filePath;
    final shell = StatefulNavigationShell.of(context);
    shell.goBranch(AppBranches.browse, initialLocation: false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final progressAsync = ref.watch(readingListProvider);
    final viewMode = ref.watch(readingViewModeProvider);
    final sources =
        ref.watch(sourceListProvider).valueOrNull ?? const <Source>[];
    final sourceNameMap = <int, String>{for (final s in sources) s.id: s.name};

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: Padding(
          // 顶部间距：移动端顶部安全区 / Dynamic Island 已由父级 SafeArea
          // 处理，这里只保留一个轻量内边距让标题与状态栏分开即可，
          // 避免红框中那种明显的额外空白。
          padding: const EdgeInsets.fromLTRB(7, 8, 7, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(theme, colorScheme, progressAsync, viewMode),
              const SizedBox(height: 12),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () =>
                      ref.read(readingListProvider.notifier).refresh(),
                  child: progressAsync.when(
                    loading: () => const Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                    error: (err, _) => _ErrorView(
                      error: err,
                      onRetry: () =>
                          ref.read(readingListProvider.notifier).refresh(),
                    ),
                    data: (items) => items.isEmpty
                        ? const _EmptyView()
                        : _buildContent(
                            items,
                            viewMode,
                            sourceNameMap: sourceNameMap,
                          ),
                  ),
                ),
              ),
              if (_selectionMode)
                _SelectionActionBar(
                  count: _selected.length,
                  onSelectAll: () =>
                      _selectAll(progressAsync.valueOrNull ?? const []),
                  onDelete: _deleteSelected,
                  onDeleteSource: _deleteSourceFiles,
                  onClose: _clearSelection,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(
    ThemeData theme,
    ColorScheme colorScheme,
    AsyncValue<List<ReadingProgress>> progressAsync,
    ReadingViewMode viewMode,
  ) {
    if (_selectionMode) {
      return Row(
        children: [
          Text(
            '已选 ${_selected.length} 项',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => _selectAll(progressAsync.valueOrNull ?? const []),
            child: const Text('全选'),
          ),
          IconButton(
            icon: const Icon(LucideIcons.x, size: 16),
            onPressed: _clearSelection,
            tooltip: '退出多选',
            visualDensity: VisualDensity.compact,
          ),
        ],
      );
    }
    return Row(
      children: [
        Text(
          '正在阅读',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '${progressAsync.valueOrNull?.length ?? 0} 项',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const Spacer(),
        // 视图切换 + 多选 + 刷新收纳到「...」菜单中，
        // 避免标题栏横向空间被挤占。
        PopupMenuButton<_HeaderMenuAction>(
          icon: const Icon(LucideIcons.ellipsis, size: 16),
          tooltip: '更多',
          onSelected: (action) {
            switch (action) {
              case _HeaderMenuAction.toggleView:
                ref.read(readingViewModeProvider.notifier).toggle();
              case _HeaderMenuAction.select:
                _enterSelectionEmpty();
              case _HeaderMenuAction.refresh:
                ref.read(readingListProvider.notifier).refresh();
            }
          },
          itemBuilder: (context) {
            return [
              // 视图切换：菜单顶部，图标与文案跟随当前模式动态变化。
              PopupMenuItem(
                value: _HeaderMenuAction.toggleView,
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    viewMode == ReadingViewMode.grid
                        ? LucideIcons.list
                        : LucideIcons.layoutGrid,
                    size: 16,
                  ),
                  title: Text(
                    viewMode == ReadingViewMode.grid ? '切换为列表' : '切换为网格',
                  ),
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: _HeaderMenuAction.select,
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(LucideIcons.checkSquare, size: 16),
                  title: Text('多选'),
                ),
              ),
              const PopupMenuItem(
                value: _HeaderMenuAction.refresh,
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(LucideIcons.rotateCw, size: 16),
                  title: Text('刷新'),
                ),
              ),
            ];
          },
        ),
      ],
    );
  }

  Widget _buildContent(
    List<ReadingProgress> items,
    ReadingViewMode viewMode, {
    required Map<int, String> sourceNameMap,
  }) {
    final selectionMode = _selectionMode;
    final titleLines = ref.watch(fileNameLinesProvider);
    String nameFor(ReadingProgress p) => sourceNameMap[p.sourceId] ?? '';
    // 多行显示文件名（标题）时，隐藏 sourceName 行：
    // 标题已占多行后，源名行会和文件名视觉冲突且挤占卡片高度，
    // 列表/网格两种视图统一按此规则。
    String visibleName(ReadingProgress p) =>
        titleLines > 1 ? '' : nameFor(p);
    return viewMode == ReadingViewMode.grid
        ? _buildGrid(items, titleLines, sourceNameMap)
        : ListView.separated(
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1, indent: 12),
            itemBuilder: (context, index) {
              final p = items[index];
              return ReadingListTile(
                progress: p,
                sourceName: visibleName(p),
                titleLines: titleLines,
                selectionMode: selectionMode,
                selected: _selected.contains(_key(p)),
                onTap: () =>
                    selectionMode ? _toggleSelect(p) : _open(context, ref, p),
                onLongPress: () => _toggleSelect(p),
                onShowMenu: (pos) => _showContextMenu(p, pos),
              );
            },
          );
  }

  /// 阅读历史网格：横向 QQ 音乐卡片（左侧文字 + 右侧圆形封面）。
  ///
  /// * 卡片比例：cellHeight = cellWidth * 0.78（横向 QQ 风，类似 16:10 转 5:4），
  ///   高度足够容纳圆形封面溢出 + 多行标题 + 进度条。
  /// * 标题行数：1~3 行自适应，2/3 行时隐藏源名（避免纵向拥挤）。
  Widget _buildGrid(
    List<ReadingProgress> items,
    int titleLines,
    Map<int, String> sourceNameMap,
  ) {
    final selectionMode = _selectionMode;
    String nameFor(ReadingProgress p) => sourceNameMap[p.sourceId] ?? '';
    return LayoutBuilder(
      builder: (context, constraints) {
        const maxExtent = 320.0;
        const spacing = 16.0;
        final available = constraints.maxWidth.clamp(0.0, 1e9).toDouble();
        // 列数：ceil 保证 cellWidth ≤ maxExtent。
        final cols = ((available + spacing) / (maxExtent + spacing))
            .ceil()
            .clamp(1, 100);
        final cellWidth = (available - spacing * (cols - 1)) / cols;
        // 横向卡片：cellHeight ≈ cellWidth * 0.78（约 5:4 比例），
        // 足够容纳：
        //   - 顶部类型图标 + 标题（最多 3 行）
        //   - 源名（仅 1 行标题时）
        //   - 进度信息
        //   - 进度条
        //   - 右侧圆形封面（d = cardHeight * 0.78，向右下溢出 15%）
        // 标题 2/3 行时整体高度不变（cellHeight 已预留圆形封面空间，
        // 多出的文字由 Spacer 吸收）。
        final cellHeight = cellWidth * 0.78;
        return GridView.builder(
          padding: const EdgeInsets.only(bottom: 24),
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: maxExtent,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            mainAxisExtent: cellHeight,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final p = items[index];
            return ReadingCard(
              progress: p,
              sourceName: titleLines > 1 ? '' : nameFor(p),
              titleLines: titleLines,
              selectionMode: selectionMode,
              selected: _selected.contains(_key(p)),
              onTap: () =>
                  selectionMode ? _toggleSelect(p) : _open(context, ref, p),
              onLongPress: () => _toggleSelect(p),
              onShowMenu: (pos) => _showContextMenu(p, pos),
            );
          },
        );
      },
    );
  }
}

/// 多选操作栏（多选模式时浮现于底部）。
class _SelectionActionBar extends StatelessWidget {
  const _SelectionActionBar({
    required this.count,
    required this.onSelectAll,
    required this.onDelete,
    required this.onDeleteSource,
    required this.onClose,
  });

  final int count;
  final VoidCallback onSelectAll;
  final VoidCallback onDelete;
  final VoidCallback onDeleteSource;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(12),
      ),
      // 按钮较多，右侧放入横向滚动区，避免窄屏被截断。
      child: Row(
        children: [
          IconButton(
            icon: const Icon(LucideIcons.x, size: 16),
            onPressed: onClose,
            tooltip: '取消多选',
            visualDensity: VisualDensity.compact,
          ),
          Text('已选 $count 项', style: theme.textTheme.bodySmall),
          // 中间可横向滚动区域：全选 + 删除记录。
          // 「删除源文件」单独固定在最右侧，避免「FilledButton.tonalIcon +
          // 长文案」的总宽度撑爆窄屏而被截断。
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
                  const SizedBox(width: 4),
                  FilledButton.tonalIcon(
                    onPressed: onDelete,
                    icon: const Icon(LucideIcons.trash2, size: 16),
                    label: const Text('删除记录'),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),
          // 固定在最右侧的「删除源文件」按钮：始终可见。
          // 用 IconButton + Tooltip 缩小宽度，避免与「删除记录」文案叠加
          // 导致窄屏上被裁切。
          IconButton(
            icon: Icon(
              LucideIcons.fileX2,
              size: 16,
              color: colorScheme.error,
            ),
            onPressed: onDeleteSource,
            tooltip: '删除源文件',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    // 空状态也保持可滚动，保证下拉刷新可用
    return ListView(
      children: [
        const SizedBox(height: 120),
        Icon(
          LucideIcons.bookOpen,
          size: 40,
          color: colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 10),
        Text(
          '还没有阅读记录，去浏览页看看吧',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      children: [
        const SizedBox(height: 120),
        Center(
          child: Column(
            children: [
              Text(
                '加载失败：$error',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
            ],
          ),
        ),
      ],
    );
  }
}

/// 文件信息对话框中的一行（标签 + 值）。
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 媒体类型 → 中文标签。
String _mediaTypeLabel(String? type) {
  switch (type) {
    case 'novel':
      return '小说';
    case 'comic':
      return '漫画';
    case 'video':
      return '视频';
    case 'audio':
      return '音频';
    case 'image':
      return '图片';
    case 'archive':
      return '压缩包';
    case 'dir':
      return '目录';
    default:
      return '其他';
  }
}
