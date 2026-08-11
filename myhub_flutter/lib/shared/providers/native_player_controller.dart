import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:myhub_flutter/core/api/stream_api.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/core/settings/server_config_provider.dart';
import 'package:myhub_flutter/core/settings/settings_provider.dart';
import 'package:myhub_flutter/data/repositories/progress_repository.dart';
import 'package:myhub_flutter/shared/providers/auth_state_provider.dart';

/// 自定义 iOS 原生播放器（AVPlayer 内核）控制器。
///
/// 通过 MethodChannel 与原生 NativePlayerPlugin 通信，通过事件流接收
/// 播放器状态。解决 media_kit 在 iOS 高帧率视频卡顿问题，并保留内嵌
/// 音轨/字幕轨切换能力。
final nativePlayerProvider = Provider<NativePlayerController>((ref) {
  final c = NativePlayerController(ref);
  ref.onDispose(c.dispose);
  return c;
});

/// 轨道信息。
class NativeMediaTrack {
  const NativeMediaTrack({
    required this.index,
    required this.title,
    required this.language,
    required this.selected,
  });

  final int index;
  final String title;
  final String language;
  final bool selected;
}

/// 播放器状态（从事件流解析）。
class NativePlayerState {
  const NativePlayerState({
    this.state,
    this.positionMs = 0,
    this.durationMs = 0,
    this.percent = 0,
    this.error,
  });

  final String? state;
  final int positionMs;
  final int durationMs;
  final double percent;
  final String? error;

  bool get isPlaying => state == 'playing';
  bool get isCompleted => state == 'completed';
  bool get isReady => state == 'ready' || state == 'playing';
}

class NativePlayerController {
  NativePlayerController(this._ref);

  final Ref _ref;
  static const MethodChannel _channel = MethodChannel('myhub/native_player');
  static const EventChannel _events =
      EventChannel('myhub/native_player/events');

  StreamSubscription<dynamic>? _eventSub;
  Timer? _reportTimer;
  Timer? _volumeSaveTimer;

  // 对外状态
  final ValueNotifier<NativePlayerState?> state = ValueNotifier(null);
  final ValueNotifier<bool> loading = ValueNotifier(true);
  final ValueNotifier<String?> error = ValueNotifier(null);
  final ValueNotifier<bool> isVideoMode = ValueNotifier(true);
  final ValueNotifier<bool> miniVisible = ValueNotifier(false);
  final ValueNotifier<double> speed = ValueNotifier(1.0);
  /// 音量（0-100，与 media_kit 一致，双向同步到系统音量）。
  final ValueNotifier<double> volume = ValueNotifier(100.0);
  /// 系统亮度（0-1），与系统亮度双向同步。
  final ValueNotifier<double> brightness = ValueNotifier(0.5);

  // 轨道
  final ValueNotifier<List<NativeMediaTrack>> audioTracks =
      ValueNotifier([]);
  final ValueNotifier<List<NativeMediaTrack>> subtitleTracks =
      ValueNotifier([]);

  int? _sourceId;
  FileItem? _file;
  bool _everPlayed = false;

  /// 渲染用 texture id（原生 AVPlayer 视频帧），可监听。
  final ValueNotifier<int> textureId = ValueNotifier(0);

  int? get sourceId => _sourceId;
  FileItem? get file => _file;
  bool get hasMedia => _file != null;

  bool _initialized = false;

  Future<void> _ensureInit() async {
    if (_initialized) return;
    _initialized = true;
    _eventSub = _events.receiveBroadcastStream().listen(_onEvent);
  }

  void _onEvent(dynamic raw) {
    final map = raw is Map ? Map<String, dynamic>.from(raw) : null;
    if (map == null) return;
    debugPrint('[native-player] 事件: ${map['state']} '
        'pos=${map['positionMs']} dur=${map['durationMs']}');
    // 系统音量/亮度双向同步事件
    // 原生回传的 systemVolume 是 0-1，转成 0-100 与 media_kit 一致
    final sysVol = map['systemVolume'];
    if (sysVol is num) {
      volume.value = (sysVol.toDouble() * 100).clamp(0.0, 100.0);
    } else {
      final vol = map['volume'];
      if (vol is num) {
        volume.value = (vol.toDouble() * 100).clamp(0.0, 100.0);
      }
    }
    final sysBrightness = map['systemBrightness'];
    if (sysBrightness is num) {
      brightness.value = sysBrightness.toDouble().clamp(0.0, 1.0);
    }
    // 纯音量/亮度同步事件（不含 state）不应更新播放状态，
    // 否则 positionMs/durationMs 等会重置为 0，导致进度条回到开头。
    if (map['state'] == null) {
      return;
    }
    final s = NativePlayerState(
      state: map['state'] as String?,
      positionMs: (map['positionMs'] as num?)?.toInt() ?? 0,
      durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
      percent: (map['percent'] as num?)?.toDouble() ?? 0,
      error: map['error'] as String?,
    );
    state.value = s;

    if (s.error != null) {
      error.value = s.error;
      loading.value = false;
      return;
    }
    if (s.state == 'ready' || s.state == 'playing') {
      if (s.state == 'ready' && !_everPlayed) {
        loading.value = false;
      }
      if (s.state == 'playing') {
        _everPlayed = true;
        loading.value = false;
        _startReporting();
      }
    } else if (s.state == 'paused') {
      if (_everPlayed) {
        _stopReporting();
        unawaited(_report());
      }
    } else if (s.state == 'completed') {
      _stopReporting();
      unawaited(_report(completed: true));
    } else if (s.state == 'loading') {
      loading.value = true;
    }
  }

  void play(int sourceId, FileItem file) {
    _sourceId = sourceId;
    _file = file;
    isVideoMode.value = file.isVideo;
    loading.value = true;
    error.value = null;
    _everPlayed = false;
    unawaited(_open());
  }

  Future<void> _open() async {
    await _ensureInit();
    final sourceId = _sourceId;
    final file = _file;
    if (sourceId == null || file == null) return;
    try {
      final token =
          await const FlutterSecureStorage().read(key: kAccessTokenKey);
      final url = StreamApi.streamUrl(
        sourceId,
        file.path,
        baseUrl: _ref.read(apiBaseUrlProvider),
      );
      await _channel.invokeMethod('open', {
        'url': url,
        'title': file.name,
        // 显式告知原生是否为音频：音频文件不创建视频输出/纹理，
        // 避免 iOS 上 Texture 显示一个空圆圈（默认占位）。
        'isAudio': file.isAudio,
        'headers': {
          if (token != null && token.isNotEmpty)
            'Authorization': 'Bearer $token',
        },
      });
      // 进入播放器与系统当前音量和亮度保持一致：
      // 不再用上次持久化的音量强制覆盖系统音量（用户可能在系统层面
      // 改过音量，强制覆盖会导致进入时音量突然变高/变低），
      // 改为读取系统当前值初始化状态，手势调节时基于真实系统值不会跳变。
      try {
        final sys =
            await _channel.invokeMapMethod<String, dynamic>('getSystemStatus');
        if (sys != null) {
          final sysVol = sys['volume'];
          if (sysVol is num) {
            volume.value = (sysVol.toDouble() * 100).clamp(0.0, 100.0);
          }
          final sysBrightness = sys['brightness'];
          if (sysBrightness is num) {
            brightness.value = sysBrightness.toDouble().clamp(0.0, 1.0);
          }
        }
      } catch (_) {}
      // 恢复倍速
      final settings = _ref.read(playerSettingsProvider);
      if (settings.defaultSpeed != 1.0) {
        await setSpeed(settings.defaultSpeed);
      }
      await _channel.invokeMethod('play');
      // 获取渲染 texture id（原生 texture 注册有延迟，重试直到拿到有效 id）
      textureId.value = await _fetchTextureId();
      debugPrint('[native-player] _open: textureId=${textureId.value}');
      // 加载轨道
      unawaited(_refreshTracks());
      // 恢复进度
      unawaited(_restorePosition(sourceId, file.path));
    } catch (e) {
      error.value = '$e';
      loading.value = false;
    }
  }

  /// 获取有效的 texture id：原生注册有延迟（首次 register 可能返回 0，
  /// 延迟重试后才生效），这里轮询直到拿到非 0 id。
  Future<int> _fetchTextureId() async {
    for (var i = 0; i < 10; i++) {
      final id = await _channel.invokeMethod<int>('getTextureId') ?? 0;
      if (id > 0) return id;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return 0;
  }

  Future<void> _refreshTracks() async {
    try {
      final tracks = await _channel.invokeMapMethod<String, dynamic>('getTracks');
      if (tracks == null) return;
      audioTracks.value = _parseTracks(tracks['audio']);
      subtitleTracks.value = _parseTracks(tracks['subtitle']);
    } catch (_) {}
  }

  List<NativeMediaTrack> _parseTracks(dynamic raw) {
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((t) => NativeMediaTrack(
              index: (t['index'] as num).toInt(),
              title: (t['title'] as String?) ?? '',
              language: (t['language'] as String?) ?? '',
              selected: (t['selected'] as bool?) ?? false,
            ))
        .toList();
  }

  Future<void> _restorePosition(int sourceId, String path) async {
    try {
      final p = await _ref.read(progressRepositoryProvider).get(sourceId, path);
      if (p == null || p.finished || p.progressJson.isEmpty) return;
      final decoded = jsonDecode(p.progressJson);
      if (decoded is Map && decoded['position'] is num) {
        final sec = (decoded['position'] as num).toDouble();
        if (sec >= 3) {
          await _channel.invokeMethod(
              'seek', {'positionMs': (sec * 1000).round()});
        }
      }
    } catch (_) {}
  }

  // 控制
  Future<void> togglePlay() async {
    final s = state.value;
    if (s?.isPlaying == true) {
      await _channel.invokeMethod('pause');
    } else {
      await _channel.invokeMethod('play');
    }
  }

  Future<void> seek(Duration position) async {
    await _channel
        .invokeMethod('seek', {'positionMs': position.inMilliseconds});
  }

  Future<void> setVolume(double v) async {
    // v 为 0-100（与 media_kit 一致），转 0-1 传给原生系统音量
    final normalized = (v / 100).clamp(0.0, 1.0);
    volume.value = v;
    await _channel.invokeMethod('setVolume', {'volume': normalized});
    _volumeSaveTimer?.cancel();
    _volumeSaveTimer = Timer(const Duration(milliseconds: 300), () {
      final settings = _ref.read(playerSettingsProvider);
      unawaited(_ref.read(playerSettingsProvider.notifier)
          .update(settings.copyWith(volume: v)));
    });
  }

  Future<void> setSpeed(double s) async {
    speed.value = s;
    await _channel.invokeMethod('setSpeed', {'speed': s});
  }

  /// 设置系统亮度（0-1），同步到系统屏幕亮度。
  Future<void> setBrightness(double b) async {
    brightness.value = b.clamp(0.0, 1.0);
    await _channel.invokeMethod('setBrightness', {'brightness': b});
  }

  Future<void> selectAudioTrack(int index) async {
    await _channel.invokeMethod('selectAudioTrack', {'index': index});
    await _refreshTracks();
  }

  Future<void> selectSubtitleTrack(int index) async {
    await _channel.invokeMethod('selectSubtitleTrack', {'index': index});
    await _refreshTracks();
  }

  // 会话/迷你
  void pageOpened() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      miniVisible.value = false;
    });
  }

  void pageClosed() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      miniVisible.value = hasMedia && error.value == null;
    });
  }

  Future<void> stop() async {
    miniVisible.value = false;
    _stopReporting();
    if (_everPlayed) {
      unawaited(_report());
    }
    await _channel.invokeMethod('dispose');
  }

  void dispose() {
    _eventSub?.cancel();
    _reportTimer?.cancel();
    _volumeSaveTimer?.cancel();
    state.dispose();
    loading.dispose();
    error.dispose();
    isVideoMode.dispose();
    miniVisible.dispose();
    speed.dispose();
    volume.dispose();
    brightness.dispose();
    audioTracks.dispose();
    subtitleTracks.dispose();
    textureId.dispose();
  }

  // 进度上报
  void _startReporting() {
    if (_reportTimer != null) return;
    _reportTimer = Timer.periodic(const Duration(seconds: 5), (_) => _report());
  }

  void _stopReporting() {
    _reportTimer?.cancel();
    _reportTimer = null;
  }

  Future<void> _report({bool completed = false}) async {
    final file = _file;
    final sourceId = _sourceId;
    final s = state.value;
    if (file == null || sourceId == null || s == null) return;
    try {
      await _ref.read(progressRepositoryProvider).save(
            sourceId: sourceId,
            filePath: file.path,
            mediaType: file.isAudio ? 'audio' : 'video',
            title: file.name,
            progressJson: jsonEncode(
                {'position': s.positionMs / 1000}),
            percent: completed ? 100.0 : s.percent,
          );
    } catch (_) {}
  }
}
