import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/features/browse/widgets/file_cover.dart';
import 'package:myhub_flutter/features/browse/widgets/file_status_indicator.dart';
import 'package:myhub_flutter/shared/utils/format.dart';

/// 文件列表视图（iOS Files 风格）。
///
/// 每行结构：
/// ┌────────────────────────────────────────────┐
/// │ ┌──┐                                       │
/// │ │封│  标题（一行加粗省略）                  │
/// │ │面│  TXT · 4 KB · 2026/8/9                │
/// │ └──┘                                       ◔│
/// └────────────────────────────────────────────┘
/// * 行尾状态指示：正在播放 → 三竖条动画；有阅读历史 → 饼状进度圆环
/// * 移动端：去掉"修改时间"列；长按可弹出上下文菜单
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
    this.progressByPath = const {},
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

  /// 文件路径 -> 阅读进度百分比（null 值表示无历史记录）。
  final Map<String, double?> progressByPath;

  @override
  Widget build(BuildContext context) {
    final list = ListView.separated(
      controller: controller,
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: items.length,
      // 行间细线分隔（iOS Files 风格）：从图标后面开始，左右两端留白对称。
      // 调整 endIndent 让右侧不再紧贴卡片边框，避免视觉上"尾部长"，
      // 与 favorites_screen.dart 中的对称缩进保持一致。
      separatorBuilder: (_, __) =>
          const Divider(height: 1, indent: 60, endIndent: 56),
      itemBuilder: (context, index) {
        final item = items[index];
        final highlighted = highlightPath != null && item.path == highlightPath;
        Widget row = _FileRow(
          item: item,
          coverSourceId: coverSourceId,
          selectionMode: selectionMode,
          selected: selectedPaths.contains(item.path),
          highlighted: highlighted,
          nameLines: nameLines,
          progressPercent: progressByPath[item.path],
          onTap: () =>
              selectionMode ? onToggleSelect?.call(item) : onOpen(item),
          onLongPress: onLongPress == null ? null : () => onLongPress!(item),
          onSecondaryTapUp: onShowMenu == null
              ? null
              : (d) => onShowMenu!(item, d.globalPosition),
          onLongPressMenu: onLongPressMenu == null
              ? null
              : (d) => onLongPressMenu!(item, d.globalPosition),
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
    this.progressPercent,
    this.onSecondaryTapUp,
    this.onLongPressMenu,
  });

  final FileItem item;
  final int? coverSourceId;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selectionMode;
  final bool selected;
  final bool highlighted;
  final int nameLines;

  /// 该文件的阅读进度百分比（null = 无历史）。
  final double? progressPercent;
  final GestureTapUpCallback? onSecondaryTapUp;
  final GestureLongPressStartCallback? onLongPressMenu;

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
        ? [
            typeLabel,
            sizeLabel,
          ].where((s) => s.isNotEmpty && s != '-').join(' · ')
        : [
            typeLabel,
            sizeLabel,
            formatModTime(item.modTime),
          ].where((s) => s.isNotEmpty && s != '-').join(' · ');

    return GestureDetector(
      onLongPressStart: onLongPressMenu,
      // 行级 Material：ink（悬停高亮/水波纹）绘制在行自身表面，
      // 不再被浏览页外层卡片容器（不透明背景 + 裁剪）遮挡，
      // 与「正在阅读」列表的悬停效果保持一致。
      child: Material(
        color: selected
            ? colorScheme.primary.withValues(alpha: 0.08)
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          onSecondaryTapUp: onSecondaryTapUp,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
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
                      PlayingFileTitle(
                        text: item.name,
                        itemPath: item.path,
                        sourceId: coverSourceId,
                        maxLines: nameLines,
                        baseStyle: isMobile
                            ? theme.textTheme.bodyMedium?.copyWith(
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
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant.withValues(
                              alpha: 0.75,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                // 右侧状态指示：正在播放动画 / 阅读进度圆环。
                // 多选模式下隐藏（该位置由勾选图标承担视觉重心）。
                if (!selectionMode)
                  FileStatusIndicator(
                    item: item,
                    sourceId: coverSourceId,
                    progressPercent: progressPercent,
                    size: 16,
                  ),
              ],
            ),
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
