import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/api/api_exception.dart';
import 'package:myhub_flutter/core/api/comic_api.dart';
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
import 'package:myhub_flutter/shared/widgets/comic_reader/comic_reader.dart';
import 'package:myhub_flutter/shared/widgets/media_player/media_player.dart';
import 'package:myhub_flutter/shared/widgets/novel_reader/epub_reader.dart';
import 'package:myhub_flutter/shared/widgets/novel_reader/novel_reader.dart';
import 'package:myhub_flutter/shared/widgets/source_selector.dart';

/// File browser page：路径源选择 + 面包屑 + 搜索 + 排序 + 网格/列表视图。
class BrowseScreen extends ConsumerStatefulWidget {
  const BrowseScreen({super.key});

  @override
  ConsumerState<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends ConsumerState<BrowseScreen> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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
      MediaPlayerPage.open(context, sourceId: source.id, file: item);
      return;
    }
    if (item.isNovel) {
      // 后端 novel 类型即 txt/epub
      final source = ref.read(effectiveSourceProvider);
      if (source == null) return;
      if (item.name.toLowerCase().endsWith('.epub')) {
        EpubReaderPage.open(context, sourceId: source.id, file: item);
      } else {
        NovelReaderPage.open(context, sourceId: source.id, file: item);
      }
      return;
    }
    if (item.isComic) {
      // cbz/cbr 扩展名直接判定为漫画
      final source = ref.read(effectiveSourceProvider);
      if (source == null) return;
      ComicReaderPage.open(context, sourceId: source.id, file: item);
      return;
    }
    if (item.isArchive) {
      // zip/rar 等普通压缩包：后端内容嗅探，漫画则路由到漫画阅读器
      final source = ref.read(effectiveSourceProvider);
      if (source == null) return;
      _openArchive(source.id, item);
      return;
    }
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text('打开 ${item.name}')));
  }

  /// 压缩包打开：漫画嗅探 → 漫画阅读器；否则提示（压缩包浏览后续提供）。
  Future<void> _openArchive(int sourceId, FileItem item) async {
    try {
      final res = await ref.read(comicApiProvider).detect(sourceId, item.path);
      if (!mounted) return;
      if (res['is_comic'] == true) {
        await ComicReaderPage.open(context, sourceId: sourceId, file: item);
        return;
      }
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('该压缩包不是漫画，暂不支持浏览')));
    } catch (e) {
      _showError(e);
    }
  }

  void _showError(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(e is ApiException ? e.message : '操作失败：$e'),
        ),
      );
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
    final target =
        await MoveTargetPicker.show(context, title: '移动到…');
    if (target == null) return;
    await _run(() => ref.read(fileActionsProvider).move(paths, target));
  }

  Future<void> _copySelected() async {
    final paths = ref.read(selectionProvider).toList();
    final target =
        await MoveTargetPicker.show(context, title: '复制到…');
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
    final items = ref
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
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('已加入收藏')));
    }
  }

  /// 右键上下文菜单（桌面端）：单条目打开/收藏/重命名/移动/复制/删除。
  Future<void> _showItemMenu(FileItem item, Offset position) async {
    final sourceId = ref.read(effectiveSourceProvider)?.id;
    final isFav = sourceId != null &&
        ref
            .read(favoritePathsProvider)
            .contains('$sourceId|${item.path}');
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        _menuItem('open', LucideIcons.squareArrowOutUpRight, '打开'),
        if (!item.isDir && sourceId != null)
          _menuItem(
            'favorite',
            LucideIcons.star,
            isFav ? '取消收藏' : '收藏',
          ),
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
    final colorScheme = theme.colorScheme;
    final source = ref.watch(effectiveSourceProvider);
    final path = ref.watch(browsePathProvider);
    final viewMode = ref.watch(viewModeProvider);
    final sort = ref.watch(sortProvider);
    final filesAsync = ref.watch(visibleFilesProvider);
    final selection = ref.watch(selectionProvider);

    // 系统返回手势兼容：多选中 → 退出多选；子目录 → 回上级；否则正常出栈
    return PopScope(
      canPop: selection.isEmpty && path == '/',
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (selection.isNotEmpty) {
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
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. 路径源选择器（小胶囊，左对齐）
              Align(
                alignment: Alignment.centerLeft,
                child: SourceSelector(
                  onChanged: (_) =>
                      ref.read(browsePathProvider.notifier).state = '/',
                ),
              ),
              const SizedBox(height: 10),
              // 2. 当前路径 + 同行右侧：搜索栏与操作按钮
              Row(
                children: [
                  Expanded(
                    child: BreadcrumbBar(
                      rootLabel: source?.name ?? '路径源',
                      path: path,
                      onNavigate: (target) =>
                          ref.read(browsePathProvider.notifier).state = target,
                    ),
                  ),
                  SizedBox(
                    width: 200,
                    height: 32,
                    child: TextField(
                      controller: _searchController,
                      onChanged: (v) =>
                          ref.read(searchQueryProvider.notifier).state = v,
                      style: theme.textTheme.bodySmall,
                      decoration: const InputDecoration(
                        hintText: '搜索当前目录...',
                        prefixIcon: Icon(LucideIcons.search, size: 14),
                        contentPadding: EdgeInsets.symmetric(vertical: 8),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _sortMenu(theme, sort),
                  IconButton(
                    icon: const Icon(LucideIcons.rotateCw, size: 16),
                    onPressed: () =>
                        ref.read(fileListProvider.notifier).refresh(),
                    tooltip: '刷新',
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    icon: const Icon(LucideIcons.layoutGrid, size: 16),
                    color: viewMode == BrowseViewMode.grid
                        ? colorScheme.primary
                        : null,
                    onPressed: () =>
                        ref.read(viewModeProvider.notifier).state =
                            BrowseViewMode.grid,
                    tooltip: '网格视图',
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    icon: const Icon(LucideIcons.list, size: 16),
                    color: viewMode == BrowseViewMode.list
                        ? colorScheme.primary
                        : null,
                    onPressed: () =>
                        ref.read(viewModeProvider.notifier).state =
                            BrowseViewMode.list,
                    tooltip: '列表视图',
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: 4),
                  FilledButton.icon(
                    onPressed: _pickAndUpload,
                    icon: const Icon(LucideIcons.upload, size: 14),
                    label: const Text('上传'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 30),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(LucideIcons.ellipsisVertical, size: 16),
                    tooltip: '更多',
                    position: PopupMenuPosition.under,
                    onSelected: (v) {
                      if (v == 'mkdir') _mkdir();
                      if (v == 'trash') context.push('/trash');
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem<String>(
                        value: 'mkdir',
                        child: Row(
                          children: [
                            Icon(
                              LucideIcons.folderPlus,
                              size: 16,
                              color: theme.colorScheme.onSurface,
                            ),
                            const SizedBox(width: 10),
                            const Text('新建文件夹'),
                          ],
                        ),
                      ),
                      PopupMenuItem<String>(
                        value: 'trash',
                        child: Row(
                          children: [
                            Icon(
                              LucideIcons.trash2,
                              size: 16,
                              color: theme.colorScheme.onSurface,
                            ),
                            const SizedBox(width: 10),
                            const Text('回收站'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
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
                    child: Column(
                      children: [
                        // 非根目录时提供 ".." 返回上级
                        if (path != '/')
                          _ParentEntry(
                            onTap: () => ref
                                .read(browsePathProvider.notifier)
                                .state = parentPathOf(path),
                          ),
                        Expanded(
                          child: _buildContent(filesAsync, viewMode),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (selection.isNotEmpty)
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
                  onClose: () =>
                      ref.read(selectionProvider.notifier).clear(),
                ),
            ],
          ),
        ),
        ),
      ),
    );
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
        final selectionNotifier = ref.read(selectionProvider.notifier);
        final selectionMode = selection.isNotEmpty;
        final favoritePaths = ref.watch(favoritePathsProvider);
        final favoriteSourceId = ref.read(effectiveSourceProvider)?.id;
        final favoriteNotifier = ref.read(favoriteListProvider.notifier);
        void toggleFavorite(FileItem f) {
          final sourceId = favoriteSourceId;
          if (sourceId == null) return;
          _run(() => favoriteNotifier.toggle(sourceId, f.path));
        }

        return IndexedStack(
          index: viewMode == BrowseViewMode.grid ? 0 : 1,
          children: [
            FileGridView(
              items: items,
              onOpen: _openItem,
              onRefresh: () => ref.read(fileListProvider.notifier).refresh(),
              selectionMode: selectionMode,
              selectedPaths: selection,
              onToggleSelect: (f) => selectionNotifier.toggle(f.path),
              onLongPress: (f) => selectionMode
                  ? selectionNotifier.toggle(f.path)
                  : selectionNotifier.enter(f.path),
              favoritePaths: favoritePaths,
              favoriteSourceId: favoriteSourceId,
              onToggleFavorite: toggleFavorite,
              onShowMenu: _showItemMenu,
            ),
            FileListView(
              items: items,
              onOpen: _openItem,
              onRefresh: () => ref.read(fileListProvider.notifier).refresh(),
              selectionMode: selectionMode,
              selectedPaths: selection,
              onToggleSelect: (f) => selectionNotifier.toggle(f.path),
              onLongPress: (f) => selectionMode
                  ? selectionNotifier.toggle(f.path)
                  : selectionNotifier.enter(f.path),
              favoritePaths: favoritePaths,
              favoriteSourceId: favoriteSourceId,
              onToggleFavorite: toggleFavorite,
              onShowMenu: _showItemMenu,
            ),
          ],
        );
      },
    );
  }

  Widget _sortMenu(ThemeData theme, SortSpec sort) {
    return PopupMenuButton<SortSpec>(
      tooltip: '排序',
      position: PopupMenuPosition.under,
      onSelected: (s) => ref.read(sortProvider.notifier).state = s,
      itemBuilder: (context) => [
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
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            sort.label,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 2),
          Icon(
            sort.ascending ? LucideIcons.arrowUp : LucideIcons.arrowDown,
            size: 12,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(
                  LucideIcons.folderUp,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Text(
                  '..',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          // 与文件行的分割线保持一致的缩进
          const Divider(height: 1, indent: 54),
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
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(LucideIcons.x, size: 16),
            onPressed: onClose,
            tooltip: '取消多选',
          ),
          Text(
            '已选 $count 项',
            style: theme.textTheme.bodySmall,
          ),
          TextButton(onPressed: onSelectAll, child: const Text('全选')),
          const Spacer(),
          IconButton(
            icon: const Icon(LucideIcons.folderInput, size: 16),
            onPressed: onMove,
            tooltip: '移动',
          ),
          IconButton(
            icon: const Icon(LucideIcons.copy, size: 16),
            onPressed: onCopy,
            tooltip: '复制',
          ),
          if (onRename != null)
            IconButton(
              icon: const Icon(LucideIcons.pencil, size: 16),
              onPressed: onRename,
              tooltip: '重命名',
            ),
          IconButton(
            icon: const Icon(LucideIcons.star, size: 16),
            onPressed: onFavorite,
            tooltip: '收藏',
          ),
          IconButton(
            icon: Icon(LucideIcons.trash2,
                size: 16, color: theme.colorScheme.error),
            onPressed: onDelete,
            tooltip: '删除',
          ),
        ],
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
              fontSize: 11,
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
