import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/features/browse/widgets/file_cover.dart';
import 'package:myhub_flutter/shared/utils/format.dart';

/// 文件列表视图（iOS Files 风格）。
///
/// 每行结构：
/// ┌────────────────────────────────────────────┐
/// │ ┌──┐                                       │
/// │ │封│  标题（一行加粗省略）                  │
/// │ │面│  TXT · 4 KB · 2026/8/9                │
/// │ └──┘                                       ⋮│
/// └────────────────────────────────────────────┘
/// * 移动端：去掉"修改时间"列 + 右下"..."菜单按钮（移动端通过长按弹菜单）
/// * 桌面端：标题右侧 8 字符宽大小列，便于快速扫读
class FileListView extends StatelessWidget {
  const FileListView({
    required this.items,
    required this.onOpen,
    this.controller,
    this.onRefresh,
    this.selectionMode = false,
    this.selectedPaths = const {},
    this.onToggleSelect,
    this.coverSourceId,
    this.onShowMenu,
    this.onLongPressMenu,
    this.highlightPath,
    this.highlightKey,
    this.onLongPress,
    this.nameLines = 1,
    super.key,
  });

  final List<FileItem> items;
  final ScrollController? controller;
  final ValueChanged<FileItem> onOpen;
  final Future<void> Function()? onRefresh;
  final bool selectionMode;
  final Set<String> selectedPaths;
  final ValueChanged<FileItem>? onToggleSelect;
  final ValueChanged<FileItem>? onLongPress;

  /// 当前路径源 ID（封面缩略图加载用）。
  final int? coverSourceId;

  /// 右键呼出上下文菜单（桌面端），携带点击全局坐标。
  final void Function(FileItem item, Offset position)? onShowMenu;

  /// 移动端长按（非多选模式）呼出与右键相同的上下文菜单。
  final void Function(FileItem item, Offset position)? onLongPressMenu;

  /// 高亮定位文件路径：匹配项显示高亮边框。
  final String? highlightPath;

  /// 高亮项的 GlobalKey（供上层滚动定位）。
  final GlobalKey? highlightKey;

  /// 文件名显示行数（1~3）。多行时行高自动增加，避免长文件名显示不全。
  final int nameLines;

  @override
  Widget build(BuildContext context) {
    final list = ListView.separated(
      controller: controller,
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: items.length,
      // 行间细线分隔（iOS Files 风格）：从图标后面开始到 "..." 按钮前结束。
      separatorBuilder: (_, __) =>
          const Divider(height: 1, indent: 60, endIndent: 56),
      itemBuilder: (context, index) {
        final item = items[index];
        final highlighted =
            highlightPath != null && item.path == highlightPath;
        Widget row = _FileRow(
          item: item,
          coverSourceId: coverSourceId,
          selectionMode: selectionMode,
          selected: selectedPaths.contains(item.path),
          highlighted: highlighted,
          nameLines: nameLines,
          onTap: () =>
              selectionMode ? onToggleSelect?.call(item) : onOpen(item),
          onLongPress: onLongPress == null ? null : () => onLongPress!(item),
          onSecondaryTapUp: onShowMenu == null
              ? null
              : (d) => onShowMenu!(item, d.globalPosition),
          onLongPressMenu: onLongPressMenu == null
              ? null
              : (d) => onLongPressMenu!(item, d.globalPosition),
          // 移动端 "..." 菜单按钮回调：复用 onShowMenu（同一上下文菜单），
          // 位置由按钮自身给出（与右键位置一致）。
          onShowRowMenu:
              onShowMenu == null ? null : (pos) => onShowMenu!(item, pos),
        );
        if (highlighted && highlightKey != null) {
          row = KeyedSubtree(key: highlightKey, child: row);
        }
        return row;
      },
    );
    if (onRefresh == null) return list;
    return RefreshIndicator(onRefresh: onRefresh!, child: list);
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.item,
    required this.coverSourceId,
    required this.onTap,
    required this.onLongPress,
    required this.selectionMode,
    required this.selected,
    this.highlighted = false,
    this.nameLines = 1,
    this.onSecondaryTapUp,
    this.onLongPressMenu,
    this.onShowRowMenu,
  });

  final FileItem item;
  final int? coverSourceId;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selectionMode;
  final bool selected;
  final bool highlighted;
  final int nameLines;
  final GestureTapUpCallback? onSecondaryTapUp;
  final GestureLongPressStartCallback? onLongPressMenu;

  /// 移动端 "..." 按钮点击回调：调用外层 onShowMenu(item, position)，
  /// 位置由按钮自身全局坐标给出。仅在非多选模式下注册。
  final void Function(Offset globalPosition)? onShowRowMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);

    // 第二行副标题（iOS Files 风格）：类型 · 大小 · 修改时间
    // 移动端：不显示"修改时间"，留"类型 · 大小"。
    final typeLabel = _typeLabel(item);
    final sizeLabel = item.isDir ? '-' : formatBytes(item.size);
    final subtitle = isMobile
        ? [typeLabel, sizeLabel]
            .where((s) => s.isNotEmpty && s != '-')
            .join(' · ')
        : [typeLabel, sizeLabel, formatModTime(item.modTime)]
            .where((s) => s.isNotEmpty && s != '-')
            .join(' · ');

    return GestureDetector(
      onLongPressStart: onLongPressMenu,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTapUp: onSecondaryTapUp,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? colorScheme.primary.withValues(alpha: 0.08)
                : null,
            border: highlighted
                ? Border.all(color: colorScheme.primary, width: 1.6)
                : null,
          ),
          child: Row(
            children: [
              if (selectionMode)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Icon(
                    selected ? LucideIcons.circleCheck : LucideIcons.circle,
                    size: 18,
                    color: selected
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                  ),
                ),
              // 左侧文件封面/类型图标：36x36（iOS Files 行高图标尺寸）
              SizedBox(
                width: 36,
                height: 36,
                child: FileCover(
                  item: item,
                  sourceId: coverSourceId,
                  iconSize: 22,
                  borderRadius: 7,
                ),
              ),
              const SizedBox(width: 14),
              // 中间：标题 + 副标题（双行，参考 iOS Files）
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      item.name,
                      maxLines: nameLines,
                      overflow: TextOverflow.ellipsis,
                      style: isMobile
                          ? theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color:
                                  highlighted ? colorScheme.primary : null,
                            )
                          : theme.textTheme.bodySmall?.copyWith(
                              color:
                                  highlighted ? colorScheme.primary : null,
                              fontWeight:
                                  highlighted ? FontWeight.w600 : null,
                            ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 12,
                          color:
                                colorScheme.onSurfaceVariant.withValues(
                              alpha: 0.75,
                            ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // 右侧 "..." 按钮：移动端可见（与 iOS Files 一致），
              // 桌面端省略（右键可触菜单）。
              if (!selectionMode && onShowRowMenu != null && isMobile)
                Builder(
                  builder: (innerContext) => InkResponse(
                    onTap: () {
                      // 弹上下文菜单：让菜单在按钮附近弹出。
                      final box =
                          innerContext.findRenderObject() as RenderBox?;
                      final pos = box != null
                          ? box.localToGlobal(
                              Offset(box.size.width / 2, box.size.height),
                            )
                          : Offset.zero;
                      onShowRowMenu!(pos);
                    },
                    radius: 18,
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(LucideIcons.ellipsis, size: 18),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 文件类型短标签（用于副标题）。
  String _typeLabel(FileItem item) {
    if (item.isDir) return '目录';
    if (item.isImage) return '图片';
    if (item.isVideo) return '视频';
    if (item.isAudio) return '音频';
    if (item.isNovel) return '小说';
    if (item.isComic) return '漫画';
    return '文件';
  }
}
