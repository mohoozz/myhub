import 'package:flutter/material.dart';
import 'package:myhub_flutter/core/theme/colors.dart';

/// Builds the light / dark [ThemeData] from the [AppColors] spec.
///
/// Global shape language: cards 12px radius, pill (stadium) buttons,
/// 8px radius inputs, 4px-tall progress indicators. Dark mode is
/// shadow-less; cards are separated by a #1E1E1E border instead.
abstract final class AppTheme {
  static const double _cardRadius = 12;
  static const double _inputRadius = 8;
  static const double _progressHeight = 4;

  /// [dynamicScheme]：Android 12+ Material You 动态取色（可选，缺省用品牌色）。
  static ThemeData light({ColorScheme? dynamicScheme}) {
    final colorScheme = (dynamicScheme ??
            const ColorScheme.light(
              primary: AppColors.primaryLight,
              onPrimary: Colors.white,
              secondary: AppColors.primaryLight,
              onSecondary: Colors.white,
              surface: AppColors.backgroundLight,
              onSurface: AppColors.textPrimaryLight,
              onSurfaceVariant: AppColors.textSecondaryLight,
              outline: AppColors.dividerLight,
              error: Color(0xFFDC2626),
              onError: Colors.white,
              surfaceTint: Colors.transparent,
            ))
        .copyWith(surfaceTint: Colors.transparent);
    return _build(
      colorScheme: colorScheme,
      cardColor: AppColors.cardLight,
      navBackground: AppColors.navBackgroundLight,
      dividerColor: AppColors.dividerLight,
      inputFill: AppColors.inputBackgroundLight,
      selectionBg: AppColors.selectionBgLight,
      selectionFg: AppColors.selectionFgLight,
      textPrimary: AppColors.textPrimaryLight,
      textSecondary: AppColors.textSecondaryLight,
      isDark: false,
    );
  }

  /// [dynamicScheme]：Android 12+ Material You 动态取色（可选，缺省用品牌色）。
  static ThemeData dark({ColorScheme? dynamicScheme}) {
    final colorScheme = (dynamicScheme ??
            const ColorScheme.dark(
              primary: AppColors.primaryDark,
              onPrimary: Colors.white,
              secondary: AppColors.primaryDark,
              onSecondary: Colors.white,
              surface: AppColors.backgroundDark,
              onSurface: AppColors.textPrimaryDark,
              onSurfaceVariant: AppColors.textSecondaryDark,
              outline: AppColors.dividerDark,
              error: Color(0xFFEF4444),
              onError: Colors.white,
              surfaceTint: Colors.transparent,
            ))
        .copyWith(surfaceTint: Colors.transparent);
    return _build(
      colorScheme: colorScheme,
      cardColor: AppColors.cardDark,
      navBackground: AppColors.navBackgroundDark,
      dividerColor: AppColors.dividerDark,
      inputFill: AppColors.inputBackgroundDark,
      selectionBg: AppColors.selectionBgDark,
      selectionFg: AppColors.selectionFgDark,
      textPrimary: AppColors.textPrimaryDark,
      textSecondary: AppColors.textSecondaryDark,
      isDark: true,
    );
  }

  static ThemeData _build({
    required ColorScheme colorScheme,
    required Color cardColor,
    required Color navBackground,
    required Color dividerColor,
    required Color inputFill,
    required Color selectionBg,
    required Color selectionFg,
    required Color textPrimary,
    required Color textSecondary,
    required bool isDark,
  }) {
    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(_inputRadius),
      borderSide: BorderSide(color: dividerColor),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        color: cardColor,
        elevation: isDark ? 0 : 1,
        shadowColor: isDark ? Colors.transparent : null,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_cardRadius),
          side: isDark ? BorderSide(color: dividerColor) : BorderSide.none,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: cardColor,
        elevation: isDark ? 0 : 6,
        shadowColor: isDark ? Colors.transparent : null,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_cardRadius),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        // 暗色主题：弹窗卡片色 #121212 与纯黑背景 #000000 对比度太弱，
        // 加上无边框会"融为一体"。统一用 cardColor + 1px 分隔线作为边界，
        // 不依赖阴影（避免明/暗主题切换时阴影"突然出现"造成的视觉跳动）。
        backgroundColor: cardColor,
        elevation: 0,
        modalElevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(_cardRadius),
          ),
          side: isDark ? BorderSide(color: dividerColor) : BorderSide.none,
        ),
        showDragHandle: false, // 各 sheet 自行决定
        dragHandleColor: dividerColor,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          // 40px-tall pill => 20px radius capsule.
          shape: const StadiumBorder(),
          minimumSize: const Size(64, 40),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: inputFill,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: inputBorder,
        enabledBorder: inputBorder,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_inputRadius),
          borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: dividerColor,
        thickness: 1,
        space: 1,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colorScheme.primary,
        linearMinHeight: _progressHeight,
        borderRadius: BorderRadius.circular(_progressHeight / 2),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: navBackground,
        indicatorColor: selectionBg,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? selectionFg
                : textSecondary,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
            color: states.contains(WidgetState.selected)
                ? selectionFg
                : textSecondary,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: navBackground,
        indicatorColor: selectionBg,
        selectedIconTheme: IconThemeData(color: selectionFg),
        unselectedIconTheme: IconThemeData(color: textSecondary),
        selectedLabelTextStyle: TextStyle(
          color: selectionFg,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelTextStyle: TextStyle(color: textSecondary),
      ),
      textTheme: _scaledTextTheme(isDark, textPrimary),
    );
  }

  /// 全局字号缩放。
  ///
  /// Material 3 默认正文 (bodyMedium) 只有 14px，在移动端偏小。这里做整体
  /// 放大：bodyMedium 升到 15px，小字 (bodySmall/labelSmall) 提升比例略高，
  /// 保证小标签在缩小时依然可读，标题层级随之同步放大。
  /// 由于大部分页面通过 [TextTheme] 取字号，这一处缩放即可全局生效。
  static TextTheme _scaledTextTheme(bool isDark, Color textPrimary) {
    final base = (isDark
            ? Typography.material2021().white
            : Typography.material2021().black)
        .apply(
      bodyColor: textPrimary,
      displayColor: textPrimary,
      fontFamilyFallback: _fontFamilyFallback,
    );
    // 逐级放大：小字 +3px，正文 +1px，标题 +1px，大标题 +2px。
    // 数值来源：主流 App（如微信/QQ/今日头条）正文约 15~16px，
    // 辅助说明文字约 13px，标签约 12px。
    return base.copyWith(
      displayLarge: base.displayLarge?.copyWith(fontSize: 58),
      displayMedium: base.displayMedium?.copyWith(fontSize: 46),
      displaySmall: base.displaySmall?.copyWith(fontSize: 37),
      headlineMedium: base.headlineMedium?.copyWith(fontSize: 29),
      headlineSmall: base.headlineSmall?.copyWith(fontSize: 25),
      titleLarge: base.titleLarge?.copyWith(fontSize: 23),
      titleMedium: base.titleMedium?.copyWith(fontSize: 17),
      titleSmall: base.titleSmall?.copyWith(fontSize: 15),
      bodyLarge: base.bodyLarge?.copyWith(fontSize: 17),
      bodyMedium: base.bodyMedium?.copyWith(fontSize: 15),
      bodySmall: base.bodySmall?.copyWith(fontSize: 13),
      labelLarge: base.labelLarge?.copyWith(fontSize: 15),
      labelMedium: base.labelMedium?.copyWith(fontSize: 13),
      labelSmall: base.labelSmall?.copyWith(fontSize: 12),
    );
  }

  /// CJK-friendly fallback chain: Windows renders Chinese with the default
  /// font stack blurry, so prefer the platform's UI CJK fonts explicitly.
  static const List<String> _fontFamilyFallback = [
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'PingFang SC',
    'Noto Sans SC',
    'sans-serif',
  ];

  /// 阅读器正文字体：思源宋体优先，逐级回退平台衬线字体。
  static const List<String> readerSerifFallback = [
    'Noto Serif SC',
    'Source Han Serif SC',
    'Songti SC',
    'SimSun',
    'serif',
  ];

  /// 阅读器正文样式（独立背景/字号由阅读器设置控制，此处仅提供字体）。
  static TextStyle readerSerif({required Color color, required double fontSize, double height = 1.8}) {
    return TextStyle(
      color: color,
      fontSize: fontSize,
      height: height,
      fontFamilyFallback: readerSerifFallback,
    );
  }
}
