import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:myhub_flutter/shared/providers/native_player_controller.dart';

/// AVPlayer 适配器：让 media_kit 的 UI 组件无需修改就能使用 iOS 原生 AVPlayer。
///
/// 暴露与 media_kit [Player] 完全相同的接口（`state`、`stream`、`playOrPause()`
/// 等），内部通过 [NativePlayerController] 的 MethodChannel/EventChannel 调用
/// AVPlayer。解决 media_kit 在 iOS 上 120fps 视频卡顿问题（vo=libmpv 不支持
/// vf 滤镜/display-sync/decoder framedrop）。
///
/// 使用方式与 [Player] 完全一致：
/// ```dart
/// final adapter = AvPlayerAdapter(nativeController);
/// adapter.state.playing;    // 当前播放状态
/// adapter.stream.position.listen((pos) { ... });  // 位置变化
/// adapter.playOrPause();    // 播放/暂停
/// adapter.seek(Duration(seconds: 10));  // 跳转
/// ```
class AvPlayerAdapter {
  AvPlayerAdapter(this._native);

  final NativePlayerController _native;

  // ---------- Stream Controllers ----------
  // 这些 StreamController 驱动 stream 属性，监听 NativePlayerController 的
  // state ValueNotifier 并转换为 media_kit 兼容的流。

  final _playingController = StreamController<bool>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _bufferController = StreamController<Duration>.broadcast();
  final _bufferingController = StreamController<bool>.broadcast();
  final _rateController = StreamController<double>.broadcast();
  final _volumeController = StreamController<double>.broadcast();
  final _trackController = StreamController<Track>.broadcast();
  final _tracksController = StreamController<Tracks>.broadcast();
  final _completedController = StreamController<bool>.broadcast();
  final _errorController = StreamController<String>.broadcast();

  // ---------- 当前状态 ----------
  // 缓存最新状态，供 state getter 同步读取。

  bool _playing = false;
  bool _completed = false;
  bool _buffering = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffer = Duration.zero;
  double _volume = 100.0;
  double _rate = 1.0;
  final Track _track = const Track();
  final Tracks _tracks = const Tracks();

  /// 渲染用 texture id（原生 AVPlayer 视频帧）。
  ValueNotifier<int> get textureId => _native.textureId;

  /// 系统亮度（0-1），与系统亮度双向同步。
  ValueNotifier<double> get brightness => _native.brightness;

  /// 设置系统亮度（0-1）。
  Future<void> setBrightness(double b) => _native.setBrightness(b);

  // ---------- Player 接口 ----------

  /// 当前播放器状态（兼容 media_kit PlayerState）。
  PlayerState get state => PlayerState(
        playing: _playing,
        completed: _completed,
        position: _position,
        duration: _duration,
        volume: _volume,
        rate: _rate,
        buffering: _buffering,
        buffer: _buffer,
        track: _track,
        tracks: _tracks,
      );

  /// 播放器状态流（兼容 media_kit PlayerStream）。
  late final PlayerStream stream = PlayerStream(
    // playlist — AVPlayer 不支持播放列表，返回空流
    const Stream.empty(),
    _playingController.stream,
    _completedController.stream,
    _positionController.stream,
    _durationController.stream,
    _volumeController.stream,
    _rateController.stream,
    // pitch — AVPlayer 不支持变调
    const Stream.empty(),
    _bufferingController.stream,
    // bufferingPercentage — 用 0.0/100.0 近似
    const Stream.empty(),
    _bufferController.stream,
    // playlistMode — AVPlayer 不支持
    const Stream.empty(),
    // shuffle — AVPlayer 不支持
    const Stream.empty(),
    // audioParams — AVPlayer 不暴露
    const Stream.empty(),
    // videoParams — AVPlayer 不暴露
    const Stream.empty(),
    // audioBitrate
    const Stream.empty(),
    // audioDevice
    const Stream.empty(),
    // audioDevices
    const Stream.empty(),
    _trackController.stream,
    _tracksController.stream,
    // width
    const Stream.empty(),
    // height
    const Stream.empty(),
    // subtitle — 字幕内容
    const Stream.empty(),
    // log
    const Stream.empty(),
    _errorController.stream,
  );

  // ---------- 播放控制 ----------

  Future<void> playOrPause() async {
    await _native.togglePlay();
  }

  Future<void> seek(Duration duration) async {
    await _native.seek(duration);
  }

  Future<void> setVolume(double volume) async {
    // media_kit 音量范围 0-100，直接传给 NativePlayerController（内部转 0-1）
    await _native.setVolume(volume);
  }

  Future<void> setRate(double rate) async {
    await _native.setSpeed(rate);
  }

  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    // AVPlayer 字幕轨道通过 NativePlayerController.selectSubtitleTrack
    if (track.id == 'no' || track.id == 'auto') {
      // 关闭/自动字幕
    }
  }

  Future<void> dispose() async {
    await _playingController.close();
    await _positionController.close();
    await _durationController.close();
    await _bufferController.close();
    await _bufferingController.close();
    await _rateController.close();
    await _volumeController.close();
    await _trackController.close();
    await _tracksController.close();
    await _completedController.close();
    await _errorController.close();
  }

  // ---------- 状态同步 ----------

  bool _listening = false;

  /// 开始监听 NativePlayerController 的状态变化，同步到本适配器的 state/stream。
  void startListening() {
    if (_listening) return;
    _listening = true;
    _native.state.addListener(_onStateChanged);
    _native.volume.addListener(_onVolumeChanged);
    _native.speed.addListener(_onSpeedChanged);
    // 同步初始状态
    final s = _native.state.value;
    if (s != null) _onStateChanged();
  }

  void stopListening() {
    if (!_listening) return;
    _listening = false;
    _native.state.removeListener(_onStateChanged);
    _native.volume.removeListener(_onVolumeChanged);
    _native.speed.removeListener(_onSpeedChanged);
  }

  void _onVolumeChanged() {
    // NativePlayerController.volume 已是 0-100（与 media_kit 一致）
    final vol = _native.volume.value;
    if (vol != _volume) {
      _volume = vol;
      _volumeController.add(vol);
    }
  }

  void _onSpeedChanged() {
    final rate = _native.speed.value;
    if (rate != _rate) {
      _rate = rate;
      _rateController.add(rate);
    }
  }

  void _onStateChanged() {
    final s = _native.state.value;
    if (s == null) return;

    // playing
    final playing = s.isPlaying;
    if (playing != _playing) {
      _playing = playing;
      _playingController.add(playing);
    }

    // completed
    final completed = s.isCompleted;
    if (completed != _completed) {
      _completed = completed;
      _completedController.add(completed);
    }

    // position
    final pos = Duration(milliseconds: s.positionMs);
    if (pos != _position) {
      _position = pos;
      _positionController.add(pos);
    }

    // duration
    final dur = Duration(milliseconds: s.durationMs);
    if (dur != _duration) {
      _duration = dur;
      _durationController.add(dur);
    }

    // buffering（state == 'loading' 时为 true）
    final buffering = s.state == 'loading';
    if (buffering != _buffering) {
      _buffering = buffering;
      _bufferingController.add(buffering);
    }

    // volume（由 _onVolumeChanged 处理）
    _onVolumeChanged();

    // rate（由 _onSpeedChanged 处理）
    _onSpeedChanged();

    // buffer（AVPlayer 不暴露精确 buffer 位置，用 position 近似）
    if (pos != _buffer) {
      _buffer = pos;
      _bufferController.add(pos);
    }

    // error
    if (s.error != null) {
      _errorController.add(s.error!);
    }
  }
}
