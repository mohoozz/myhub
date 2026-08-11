import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/features/browse/widgets/file_cover.dart';
import 'package:myhub_flutter/shared/utils/format.dart';

/// 文件网格视图。
class FileGridView extends StatelessWidget {
  const FileGridView({
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
    this.onParentTap,
    this.highlightPath,
    this.highlightKey,
    this.onLongPress,
    this.nameLines = 1,
    super.key,
  });

  final List<FileItem> items;
  final ValueChanged<FileItem> onOpen;

  /// 滚动控制器（用于大目录下高亮定位时先按索引估算滚动位置）。
  final ScrollController? controller;
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

  /// 非空时在网格首位插入 ".." 返回上级卡片。
  final VoidCallback? onParentTap;

  /// 高亮定位文件路径：匹配项显示高亮边框。
  final String? highlightPath;

  /// 高亮项的 GlobalKey（供上层滚动定位）。
  final GlobalKey? highlightKey;

  /// 文件名显示行数（1~3）。多行时网格单元高度自适应，避免长文件名显示不全。
  final int nameLines;

  @override
  Widget build(BuildContext context) {
    final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    // 依据实际可用宽度计算列数与单元宽度，再按名称行数推导单元高度：
    // 保证名称多行时卡片内容完整展示，不会溢出或被截断。
    final grid = LayoutBuilder(
      builder: (context, constraints) {
        const maxExtent = 140.0;
        const spacing = 12.0;
        const hPadding = 24.0; // EdgeInsets.all(12) 左右各 12
        final available =
            (constraints.maxWidth - hPadding).clamp(0.0, 1e9).toDouble();
        final cols = ((available + spacing) / (maxExtent + spacing))
            .floor()
            .clamp(1, 100);
        final cellWidth = (available - spacing * (cols - 1)) / cols;
        // 封面最大 72×72（与 _FileCard 内 ConstrainedBox 一致）；
        // 窄屏单列时封面随 cell 宽度放大，但不超过 72。
        final coverHeight = math
            .min(cellWidth - 20, 72.0)
            .clamp(40.0, 72.0)
            .toDouble();
        // 名称行高：移动端 bodyMedium 较大，桌面端 bodySmall 较小；留少量缓冲。
        final nameLineHeight = isMobile ? 21.0 : 17.5;
        final metaHeight = isMobile ? 20.0 : 16.0;
        final cellHeight =
            10 + coverHeight + 10 + nameLines * nameLineHeight + 4 + metaHeight + 10;
        return GridView.builder(
          controller: controller,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(12),
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: maxExtent,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            mainAxisExtent: cellHeight,
          ),
          itemCount: items.length + (onParentTap == null ? 0 : 1),
          itemBuilder: (context, index) {
            if (onParentTap != null) {
              if (index == 0) return _ParentCard(onTap: onParentTap!);
              index--;
            }
            final item = items[index];
            final highlighted =
                highlightPath != null && item.path == highlightPath;
            Widget card = _FileCard(
              item: item,
              coverSourceId: coverSourceId,
              selectionMode: selectionMode,
              selected: selectedPaths.contains(item.path),
              highlighted: highlighted,
              nameLines: nameLines,
              onTap: () =>
                  selectionMode ? onToggleSelect?.call(item) : onOpen(item),
              onLongPress: onLongPress == null
                  ? null
                  : () => onLongPress!(item),
              onSecondaryTapUp: onShowMenu == null
                  ? null
                  : (d) => onShowMenu!(item, d.globalPosition),
              onLongPressMenu: onLongPressMenu == null
                  ? null
                  : (d) => onLongPressMenu!(item, d.globalPosition),
            );
            if (highlighted && highlightKey != null) {
              card = KeyedSubtree(key: highlightKey, child: card);
            }
            return card;
          },
        );
      },
    );
    if (onRefresh == null) return grid;
    return RefreshIndicator(onRefresh: onRefresh!, child: grid);
  }
}

/// ".." 返回上级卡片（网格首位）。
class _ParentCard extends StatelessWidget {
  const _ParentCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: theme.cardTheme.color,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 72),
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: Center(
                        child: Icon(
                          LucideIcons.folderUp,
                          size: 36,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '..',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: isMobile
                    ? theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      )
                    : theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Text(
                '返回上级',
                style: isMobile
                    ? theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )
                    : theme.textTheme.bodySmall?.copyWith(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FileCard extends StatelessWidget {
  const _FileCard({
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
  });

  final FileItem item;

  /// 当前路径源 ID（封面缩略图加载用）。
  final int? coverSourceId;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selectionMode;
  final bool selected;

  /// 高亮定位提示（来自"正在阅读"页跳转）。
  final bool highlighted;

  /// 文件名显示行数（1~3）。
  final int nameLines;
  final GestureTapUpCallback? onSecondaryTapUp;

  /// 移动端长按（非多选模式）呼出上下文菜单，携带按下位置。
  final GestureLongPressStartCallback? onLongPressMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    // 移动端字号放大：参考"正在阅读"卡片标题（bodyMedium + w600）与
    // 说明文字，iOS 窄屏下文件名/说明不再显得偏小。桌面端保持原样。
    final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    // 文件名：移动端用正文大号 + 加粗；桌面端保持 bodySmall + 高亮加粗。
    final nameStyle = isMobile
        ? theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: highlighted ? colorScheme.primary : null,
          )
        : theme.textTheme.bodySmall?.copyWith(
            color: highlighted ? colorScheme.primary : null,
            fontWeight: highlighted ? FontWeight.w600 : null,
          );
    // 二级说明文字（文件夹/大小）：移动端用 bodySmall(13px)，桌面端 12px。
    final metaStyle = isMobile
        ? theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          )
        : theme.textTheme.bodySmall?.copyWith(
            fontSize: 12,
            color: colorScheme.onSurfaceVariant,
          );
    // 外层处理移动端长按弹菜单：该手势仅在桌面端长按（进入多选）为空时注册，
    // 与内层 InkWell 的长按手势互斥，不会同时响应。
    return GestureDetector(
      onLongPressStart: onLongPressMenu,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTapUp: onSecondaryTapUp,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: theme.cardTheme.color,
            borderRadius: BorderRadius.circular(12),
            border: highlighted
                ? Border.all(color: colorScheme.primary, width: 1.6)
                : selected
                ? Border.all(color: colorScheme.primary, width: 1.5)
                : null,
          ),
          child: Stack(
            children: [
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 72),
                          child: AspectRatio(
                            aspectRatio: 1,
                            child: FileCover(
                              item: item,
                              sourceId: coverSourceId,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      item.name,
                      maxLines: nameLines,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: nameStyle,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.isDir ? '文件夹' : formatBytes(item.size),
                      style: metaStyle,
                    ),
                  ],
                ),
              ),
              if (selectionMode)
                Positioned(
                  top: 0,
                  right: 0,
                  child: Icon(
                    selected ? LucideIcons.circleCheck : LucideIcons.circle,
                    size: 18,
                    color: selected
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
