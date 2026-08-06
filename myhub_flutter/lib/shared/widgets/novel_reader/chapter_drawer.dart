import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/shared/widgets/novel_reader/reader_settings.dart';

/// 目录抽屉（TODO 6.4）：从右侧滑出（`Scaffold.endDrawer`）。
///
/// 章节列表，当前章节高亮；点击跳转到对应章节并关闭抽屉。
/// TXT/EPUB 阅读器共用（章节标题列表驱动）。
class ChapterDrawer extends StatelessWidget {
  const ChapterDrawer({
    super.key,
    required this.titles,
    required this.currentIndex,
    required this.onSelect,
    required this.style,
  });

  /// 章节标题列表。
  final List<String> titles;

  /// 当前章节下标（高亮）。
  final int currentIndex;

  /// 点击章节跳转。
  final ValueChanged<int> onSelect;

  /// 阅读器样式（抽屉配色跟随阅读器主题，不受全局主题影响）。
  final ReaderStyle style;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: style.background,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text(
                '目录（共 ${titles.length} 章）',
                style: TextStyle(
                  color: style.foreground,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Divider(height: 1, color: style.subtle.withValues(alpha: 0.3)),
            Expanded(
              child: ListView.builder(
                itemCount: titles.length,
                itemBuilder: (context, i) {
                  final selected = i == currentIndex;
                  return ListTile(
                    dense: true,
                    selected: selected,
                    selectedColor: style.foreground,
                    selectedTileColor:
                        style.foreground.withValues(alpha: 0.08),
                    title: Text(
                      titles[i].isEmpty ? '第 ${i + 1} 章' : titles[i],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected ? style.foreground : style.subtle,
                        fontSize: 13,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                    onTap: () {
                      Navigator.of(context).pop();
                      onSelect(i);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 阅读器底部栏（TODO 6.4）：上/下一章按钮 + 进度条 + 百分比。
class ReaderBottomBar extends StatelessWidget {
  const ReaderBottomBar({
    super.key,
    required this.style,
    required this.progress,
    this.onPrevChapter,
    this.onNextChapter,
  });

  final ReaderStyle style;

  /// 全书进度 0.0 ~ 1.0。
  final double progress;

  /// 上一章（null = 禁用）。
  final VoidCallback? onPrevChapter;

  /// 下一章（null = 禁用）。
  final VoidCallback? onNextChapter;

  @override
  Widget build(BuildContext context) {
    final percent = (progress.clamp(0.0, 1.0) * 100).toStringAsFixed(1);
    return Container(
      color: style.background,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
          child: Row(
            children: [
              TextButton.icon(
                onPressed: onPrevChapter,
                icon: const Icon(LucideIcons.chevronLeft, size: 16),
                label: const Text('上一章'),
                style: TextButton.styleFrom(
                  foregroundColor: style.foreground,
                  disabledForegroundColor:
                      style.subtle.withValues(alpha: 0.5),
                  textStyle: const TextStyle(fontSize: 13),
                ),
              ),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LinearProgressIndicator(
                      value: progress.clamp(0.0, 1.0),
                      minHeight: 2,
                      backgroundColor:
                          style.subtle.withValues(alpha: 0.25),
                      valueColor:
                          AlwaysStoppedAnimation<Color>(style.foreground),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$percent%',
                      style: TextStyle(color: style.subtle, fontSize: 11),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: onNextChapter,
                icon: const Text('下一章'),
                label: const Icon(LucideIcons.chevronRight, size: 16),
                style: TextButton.styleFrom(
                  foregroundColor: style.foreground,
                  disabledForegroundColor:
                      style.subtle.withValues(alpha: 0.5),
                  textStyle: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
