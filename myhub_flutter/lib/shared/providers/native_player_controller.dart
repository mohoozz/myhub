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
  /// 加载超时兜底：进入 loading 后长时间（15s）无 ready/playing 事件时
  /// 主动清除加载遮罩并报错，避免「一直显示加载中」卡死。
  Timer? _loadingTimer;

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

  /// 会话代际：每次 play()/stop() 递增。
  ///
  /// 用于作废跨会话挂起的进度恢复：_restorePosition 在 await 历史进度
  /// 与 ready 事件期间可能跨越会话边界（如视频切 media_kit 软解后停掉、
  /// 再打开音频），若不做守卫，旧会话恢复函数会在新会话 open 时被
  /// _restoreCompleter.complete() 唤醒，把旧文件的 seek 打到新播放器上
  /// （日志实证：音频再次打开时被视频的 4135531ms seek 打到末尾卡死）。
  int _sessionEpoch = 0;

  /// 当前是否使用 HLS 播放（直链 / HLS）。默认跟随转码偏好。
  bool _useHls = false;

  /// 直链/HLS 是否已互换兜底过一次。
  bool _swapped = false;

  /// 已知的真实总时长（毫秒）。直链阶段可拿到完整时长，
  /// 切 HLS 后（实时转码 seekable 范围渐进增长）用它修正总时长显示。
  int _knownDurationMs = 0;

  /// 渲染用 texture id（原生 AVPlayer 视频帧），可监听。
  final ValueNotifier<int> textureId = ValueNotifier(0);

  /// 视频真实宽高（原生从 CVPixelBuffer 提取），用于按比例渲染，
  /// 避免竖屏/4:3 等非 16:9 视频被拉伸。首次有效帧后填充。
  final ValueNotifier<int> videoWidth = ValueNotifier(0);
  final ValueNotifier<int> videoHeight = ValueNotifier(0);

  /// 无视频帧兜底回调（由上层播放器路由层注入）。
  ///
  /// 原生层上报「播放中持续无视频帧」（如 HEVC 无法硬解）时，
  /// 若设置了此回调则交给上层决定兜底策略（如切 media_kit 软解），
  /// 否则走默认行为（切 HLS 转码）。
  void Function()? onNoVideoFrame;

  int? get sourceId => _sourceId;
  FileItem? get file => _file;
  bool get hasMedia => _file != null;

  bool _initialized = false;

  Future<void> _ensureInit() async {
    if (_initialized) return;
    _initialized = true;
    _eventSub = _events.receiveBroadcastStream().listen(_onEvent);
  }

  /// 加载超时兜底：15 秒内没有收到 ready/playing 事件就强制清 loading 并报错，
  /// 防止原生事件全部丢失或卡死时 UI 永远停留在加载遮罩。
  void _startLoadingTimer() {
    _loadingTimer?.cancel();
    _loadingTimer = Timer(const Duration(seconds: 15), () {
      if (loading.value) {
        debugPrint('[native-player] 加载超时，强制退出 loading');
        loading.value = false;
        error.value = '加载超时，请检查网络后重试';
      }
    });
  }

  void _cancelLoadingTimer() {
    _loadingTimer?.cancel();
    _loadingTimer = null;
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
    // 原生层上报视频真实宽高（首次有效帧），用于按比例渲染
    final vw = map['videoWidth'];
    final vh = map['videoHeight'];
    if (vw is num && vh is num && vw.toInt() > 0 && vh.toInt() > 0) {
      videoWidth.value = vw.toInt();
      videoHeight.value = vh.toInt();
      debugPrint('[native-player] 视频宽高: ${vw.toInt()}x${vh.toInt()}');
    }
    // 原生层上报「播放中持续无视频帧」（如 HEVC 无法硬解，有声音无画面）。
    // 立即切换 HLS 重开（仅视频 + 直链 + 尚未 swap 时生效一次）。
    if (map['noVideoFrame'] == true) {
      debugPrint('[native-player] 收到 noVideoFrame 事件，切换 HLS');
      _handleNoVideoFrame();
      return;
    }
    // 纯音量/亮度同步事件（不含 state）不应更新播放状态，
    // 否则 positionMs/durationMs 等会重置为 0，导致进度条回到开头。
    final st = map['state'];
    final pm = map['positionMs'];
    final dm = map['durationMs'];
    debugPrint('[native-player] _onEvent state=$st pos=$pm dur=$dm');
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
    // 记录已知的真实总时长：直链阶段能拿到完整时长（8899s），
    // HLS 实时转码阶段 seekable 范围渐进增长，时长偏小。
    // 取较大值作为真实时长，切 HLS 后用于修正。
    if (s.durationMs > _knownDurationMs) {
      _knownDurationMs = s.durationMs;
    }
    state.value = s;

    if (s.error != null) {
      debugPrint('[native-player] 错误事件: error=${s.error}');
      error.value = s.error;
      loading.value = false;
      return;
    }
    if (s.state == 'ready' || s.state == 'playing') {
      if (s.state == 'ready') {
        loading.value = false;
        // Ready: trigger the restore-position Completer so the seek runs after
        // AVPlayer is truly ready。不能依赖 !_everPlayed：原生 rateObserver
        // 注册时（.new 选项）会先回调一次 playing（_everPlayed 已置 true），
        // 随后 ready 事件仍需完成 completer，否则音频进度恢复的 seek 会被
        // 跳过（等 10 秒超时后丢弃），表现为「当前播放时间错误」。
        final done = _restoreCompleter;
        if (done != null && !done.isCompleted) done.complete();
        _cancelLoadingTimer();
      }
      if (s.state == 'playing') {
        _everPlayed = true;
        loading.value = false;
        _cancelLoadingTimer();
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
      // 只在从未进入播放态时才置 loading=true：
      // 原生 open() 中 rateObserver 注册时立即回调一次 playing，随后 open()
      // 末尾才发 loading，事件顺序为 playing → loading。若此处无条件置 true，
      // 会把刚清除的 loading 又置回；若后续再无 playing 事件（timeObserver
      // 被 isSeeking 挡掉、item 异常等），loading 将永远为 true，UI 一直
      // 显示加载中。配合 _startLoadingTimer 超时兜底。
      if (!_everPlayed) {
        loading.value = true;
        _startLoadingTimer();
      }
    }
  }

  void play(int sourceId, FileItem file) {
    _sourceId = sourceId;
    _file = file;
    isVideoMode.value = file.isVideo;
    loading.value = true;
    error.value = null;
    _everPlayed = false;
    _swapped = false;
    // 新会话开始：清空上个会话残留的播放状态。
    // 否则 _switchToSoftDecode 等读取 state.value 会拿到旧媒体的
    // position（日志实证：播放视频时 curPos=7000 竟是上一音频的位置），
    // 导致新媒体的恢复位置被打错（视频无法跳到历史记录点）。
    state.value = null;
    // 新会话开始：作废旧会话可能挂起的进度恢复（见 _sessionEpoch 说明）。
    _sessionEpoch++;
    // 新会话：重置已知真实总时长，避免把上一媒体（如 8899s 视频）的
    // 时长传给原生，导致音频等新媒体总时长/进度显示错误。
    _knownDurationMs = 0;
    // 音频不涉及 HLS 转码（无视频可转），恒用直链。
    // 视频跟随转码偏好：true 优先 HLS，否则直链。
    _useHls = !file.isAudio && _ref.read(playerSettingsProvider).preferTranscode;
    debugPrint('[native-player] play: name=${file.name} isAudio=${file.isAudio} '
        'useHls=$_useHls preferTranscode=${_ref.read(playerSettingsProvider).preferTranscode}');
    // 关键：恢复进度用的 completer 必须在 _open() 之前创建。
    // 原生 open() 之后 ready 事件会很快到达（可能早于 _open() 末尾），
    // 若 completer 在 _open() 末尾才创建，_onEvent 处理 ready 时拿到的是
    // 上个会话的 null/旧 completer，新 completer 永远等不到 ready，
    // _restorePosition 在 10s 超时后直接放弃 seek（音频/视频都无法恢复进度）。
    // 这里先作废旧 completer 再新建，确保 ready 事件被本会话捕获。
    final old = _restoreCompleter;
    if (old != null && !old.isCompleted) old.complete();
    _restoreCompleter = Completer<void>();
    unawaited(_open());
  }

  Future<void> _open() async {
    await _ensureInit();
    _startLoadingTimer();
    final sourceId = _sourceId;
    final file = _file;
    if (sourceId == null || file == null) return;
    try {
      final token =
          await const FlutterSecureStorage().read(key: kAccessTokenKey);
      final baseUrl = _ref.read(apiBaseUrlProvider);
      final url = _useHls
          ? StreamApi.hlsPlaylistUrl(sourceId, file.path, baseUrl: baseUrl)
          : StreamApi.streamUrl(sourceId, file.path, baseUrl: baseUrl);
      debugPrint('[native-player] _open: useHls=$_useHls url=$url '
          'knownDurationMs=$_knownDurationMs');
      await _channel.invokeMethod('open', {
        'url': url,
        'title': file.name,
        // 显式告知原生是否为音频：音频文件不创建视频输出/纹理，
        // 避免 iOS 上 Texture 显示一个空圆圈（默认占位）。
        'isAudio': file.isAudio,
        // 已知真实总时长（毫秒）：直链阶段拿到，切 HLS 后用于修正
        // 实时转码导致 seekable 范围渐进增长、时长偏小的问题。
        'knownDurationMs': _knownDurationMs,
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
      // 恢复进度：completer 已在 play() 中创建（早于 open，确保 ready 事件
      // 能被捕获），这里直接触发进度恢复即可。
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

  /// 处理原生层上报的「无视频帧」事件。
  ///
  /// 背景：iOS AVPlayer 对无法解码的视频（如 HEVC Level 6.2）不报错，
  /// 音频正常、视频轨静默失效，表现为"有声音无画面"。原生层在播放中
  /// 持续 3 秒未产出视频帧时上报此事件。
  ///
  /// 兜底策略：
  ///  - 若上层（播放器路由层）注入了 onNoVideoFrame 回调，交给上层决定
  ///    （如切 media_kit 软解，像 nPlayer 一样本地软解）；
  ///  - 否则默认切 HLS 转码（服务端转 H.264）。
  void _handleNoVideoFrame() {
    // 仅视频 + 直链 + 尚未 swap 时生效一次。
    if (!isVideoMode.value || _useHls || _swapped) return;
    final file = _file;
    final sourceId = _sourceId;
    if (file == null || sourceId == null) return;
    _swapped = true;
    final cb = onNoVideoFrame;
    if (cb != null) {
      debugPrint('[native-player] 无视频帧，交由上层播放器路由处理');
      cb();
      return;
    }
    _useHls = true;
    debugPrint('[native-player] 无视频帧，切换 HLS 重开');
    unawaited(_open());
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

  /// 恢复进度：等 item readyToPlay 后再 seek。
  ///
  /// 必须在 readyToPlay 后调用 seek，否则 AVPlayer 尚未加载完成，
  /// seek 命令会被静默丢弃（音频文件下尤为明显，因为音频流 moov 在
  /// 文件末尾、HTTP Range 加载需要时间）。通过一个 Completer 等
  /// `_onEvent` 收到 `state: ready` 后完成。
  Completer<void>? _restoreCompleter;

  Future<void> _restorePosition(int sourceId, String path) async {
    // 捕获发起时的会话代际与文件：await 历史进度/ready 期间可能发生
    // 会话切换（stop 后 play 新文件）。完成后必须校验代际与文件是否
    // 仍是当前会话，否则旧会话的恢复会把 seek 打到新会话的播放器上
    // （日志实证：音频再次打开时被上一视频的 4135531ms seek 打到末尾，
    // AVPlayer 直接 completed，UI 表现为一直加载中/没声音）。
    final epoch = _sessionEpoch;
    final file = _file;
    try {
      final p = await _ref.read(progressRepositoryProvider).get(sourceId, path);
      debugPrint('[native-player] _restorePosition: 历史进度 p=$p fileIsAudio=${file?.isAudio}');
      if (epoch != _sessionEpoch || !identical(file, _file)) {
        debugPrint('[native-player] _restorePosition: 会话已切换，放弃恢复');
        return;
      }
      if (p == null || p.finished || p.progressJson.isEmpty) return;
      final decoded = jsonDecode(p.progressJson);
      if (decoded is Map && decoded['position'] is num) {
        final sec = (decoded['position'] as num).toDouble();
        debugPrint('[native-player] _restorePosition: 历史 position=${sec}s');
        if (sec < 3) return;
        final ms = (sec * 1000).round();
        // 等待 readyToPlay 后再 seek（最多等 10 秒，避免无限等待）
        final done = _restoreCompleter;
        if (done == null) return;
        await done.future.timeout(const Duration(seconds: 10),
            onTimeout: () {});
        if (!done.isCompleted) return;
        // 会话守卫：等 ready 期间若又发生了会话切换（新 play/stop），
        // 放弃恢复，避免旧会话 seek 打到新会话播放器上。
        if (epoch != _sessionEpoch || !identical(file, _file)) {
          debugPrint('[native-player] _restorePosition: 会话已切换，放弃恢复');
          return;
        }
        // 防止历史进度被污染（如 8899s 视频残留）导致 seek 到无效位置。
        if (_knownDurationMs > 0 && ms > _knownDurationMs) {
          debugPrint('[native-player] _restorePosition: 目标 $ms 超过已知时长 $_knownDurationMs，跳过');
          return;
        }
        // 音频也需要恢复历史进度。此前曾因「音频 moov 在文件末尾、ready 时
        // duration 未加载完」的顾虑跳过音频 seek，但这导致音频每次从头播放。
        // 实际上 seek 已在 _restoreCompleter 上等待 ready，且目标秒数经过
        // 上面的时长校验，即使 duration 稍后才就绪，AVPlayer 也会在 item
        // 加载完成后执行 seek，不会卡住 loading（loading 由 ready/playing
        // 事件驱动，与 seek 无关）。
        debugPrint('[native-player] _restorePosition: seek 到 ${ms}ms');
        await _channel.invokeMethod('seek', {'positionMs': ms});
      }
    } catch (e) {
      debugPrint('[native-player] _restorePosition 失败: $e');
    }
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
    // 会话结束：作废挂起的进度恢复，并完成 completer 释放等 ready 的
    // await，让挂起的 _restorePosition 醒来后因 epoch 守卫直接放弃，
    // 不再把旧会话 seek 打到之后新会话的播放器上。
    _sessionEpoch++;
    final done = _restoreCompleter;
    if (done != null && !done.isCompleted) done.complete();
    await _channel.invokeMethod('dispose');
  }

  void dispose() {
    _eventSub?.cancel();
    _reportTimer?.cancel();
    _volumeSaveTimer?.cancel();
    _loadingTimer?.cancel();
    // 组件销毁同样作废挂起的进度恢复
    _sessionEpoch++;
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
    // position 无效（0）时不上报，避免把历史进度覆盖成 0：
    // open() 阶段 AVPlayer 尚未 ready，playing 事件携带 position=0，
    // 若上报会清掉用户已有的播放进度（音频 moov 加载期间尤甚）。
    if (!completed && s.positionMs <= 0) return;
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
