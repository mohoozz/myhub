import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 阅读文本样式配置（TODO 6.3，由 [readerSettingsProvider] 驱动）。
class ReaderStyle {
  const ReaderStyle({
    this.fontSize = 16,
    this.lineHeight = 1.6,
    this.background = const Color(0xFFFFFFFF),
    this.foreground = const Color(0xDE000000),
  });

  final double fontSize;
  final double lineHeight;

  /// 阅读器独立背景色（不受全局主题影响）。
  final Color background;
  final Color foreground;

  /// 正文字体家族回退栈。
  ///
  /// 不依赖 google_fonts 的运行时网络下载（iOS 上会导致文字在下载完成的
  /// 前后反复切换而闪烁/空白）。优先使用系统自带的中文衬线/黑体字体，
  /// 缺失时逐级回退到系统默认，保证首帧 [TextPainter] 分页与渲染字体一致。
  static const List<String> _fontStack = [
    // 系统自带中文衬线字体（优先呈现"宋体"阅读观感）
    'Songti SC', // iOS 宋体
    'STSong', // macOS 华文宋体
    'Noto Serif CJK SC', // Android/Linux 思源宋体
    'Source Han Serif SC', // Android 思源宋体别名
    'Noto Serif SC', // 系统已内置时（不触发下载）
    // 以上均缺失时回退到系统中文黑体（iOS 苹方 / Android 思源黑体）
    'PingFang SC',
    'Heiti SC',
    'Noto Sans CJK SC',
    'Noto Sans SC',
  ];

  /// 正文样式：本地字体栈（不触发运行时字体下载，避免 iOS 文字闪烁/空白）。
  TextStyle get textStyle => TextStyle(
        fontSize: fontSize,
        height: lineHeight,
        color: foreground,
        fontFamily: _fontStack.first,
        fontFamilyFallback: _fontStack.skip(1).toList(),
      );

  /// 页眉/辅助文字色。
  Color get subtle => foreground.withValues(alpha: 0.45);
}

/// 阅读模式。
enum ReaderMode { page, scroll }

/// 阅读器主题（独立背景色，不受全局亮/暗主题影响）。
enum ReaderTheme {
  /// 日间：白底 #ffffff 黑字。
  day,

  /// 夜间：黑底 #000000 白字。
  night,

  /// 护眼：暖纸 #f5f0e8 底 + 深棕 #4a3728 字。
  eyeCare,
}

extension ReaderThemeX on ReaderTheme {
  String get label => switch (this) {
        ReaderTheme.day => '日间',
        ReaderTheme.night => '夜间',
        ReaderTheme.eyeCare => '护眼',
      };

  /// (背景色, 文字色)。
  (Color, Color) get colors => switch (this) {
        ReaderTheme.day => (const Color(0xFFFFFFFF), const Color(0xDE000000)),
        ReaderTheme.night => (const Color(0xFF000000), const Color(0xE6FFFFFF)),
        ReaderTheme.eyeCare =>
          (const Color(0xFFF5F0E8), const Color(0xFF4A3728)),
      };
}

/// 阅读器设置（字号/行距/主题/翻页模式），持久化到 SharedPreferences。
class ReaderSettings {
  const ReaderSettings({
    this.fontSize = 16,
    this.lineHeight = 1.6,
    this.theme = ReaderTheme.day,
    this.mode = ReaderMode.page,
  });

  static const double minFontSize = 12;
  static const double maxFontSize = 24;
  static const double minLineHeight = 1.2;
  static const double maxLineHeight = 2.5;

  final double fontSize;
  final double lineHeight;
  final ReaderTheme theme;
  final ReaderMode mode;

  /// 当前设置对应的文本样式。
  ReaderStyle get style {
    final (bg, fg) = theme.colors;
    return ReaderStyle(
      fontSize: fontSize,
      lineHeight: lineHeight,
      background: bg,
      foreground: fg,
    );
  }

  ReaderSettings copyWith({
    double? fontSize,
    double? lineHeight,
    ReaderTheme? theme,
    ReaderMode? mode,
  }) {
    return ReaderSettings(
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      theme: theme ?? this.theme,
      mode: mode ?? this.mode,
    );
  }
}

/// 阅读器设置全局状态（TXT/EPUB 阅读器共用）。
final readerSettingsProvider =
    NotifierProvider<ReaderSettingsNotifier, ReaderSettings>(
  ReaderSettingsNotifier.new,
);

class ReaderSettingsNotifier extends Notifier<ReaderSettings> {
  static const _kFontSize = 'reader_font_size';
  static const _kLineHeight = 'reader_line_height';
  static const _kTheme = 'reader_theme';
  static const _kMode = 'reader_mode';

  /// 标记用户已显式修改（防止异步恢复覆盖新值）。
  var _dirty = false;

  @override
  ReaderSettings build() {
    _restore();
    return const ReaderSettings();
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    if (_dirty) return;
    final fontSize = (prefs.getDouble(_kFontSize) ?? 16)
        .clamp(ReaderSettings.minFontSize, ReaderSettings.maxFontSize);
    final lineHeight = (prefs.getDouble(_kLineHeight) ?? 1.6)
        .clamp(ReaderSettings.minLineHeight, ReaderSettings.maxLineHeight);
    state = ReaderSettings(
      fontSize: fontSize,
      lineHeight: lineHeight,
      theme: ReaderTheme.values.asNameMap()[prefs.getString(_kTheme)] ??
          ReaderTheme.day,
      mode: ReaderMode.values.asNameMap()[prefs.getString(_kMode)] ??
          ReaderMode.page,
    );
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kFontSize, state.fontSize);
    await prefs.setDouble(_kLineHeight, state.lineHeight);
    await prefs.setString(_kTheme, state.theme.name);
    await prefs.setString(_kMode, state.mode.name);
  }

  /// 设置字号（滑动中 persist=false 仅更新状态，结束时再持久化）。
  void setFontSize(double v, {bool persist = true}) {
    _dirty = true;
    state = state.copyWith(
      fontSize: v.clamp(ReaderSettings.minFontSize, ReaderSettings.maxFontSize),
    );
    if (persist) unawaited(_save());
  }

  /// 设置行距。
  void setLineHeight(double v, {bool persist = true}) {
    _dirty = true;
    state = state.copyWith(
      lineHeight:
          v.clamp(ReaderSettings.minLineHeight, ReaderSettings.maxLineHeight),
    );
    if (persist) unawaited(_save());
  }

  /// 切换主题。
  void setTheme(ReaderTheme theme) {
    _dirty = true;
    state = state.copyWith(theme: theme);
    unawaited(_save());
  }

  /// 切换翻页模式。
  void setMode(ReaderMode mode) {
    _dirty = true;
    state = state.copyWith(mode: mode);
    unawaited(_save());
  }
}

/// 阅读器设置面板（TODO 6.3）：`ModalBottomSheet` 弹出。
class ReaderSettingsSheet extends ConsumerWidget {
  const ReaderSettingsSheet({super.key});

  /// 弹出设置面板。
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => const ReaderSettingsSheet(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(readerSettingsProvider);
    final notifier = ref.read(readerSettingsProvider.notifier);
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 字号
            Text(
              '字号  ${settings.fontSize.toStringAsFixed(1)}',
              style: theme.textTheme.labelLarge,
            ),
            Slider(
              value: settings.fontSize,
              min: ReaderSettings.minFontSize,
              max: ReaderSettings.maxFontSize,
              divisions: 24, // 0.5 步进
              onChanged: (v) => notifier.setFontSize(v, persist: false),
              onChangeEnd: notifier.setFontSize,
            ),
            // 行距
            Text(
              '行距  ${settings.lineHeight.toStringAsFixed(1)}',
              style: theme.textTheme.labelLarge,
            ),
            Slider(
              value: settings.lineHeight,
              min: ReaderSettings.minLineHeight,
              max: ReaderSettings.maxLineHeight,
              divisions: 13, // 0.1 步进
              onChanged: (v) => notifier.setLineHeight(v, persist: false),
              onChangeEnd: notifier.setLineHeight,
            ),
            const SizedBox(height: 8),
            // 主题
            Text('主题', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final t in ReaderTheme.values) ...[
                  _ThemeChip(
                    theme: t,
                    selected: settings.theme == t,
                    onTap: () => notifier.setTheme(t),
                  ),
                  if (t != ReaderTheme.values.last) const SizedBox(width: 10),
                ],
              ],
            ),
            const SizedBox(height: 16),
            // 翻页模式
            Text('翻页模式', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            SegmentedButton<ReaderMode>(
              segments: const [
                ButtonSegment(
                  value: ReaderMode.page,
                  label: Text('翻页'),
                  icon: Icon(LucideIcons.bookOpen, size: 16),
                ),
                ButtonSegment(
                  value: ReaderMode.scroll,
                  label: Text('滚动'),
                  icon: Icon(LucideIcons.scroll, size: 16),
                ),
              ],
              selected: {settings.mode},
              onSelectionChanged: (s) => notifier.setMode(s.first),
            ),
          ],
        ),
      ),
    );
  }
}

/// 主题选择块：预览背景色 + 文字色，选中描边。
class _ThemeChip extends StatelessWidget {
  const _ThemeChip({
    required this.theme,
    required this.selected,
    required this.onTap,
  });

  final ReaderTheme theme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = theme.colors;
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 72,
        height: 48,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? colorScheme.primary : colorScheme.outline,
            width: selected ? 2 : 1,
          ),
        ),
        child: Center(
          child: Text(
            theme.label,
            style: TextStyle(color: fg, fontSize: 12),
          ),
        ),
      ),
    );
  }
}
