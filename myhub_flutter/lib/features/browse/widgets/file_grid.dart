import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/features/browse/widgets/file_cover.dart';
import 'package:myhub_flutter/features/browse/widgets/file_status_indicator.dart';
import 'package:myhub_flutter/shared/utils/format.dart';
import 'package:myhub_flutter/shared/widgets/breathe_border.dart';

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
    this.onParentTap,
    this.highlightPath,
    this.highlightKey,
    this.onLongPress,
    this.nameLines = 1,
    this.progressByPath = const {},
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

  /// 非空时在网格首位插入 ".." 返回上级卡片。
  final VoidCallback? onParentTap;

  /// 高亮定位文件路径：匹配项显示高亮边框。
  final String? highlightPath;

  /// 高亮项的 GlobalKey（供上层滚动定位）。
  final GlobalKey? highlightKey;

  /// 文件名显示行数（1~3）。多行时网格单元高度自适应，避免长文件名显示不全。
  final int nameLines;

  /// 文件路径 -> 阅读进度百分比（null 值表示无历史记录）。
  final Map<String, double?> progressByPath;

  @override
  Widget build(BuildContext context) {
    final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    // 依据实际可用宽度计算列数与单元宽度，按 QQ 音乐红框风格的横向卡片布局：
    // ┌──────────────────────────┐
    // │  文件名 1~3行   ┌──┐  │
    // │  作者/说明      │封│  │  ← 圆形封面在右侧
    // │  size           └──┘  │
    // └──────────────────────────┘
    // 颜色块为卡片底色（按文件类型取明亮渐变色），文字白色。
    final grid = LayoutBuilder(
      builder: (context, constraints) {
        const maxExtent = 140.0; // iOS Files 风格格子最大宽度
        const spacing = 12.0;
        // const hPadding = 24.0; // EdgeInsets.all(12) 左右各 12
        // 列数现在不再用于计算 cellWidth——iOS Files 风格格子固定
        // maxExtent = 140px，配合 SliverGridDelegateWithMaxCrossAxisExtent
        // 让 Flutter 自动按列布局。
        // 名称行高：移动端 bodyMedium 较大，桌面端 bodySmall 较小。
        final nameLineHeight = isMobile ? 17.0 : 14.0;
        // 副标题行高（11px labelSmall）。
        final metaLineHeight = isMobile ? 14.0 : 12.0;
        // iOS Files 风格 cell 高度：
        //   * 顶部 padding 8
        //   * 封面 56
        //   * 间距 8
        //   * 标题 1~3 行
        //   * 间距 2
        //   * 副标题 1 行
        //   * 底部 padding 8
        final cellHeight =
            8 +
            56 + // 封面固定 56 高
            8 +
            nameLines * nameLineHeight +
            2 +
            metaLineHeight +
            8;
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
              progressPercent: progressByPath[item.path],
              onTap: () =>
                  selectionMode ? onToggleSelect?.call(item) : onOpen(item),
              onLongPress: onLongPress == null
                  ? null
                  : () => onLongPress!(item),
              onSecondaryTapUp: onShowMenu == null
                  ? null
                  : (d) => onShowMenu!(item, d.globalPosition),
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
    // 局部 Material：ink 悬停高亮绘制在卡片自身表面，不被外层容器遮挡。
    return Material(
      color: theme.cardTheme.color,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(10),
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
    this.progressPercent,
    this.onSecondaryTapUp,
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

  /// 该文件的阅读进度百分比（null = 无历史）。
  final double? progressPercent;
  final GestureTapUpCallback? onSecondaryTapUp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);

    // iOS Files 风格卡片：
    //   ┌────────────────┐
    //   │     ┌──┐         │
    //   │     │封│         │
    //   │     │面│         │
    //   │     └──┘         │
    //   │  标题（居中）     │
    //   │  副标题           │
    //   │       ⋮            │ ← "..." 仅移动端可见
    //   └────────────────┘
    // 整张卡片：浅灰背景（surfaceContainerHigh）+ 大封面图标居中。
    final subtitle = _subtitleText();

    // 卡片级 Material：ink（悬停高亮/水波纹）绘制在卡片自身表面，
    // 不再被浏览页外层卡片容器遮挡，与「正在阅读」的悬停效果一致。
    final card = Material(
      color: theme.cardTheme.color ?? colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTapUp: onSecondaryTapUp,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: selected
                ? Border.all(color: colorScheme.primary, width: 1.5)
                : null,
          ),
          child: Stack(
            children: [
              // 主体：封面 + 标题 + 副标题（垂直居中）
              Center(
                child: Padding(
                  // 顶部预留 8 让封面"上方留白"——iOS Files 中图标与卡片边
                  // 距都比较大，让卡片看起来舒展。
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // 大封面/类型图标：固定 56x56 圆角方块（iOS Files 比例）
                      SizedBox(
                        width: 56,
                        height: 56,
                        child: FileCover(
                          item: item,
                          sourceId: coverSourceId,
                          iconSize: 32,
                          borderRadius: 12,
                        ),
                      ),
                      const SizedBox(height: 8),
                      // 标题（加粗、居中、1~3 行省略）
                      PlayingFileTitle(
                        text: item.name,
                        itemPath: item.path,
                        sourceId: coverSourceId,
                        maxLines: nameLines,
                        baseStyle: isMobile
                            ? theme.textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: highlighted ? colorScheme.primary : null,
                              )
                            : theme.textTheme.bodySmall?.copyWith(
                                color: highlighted ? colorScheme.primary : null,
                                fontWeight: highlighted
                                    ? FontWeight.w600
                                    : null,
                              ),
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant.withValues(
                              alpha: 0.7,
                            ),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              // 右上角状态指示：正在播放动画 / 阅读进度圆环。
              // 多选模式下隐藏（右上角由勾选图标占用）。
              if (!selectionMode)
                Positioned(
                  top: 8,
                  right: 8,
                  child: FileStatusIndicator(
                    item: item,
                    sourceId: coverSourceId,
                    progressPercent: progressPercent,
                    size: 16,
                  ),
                ),
              // 多选模式：右上角勾选环
              if (selectionMode)
                Positioned(
                  top: 6,
                  right: 6,
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
    // 高亮定位：用呼吸灯边框包裹整张卡片（提示由上层定时熄灭）。
    if (highlighted) {
      return BreathingBorder(
        borderRadius: BorderRadius.circular(12),
        child: card,
      );
    }
    return card;
  }

  /// 副标题（iOS Files 风格）：目录显示"目录"，文件显示格式字节数。
  String _subtitleText() {
    if (item.isDir) return '目录';
    return formatBytes(item.size);
  }
}
