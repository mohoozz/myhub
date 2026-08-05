import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 阅读器主题（独立于全局亮/暗主题）。
enum ReaderTheme { day, night, eye }

/// 阅读器翻页模式。
enum ReaderPageMode { page, scroll }

/// 漫画阅读方向。
enum ComicDirection { ltr, rtl }

/// 阅读器偏好设置。
class ReaderSettings {
  const ReaderSettings({
    this.fontSize = 16,
    this.lineHeight = 1.8,
    this.theme = ReaderTheme.day,
    this.pageMode = ReaderPageMode.page,
    this.comicDirection = ComicDirection.rtl,
  });

  /// 字号 12~24。
  final double fontSize;

  /// 行距 1.2~2.5。
  final double lineHeight;

  final ReaderTheme theme;
  final ReaderPageMode pageMode;
  final ComicDirection comicDirection;

  ReaderSettings copyWith({
    double? fontSize,
    double? lineHeight,
    ReaderTheme? theme,
    ReaderPageMode? pageMode,
    ComicDirection? comicDirection,
  }) {
    return ReaderSettings(
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      theme: theme ?? this.theme,
      pageMode: pageMode ?? this.pageMode,
      comicDirection: comicDirection ?? this.comicDirection,
    );
  }
}

/// 播放偏好设置。
class PlayerSettings {
  const PlayerSettings({
    this.defaultSpeed = 1.0,
    this.preferTranscode = false,
  });

  /// 默认倍速（0.5 ~ 2.0）。
  final double defaultSpeed;

  /// 转码偏好：true 时优先 HLS 转码播放，false 优先直通。
  final bool preferTranscode;

  PlayerSettings copyWith({double? defaultSpeed, bool? preferTranscode}) {
    return PlayerSettings(
      defaultSpeed: defaultSpeed ?? this.defaultSpeed,
      preferTranscode: preferTranscode ?? this.preferTranscode,
    );
  }
}

/// 阅读器设置 Provider（持久化到 SharedPreferences）。
final readerSettingsProvider =
    NotifierProvider<ReaderSettingsNotifier, ReaderSettings>(
  ReaderSettingsNotifier.new,
);

class ReaderSettingsNotifier extends Notifier<ReaderSettings> {
  static const _kFontSize = 'reader.font_size';
  static const _kLineHeight = 'reader.line_height';
  static const _kTheme = 'reader.theme';
  static const _kPageMode = 'reader.page_mode';
  static const _kComicDirection = 'reader.comic_direction';

  /// 标记用户已显式修改（防止异步恢复覆盖新值）。
  var _dirty = false;

  @override
  ReaderSettings build() {
    _restore();
    return const ReaderSettings();
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    if (_dirty) return; // 恢复期间用户已修改，保留新值
    state = ReaderSettings(
      fontSize: (prefs.getDouble(_kFontSize) ?? 16).clamp(12, 24),
      lineHeight: (prefs.getDouble(_kLineHeight) ?? 1.8).clamp(1.2, 2.5),
      theme: ReaderTheme.values.asNameMap()[prefs.getString(_kTheme)] ??
          ReaderTheme.day,
      pageMode:
          ReaderPageMode.values.asNameMap()[prefs.getString(_kPageMode)] ??
              ReaderPageMode.page,
      comicDirection: ComicDirection.values
              .asNameMap()[prefs.getString(_kComicDirection)] ??
          ComicDirection.rtl,
    );
  }

  Future<void> update(ReaderSettings settings) async {
    _dirty = true;
    state = settings;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kFontSize, settings.fontSize);
    await prefs.setDouble(_kLineHeight, settings.lineHeight);
    await prefs.setString(_kTheme, settings.theme.name);
    await prefs.setString(_kPageMode, settings.pageMode.name);
    await prefs.setString(_kComicDirection, settings.comicDirection.name);
  }
}

/// 播放设置 Provider（持久化到 SharedPreferences）。
final playerSettingsProvider =
    NotifierProvider<PlayerSettingsNotifier, PlayerSettings>(
  PlayerSettingsNotifier.new,
);

class PlayerSettingsNotifier extends Notifier<PlayerSettings> {
  static const _kDefaultSpeed = 'player.default_speed';
  static const _kPreferTranscode = 'player.prefer_transcode';

  /// 标记用户已显式修改（防止异步恢复覆盖新值）。
  var _dirty = false;

  @override
  PlayerSettings build() {
    _restore();
    return const PlayerSettings();
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    if (_dirty) return;
    state = PlayerSettings(
      defaultSpeed: (prefs.getDouble(_kDefaultSpeed) ?? 1.0).clamp(0.5, 2.0),
      preferTranscode: prefs.getBool(_kPreferTranscode) ?? false,
    );
  }

  Future<void> update(PlayerSettings settings) async {
    _dirty = true;
    state = settings;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kDefaultSpeed, settings.defaultSpeed);
    await prefs.setBool(_kPreferTranscode, settings.preferTranscode);
  }
}
