import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/api/comic_api.dart';
import 'package:myhub_flutter/core/api/file_api.dart';
import 'package:myhub_flutter/core/models/reading_progress.dart';
import 'package:myhub_flutter/shared/providers/auth_headers_provider.dart';
import 'package:myhub_flutter/shared/utils/format.dart';

/// "正在阅读"进度卡片：QQ 音乐风格的横向卡片（背景色块 + 右侧圆形封面）。
///
/// 视觉布局（参考 QQ 音乐红框）：
/// ┌──────────────────────────────────────┐
/// │  类型icon                            │
/// │                                       │
/// │  标题（最多 [titleLines] 行）         │
/// │   ┌──┐                                │
/// │   │封│  源名                          │
/// │   │面│  16% · 7 分钟前                │
/// │   └──┘  ▓▓▓▓░░░░░░                   │
/// └──────────────────────────────────────┘
/// 与原 [ReadingCard] 区别：
/// * 不再以 16:10 大封面为视觉中心；改为横向布局，左侧文案，右侧圆形封面浮起。
/// * 整卡片是按媒体类型取的明亮渐变色块（QQ 音乐"合辑卡片"风格），文字反白。
/// * 选中/未选中态由渐变色块自身 + 边框处理，不再用 primary 8% 透明叠加。
class ReadingCard extends ConsumerWidget {
  const ReadingCard({
    super.key,
    required this.progress,
    required this.sourceName,
    this.onTap,
    this.onLongPress,
    this.onShowMenu,
    this.selectionMode = false,
    this.selected = false,
    this.titleLines = 1,
  });

  final ReadingProgress progress;
  final String sourceName;
  final VoidCallback? onTap;

  /// 多选模式下长按切换选中；非多选模式下长按由 [onShowMenu] 弹出菜单。
  final VoidCallback? onLongPress;

  /// PC 端右键 / 移动端长按触发：在对应位置弹出上下文菜单（信息/定位/删除）。
  final void Function(Offset globalPosition)? onShowMenu;

  /// 多选模式：显示选中框并高亮选中项。
  final bool selectionMode;

  /// 当前是否被选中（多选模式下生效）。
  final bool selected;

  /// 标题显示行数（1~3）。
  final int titleLines;

  /// 类型映射（亮色主题）：明亮饱和渐变，文字反白。
  static const _typeColorsLight = {
    'novel': [Color(0xFF7C3AED), Color(0xFFDB2777)],
    'comic': [Color(0xFF334155), Color(0xFF0F172A)],
    'video': [Color(0xFF0F766E), Color(0xFF155E75)],
    'audio': [Color(0xFF2563EB), Color(0xFF7C3AED)],
  };

  /// 类型映射（暗色主题）：降低饱和度、明度，避免刺眼。
  static const _typeColorsDark = {
    'novel': [Color(0xFF4C1D95), Color(0xFF831843)],
    'comic': [Color(0xFF1E293B), Color(0xFF0F172A)],
    'video': [Color(0xFF134E4A), Color(0xFF164E63)],
    'audio': [Color(0xFF1E3A8A), Color(0xFF4C1D95)],
  };

  /// 按类型获取渐变色（亮/暗双主题）。
  List<Color> _paletteColors(ThemeData theme) {
    final dark = theme.brightness == Brightness.dark;
    return (dark
            ? _typeColorsDark[progress.mediaType]
            : _typeColorsLight[progress.mediaType]) ??
        (dark
            ? const [Color(0xFF334155), Color(0xFF1E293B)]
            : const [Color(0xFF475569), Color(0xFF1E293B)]);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final title = progress.title.isNotEmpty
        ? progress.title
        : progress.filePath.split('/').last;

    return Material(
      // 选中态：保留色块，仅在外层加 primary 边框避免遮挡卡片内容。
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: GestureDetector(
        // 移动端长按（非多选模式）：在按下的位置弹出与右键相同的菜单
        onLongPressStart: selectionMode
            ? null
            : (d) => onShowMenu?.call(d.globalPosition),
        child: InkWell(
          onTap: onTap,
          onLongPress: selectionMode ? onLongPress : null,
          onSecondaryTapUp: selectionMode
              ? null
              : (d) => onShowMenu?.call(d.globalPosition),
          // 选中态的覆盖描边只在外层 BoxDecoration 上，不影响 InkWell 水波纹。
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 预解析封面 URL（视频/音频走 thumbnail，漫画走第一页）。
              // 直接使用图片作为卡片背景，让卡片在视觉上"自带封面"。
              String? bgUrl;
              if (progress.cover.isNotEmpty) {
                bgUrl = progress.cover;
              } else if (progress.mediaType == 'video' ||
                  progress.mediaType == 'audio') {
                bgUrl = ref
                    .read(fileApiProvider)
                    .thumbnailUrl(progress.sourceId, progress.filePath);
              } else if (progress.mediaType == 'comic') {
                bgUrl = ref
                    .read(comicApiProvider)
                    .pageUrl(progress.sourceId, progress.filePath, 0);
              }
              final headers = ref.watch(authHeadersProvider).valueOrNull;
              return Stack(
                children: [
                  // 底层：背景层（优先 cover 缩略图；无图时回退到渐变色块）。
                  // 视频/音频/漫画的封面正好可以充当卡片背景，省去 QQ 风的
                  // "右侧圆形封面"——让整张图片作为视觉主元素，更具"沉浸感"。
                  if (bgUrl != null && headers != null)
                    Positioned.fill(
                      child: CachedNetworkImage(
                        imageUrl: bgUrl,
                        httpHeaders: headers,
                        fit: BoxFit.cover,
                        fadeInDuration: const Duration(milliseconds: 200),
                        placeholder: (_, __) => _gradientFallback(theme),
                        errorWidget: (_, __, ___) => _gradientFallback(theme),
                      ),
                    )
                  else
                    Positioned.fill(child: _gradientFallback(theme)),
                  // 蒙版：图片背景上需要可读文字。加一层从左到右的深色
                  // 渐变（左侧更暗，右侧弱化），让左侧文字自然落于暗背景上，
                  // 右侧保留图片的明亮细节作为视觉中心。
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [
                            Colors.black.withValues(alpha: 0.55),
                            Colors.black.withValues(alpha: 0.15),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // 选中态描边：在 Stack 最上层渲染（被蒙版/文字层下覆盖，
                  // 但仍可见于卡片边界）。
                  if (selected)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: colorScheme.primary,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                    ),
                  // 中层：左侧文案（标题/源名/进度 + 进度条）
                  Padding(
                    padding: EdgeInsets.fromLTRB(14, 12, 14, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: [
                        // 顶部：类型小图标（类型含义一目了然）
                        Icon(
                          _typeIcon(progress.mediaType),
                          size: 16,
                          color: Colors.white.withValues(alpha: 0.85),
                        ),
                        const SizedBox(height: 6),
                        // 标题：白色加粗、多行省略
                        Text(
                          title,
                          maxLines: titleLines,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            height: 1.25,
                          ),
                        ),
                        if (sourceName.isNotEmpty && titleLines == 1) ...[
                          const SizedBox(height: 4),
                          Text(
                            sourceName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.85),
                              fontSize: 12,
                            ),
                          ),
                        ],
                        const Spacer(),
                        // 进度信息（百分比 + 相对时间）
                        Text(
                          progress.finished
                              ? '已读完 · ${formatRelativeTime(progress.updatedAt)}'
                              : '${progress.percent.toStringAsFixed(0)}% · '
                                    '${formatRelativeTime(progress.updatedAt)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.85),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 6),
                        // 细进度条：底色半透白 + 已播放部分纯白填充
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: (progress.percent / 100).clamp(0.0, 1.0),
                            minHeight: 3,
                            backgroundColor:
                                Colors.white.withValues(alpha: 0.25),
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 多选模式：右上角勾选环
                  if (selectionMode)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: ReadingSelectBadge(selected: selected),
                    )
                  // 非多选模式：把"已读完"徽标移到右上角
                  else if (progress.finished)
                    const Positioned(
                      top: 8,
                      right: 8,
                      child: _FinishedBadge(),
                    )
                  // 非多选模式：类型徽标放右上角
                  else
                    Positioned(
                      top: 8,
                      right: 8,
                      child: ReadingTypeBadge(mediaType: progress.mediaType),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// 无封面图时的回退背景：渐变色块（与卡片文字反白兼容）。
  Widget _gradientFallback(ThemeData theme) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: _paletteColors(theme),
        ),
      ),
    );
  }

  /// 类型图标：与现有 [ReadingCover._icon] 保持一致。
  static IconData _typeIcon(String mediaType) => switch (mediaType) {
        'video' => LucideIcons.film,
        'audio' => LucideIcons.music,
        'novel' => LucideIcons.bookOpen,
        'comic' => LucideIcons.images,
        _ => LucideIcons.file,
      };
}

/// 已读完徽标（叠加在封面右下角）。
class _FinishedBadge extends StatelessWidget {
  const _FinishedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.checkCheck, size: 11, color: Colors.white),
          SizedBox(width: 3),
          Text(
            '已读完',
            style: TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 多选模式右上角的圆形选中/未选中标记。
class ReadingSelectBadge extends StatelessWidget {
  const ReadingSelectBadge({super.key, required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected
            ? colorScheme.primary
            : Colors.black.withValues(alpha: 0.35),
        border: Border.all(
          color: selected ? colorScheme.primary : Colors.white54,
          width: 1.5,
        ),
      ),
      child: selected
          ? Icon(
              LucideIcons.check,
              size: 13,
              color: theme.colorScheme.onPrimary,
            )
          : null,
    );
  }
}

/// "正在阅读"类型徽标：小说/漫画/视频/音频。
class ReadingTypeBadge extends StatelessWidget {
  const ReadingTypeBadge({super.key, required this.mediaType});

  final String mediaType;

  static const _labels = {
    'novel': '小说',
    'comic': '漫画',
    'video': '视频',
    'audio': '音频',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        _labels[mediaType] ?? '其他',
        style: theme.textTheme.labelSmall?.copyWith(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 阅读封面：优先 cover 字段图片；视频/音频回退到 FFmpeg 缩略图，
/// 漫画回退到第一页；其余按类型渐变 + 图标。
class ReadingCover extends ConsumerWidget {
  const ReadingCover({super.key, required this.progress, this.iconSize = 36});

  final ReadingProgress progress;
  final double iconSize;

  IconData get _icon => switch (progress.mediaType) {
    'video' => LucideIcons.film,
    'audio' => LucideIcons.music,
    'novel' => LucideIcons.bookOpen,
    'comic' => LucideIcons.images,
    _ => LucideIcons.file,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 使用 ReadingCard 的色彩映射（亮/暗主题各一套）作为无图回退背景色，
    // 与新卡片整张色块保持视觉一致。ReadingCard 的 _paletteColors 是
    // 实例方法，但回退图层通常与卡片背景同色，所以这里简化为亮色套。
    final colors =
        ReadingCard._typeColorsLight[progress.mediaType] ??
        const [Color(0xFF475569), Color(0xFF1E293B)];
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
      ),
      child: Center(
        child: Icon(
          _icon,
          size: iconSize,
          color: Colors.white.withValues(alpha: 0.75),
        ),
      ),
    );

    String? url;
    if (progress.cover.isNotEmpty) {
      url = progress.cover;
    } else if (progress.mediaType == 'video' || progress.mediaType == 'audio') {
      url = ref
          .read(fileApiProvider)
          .thumbnailUrl(progress.sourceId, progress.filePath);
    } else if (progress.mediaType == 'comic') {
      url = ref
          .read(comicApiProvider)
          .pageUrl(progress.sourceId, progress.filePath, 0);
    }
    if (url == null) return fallback;

    final headers = ref.watch(authHeadersProvider).valueOrNull;
    if (headers == null) return fallback;
    return CachedNetworkImage(
      imageUrl: url,
      httpHeaders: headers,
      fit: BoxFit.cover,
      fadeInDuration: const Duration(milliseconds: 150),
      placeholder: (_, __) => fallback,
      errorWidget: (_, __, ___) => fallback,
    );
  }
}

/// 列表视图行：小封面、标题、类型徽标、源名、百分比/相对时间、进度条。
class ReadingListTile extends ConsumerWidget {
  const ReadingListTile({
    super.key,
    required this.progress,
    required this.sourceName,
    this.onTap,
    this.onLongPress,
    this.onShowMenu,
    this.selectionMode = false,
    this.selected = false,
    this.titleLines = 1,
  });

  final ReadingProgress progress;
  final String sourceName;
  final VoidCallback? onTap;

  /// 多选模式下长按切换选中；非多选模式下长按由 [onShowMenu] 弹出菜单。
  final VoidCallback? onLongPress;

  /// PC 端右键 / 移动端长按触发：在对应位置弹出上下文菜单（信息/定位/删除）。
  final void Function(Offset globalPosition)? onShowMenu;

  final bool selectionMode;
  final bool selected;

  /// 标题显示行数（1~3）。
  final int titleLines;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final title = progress.title.isNotEmpty
        ? progress.title
        : progress.filePath.split('/').last;

    return GestureDetector(
      // 移动端长按（非多选模式）：在按下的位置弹出与右键相同的菜单
      onLongPressStart: selectionMode
          ? null
          : (d) => onShowMenu?.call(d.globalPosition),
      child: InkWell(
        onTap: onTap,
        onLongPress: selectionMode ? onLongPress : null,
        onSecondaryTapUp: selectionMode
            ? null
            : (d) => onShowMenu?.call(d.globalPosition),
        child: Container(
          // 选中态：primary 8% 透明叠加（与上文 ReadingCard 一致）。
          // 列表项间细线分隔：底部 outline-with-alpha，与 GridView 风格统一。
          decoration: BoxDecoration(
            color:
                selected ? colorScheme.primary.withValues(alpha: 0.08) : null,
            border: Border(
              bottom: BorderSide(
                color: colorScheme.outline.withValues(alpha: 0.15),
                width: 0.5,
              ),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (selectionMode) ...[
                ReadingSelectBadge(selected: selected),
                const SizedBox(width: 10),
              ],
              // 左侧封面/图标：44x44 圆角方块（与参考图红框风格一致）。
              SizedBox(
                width: 44,
                height: 44,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: ReadingCover(progress: progress, iconSize: 20),
                ),
              ),
              const SizedBox(width: 12),
              // 中间文案区
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // 第一行：标题（加粗，省略）
                    Text(
                      title,
                      maxLines: titleLines,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                    ),
                    // 第二行：源名 · 类型 · 大小 · 日期（小字号次要色）
                    if (sourceName.isNotEmpty || progress.mediaType != '') ...[
                      const SizedBox(height: 4),
                      Text(
                        _formatSubtitle(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.75,
                          ),
                          fontSize: 12,
                          height: 1.2,
                        ),
                      ),
                    ],
                    // 进度条 + 百分比（参考图：底部明细）
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value:
                                  (progress.percent / 100).clamp(0.0, 1.0),
                              minHeight: 3,
                              backgroundColor:
                                  colorScheme.outline.withValues(alpha: 0.3),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          progress.finished
                              ? '已读完'
                              : '${progress.percent.toStringAsFixed(0)}%',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: progress.finished
                                ? colorScheme.primary
                                : colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 第二行副标题：源名 · 类型 · 大小 · 日期（参考图"TXT · 4 KB · 2026/8/9"风格）。
  String _formatSubtitle() {
    final parts = <String>[];
    if (sourceName.isNotEmpty) parts.add(sourceName);
    final m = progress.mediaType;
    if (m == 'video') parts.add('视频');
    if (m == 'audio') parts.add('音频');
    if (m == 'novel') parts.add('小说');
    if (m == 'comic') parts.add('漫画');
    if (progress.updatedAt != null) {
      final dt = progress.updatedAt!;
      parts.add('${dt.year}/${dt.month}/${dt.day}');
    }
    return parts.join(' · ');
  }
}
