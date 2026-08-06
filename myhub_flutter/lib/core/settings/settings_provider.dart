import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 可选播放倍速（播放器控制栏与设置页共用）。
const List<double> kPlaybackSpeeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

/// 倍速显示标签（与播放器控制栏一致）。
String playbackSpeedLabel(double s) =>
    s == s.roundToDouble() ? '${s.toStringAsFixed(1)}x' : '${s}x';

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
