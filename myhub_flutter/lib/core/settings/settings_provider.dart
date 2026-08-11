import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 可选播放倍速（播放器控制栏与设置页共用）。
const List<double> kPlaybackSpeeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

/// 倍速显示标签（与播放器控制栏一致）。
String playbackSpeedLabel(double s) =>
    s == s.roundToDouble() ? '${s.toStringAsFixed(1)}x' : '${s}x';

/// 播放方向偏好。
///
/// 视频模式下的方向策略：
/// * [portrait]   强制竖屏（默认，移动端 App 主流体验）；
/// * [landscape]  强制横屏；
/// * [sensor]     跟随水平仪自动切换（未锁定方向时）。
enum PlayerOrientation {
  portrait,
  landscape,
  sensor;

  static PlayerOrientation fromName(String? name) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    return portrait;
  }
}

/// 文件名/标题显示行数（浏览页卡片与列表、阅读页卡片与列表共用）。
///
/// 范围 1~3，持久化到 SharedPreferences，默认 1（保持原有单行截断行为）。
final fileNameLinesProvider = NotifierProvider<FileNameLinesNotifier, int>(
  FileNameLinesNotifier.new,
);

class FileNameLinesNotifier extends Notifier<int> {
  static const _kKey = 'ui.file_name_lines';
  static const int minLines = 1;
  static const int maxLines = 3;

  @override
  int build() {
    _restore();
    return 1;
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    state = (prefs.getInt(_kKey) ?? 1).clamp(minLines, maxLines);
  }

  Future<void> set(int lines) async {
    final v = lines.clamp(minLines, maxLines);
    state = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kKey, v);
  }
}

/// 播放偏好设置。
class PlayerSettings {
  const PlayerSettings({
    this.defaultSpeed = 1.0,
    this.preferTranscode = false,
    this.volume = 100.0,
    this.orientation = PlayerOrientation.portrait,
  });

  /// 默认倍速（0.5 ~ 2.0）。
  final double defaultSpeed;

  /// 转码偏好：true 时优先 HLS 转码播放，false 优先直通。
  final bool preferTranscode;

  /// 上次使用的音量（0 ~ 100），重启应用后恢复。
  final double volume;

  /// 视频方向偏好：竖屏 / 横屏 / 水平仪自动切换。
  ///
  /// 注意：方向偏好会持久化到 SharedPreferences，
  /// 下次打开播放器沿用上次的设置。
  final PlayerOrientation orientation;

  PlayerSettings copyWith({
    double? defaultSpeed,
    bool? preferTranscode,
    double? volume,
    PlayerOrientation? orientation,
  }) {
    return PlayerSettings(
      defaultSpeed: defaultSpeed ?? this.defaultSpeed,
      preferTranscode: preferTranscode ?? this.preferTranscode,
      volume: volume ?? this.volume,
      orientation: orientation ?? this.orientation,
    );
  }
}

/// 播放设置 Provider（持久化到 SharedPreferences）。
///
/// 阅读器偏好见 `shared/widgets/novel_reader/reader_settings.dart`，
/// 漫画偏好见 `shared/widgets/comic_reader/comic_settings.dart`。
final playerSettingsProvider =
    NotifierProvider<PlayerSettingsNotifier, PlayerSettings>(
  PlayerSettingsNotifier.new,
);

class PlayerSettingsNotifier extends Notifier<PlayerSettings> {
  static const _kDefaultSpeed = 'player.default_speed';
  static const _kPreferTranscode = 'player.prefer_transcode';
  static const _kVolume = 'player.volume';
  static const _kOrientation = 'player.orientation';

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
      volume: (prefs.getDouble(_kVolume) ?? 100.0).clamp(0.0, 100.0),
      // 方向偏好从持久化恢复：上次设置是竖屏就保持竖屏，横屏就保持横屏，
      // 水平仪自动就保持自动。
      orientation: PlayerOrientation.fromName(prefs.getString(_kOrientation)),
    );
  }

  Future<void> update(PlayerSettings settings) async {
    _dirty = true;
    state = settings;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kDefaultSpeed, settings.defaultSpeed);
    await prefs.setBool(_kPreferTranscode, settings.preferTranscode);
    await prefs.setDouble(_kVolume, settings.volume);
    // 方向偏好持久化：下次打开沿用上次设置。
    await prefs.setString(_kOrientation, settings.orientation.name);
  }
}
