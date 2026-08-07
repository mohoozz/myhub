import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:myhub_flutter/core/api/file_api.dart';
import 'package:myhub_flutter/core/api/stream_api.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/core/settings/settings_provider.dart';
import 'package:myhub_flutter/data/repositories/progress_repository.dart';
import 'package:myhub_flutter/shared/providers/auth_state_provider.dart';

/// 直通格式（与后端 `directStreamExts` 一致）：media_kit/libmpv 直接流式解码。
const Set<String> _passthroughExts = {
  // 视频
  'mp4', 'webm', 'm4v', 'mkv', 'avi', 'mov',
  // 音频
  'mp3', 'm4a', 'flac', 'wav', 'ogg',
};

/// 音频扩展名（mediaType 缺失/不准确时的兜底识别）。
const Set<String> _audioExts = {
  'mp3', 'm4a', 'flac', 'wav', 'ogg', 'aac', 'ape', 'wma', 'opus',
};

/// 外挂字幕扩展名（后端统一转 WebVTT：srt/ass/ssa，vtt 透传）。
const Set<String> _subtitleExts = {'srt', 'ass', 'ssa', 'vtt'};

/// 全局媒体播放控制器（TODO 5.7）。
///
/// Player 由控制器持有而非全屏播放页：页面 pop 后播放继续，
/// 底部迷你条跨页面接管（暂停/关闭/重新展开）；页面仅作视图层。
final mediaPlayerProvider = Provider<MediaPlayerController>((ref) {
  final controller = MediaPlayerController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});

/// 媒体播放会话的所有者：
///
/// * Player/VideoController 生命周期、直链/HLS 选择与失败互换兜底；
/// * 外挂字幕自动检测加载；视频/音频模式按媒体轨自动校正；
/// * 播放进度每 5 秒节流上报 `PUT /api/progress`，暂停/停止/播完即时上报；
/// * 打开已播放文件自动 seek 到上次位置（已完成的从头播放）；
/// * 迷你播放器可见性（[miniVisible]）。
class MediaPlayerController {
  MediaPlayerController(this._ref);

  final Ref _ref;

  /// 进度上报间隔。
  static const Duration _reportInterval = Duration(seconds: 5);

  /// 恢复进度的最小有效秒数（小于则从头播放）。
  static const double _resumeMinSec = 3;

  Player? _player;
  VideoController? _videoController;
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _reportTimer;

  /// 音量持久化的防抖计时器。
  Timer? _volumeSaveTimer;

  int? _sourceId;
  FileItem? _file;

  bool _useHls = false;

  /// 直链/HLS 是否已互换兜底过一次。
  bool _swapped = false;

  /// 是否成功进入过播放（区分加载失败与播放中故障）。
  bool _everPlayed = false;

  /// 外挂字幕是否已检测加载过（每会话仅一次）。
  bool _subsLoaded = false;

  /// 打开成功后待 seek 的恢复位置。
  Duration? _pendingResume;

  // ---------- 供 UI 订阅的状态 ----------

  /// 首次加载中。
  final ValueNotifier<bool> loading = ValueNotifier(true);

  /// 致命错误信息（null = 正常）。
  final ValueNotifier<String?> error = ValueNotifier(null);

  /// 视频/音频模式（tracks 流自动校正）。
  final ValueNotifier<bool> isVideoMode = ValueNotifier(true);

  /// 迷你播放器可见性（全屏页打开时强制隐藏）。
  final ValueNotifier<bool> miniVisible = ValueNotifier(false);

  /// 会话版本：每次切换媒体自增。
  /// 迷你条据此重建（file/player 非可监听对象，切换会话后
  /// 不重建会残留旧会话的画面与标题）。
  final ValueNotifier<int> sessionVersion = ValueNotifier(0);

  Player? get player => _player;
  VideoController? get videoController => _videoController;
  int? get sourceId => _sourceId;
  FileItem? get file => _file;

  /// 是否有已加载的媒体会话。
  bool get hasMedia => _player != null && _file != null;

  // ---------- 页面生命周期 ----------

  /// 全屏播放页打开：隐藏迷你条。
  ///
  /// 在页面 initState/dispose 中调用，处于组件树锁定阶段，
  /// 直接通知会被框架丢弃——统一延迟到帧后执行。
  void pageOpened() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      miniVisible.value = false;
    });
  }

  /// 全屏播放页关闭：媒体仍在播放时显示迷你条。
  void pageClosed() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      miniVisible.value = hasMedia && error.value == null;
    });
  }

  // ---------- 播放会话 ----------

  /// 播放指定媒体；同一媒体已在会话中时直接复用（迷你条 → 全屏页回迁）。
  ///
  /// 同步完成 Player 创建，调用方随后即可读取 [player]/[videoController]。
  void play(int sourceId, FileItem file) {
    if (hasMedia && _sourceId == sourceId && _file!.path == file.path) {
      return;
    }
    _switchTo(sourceId, file);
  }

  /// 停止播放并销毁会话（迷你条关闭按钮 / 拖拽关闭）。
  Future<void> stop() async {
    // 先隐藏迷你条：Dismissible 关闭动画期间不能残留在树上
    miniVisible.value = false;
    _reportTimer?.cancel();
    _reportTimer = null;
    // 停止前补报一次最终进度
    if (hasMedia && _everPlayed) {
      unawaited(_report());
    }
    await _teardown();
  }

  /// 错误视图重试：重置兜底状态，按初始模式重新打开（不重复恢复进度）。
  void retry() {
    if (!hasMedia) return;
    loading.value = true;
    error.value = null;
    _swapped = false;
    _everPlayed = false;
    _useHls = _initialUseHls(_file!.name);
    unawaited(_open());
  }

  /// 初始播放模式：转码偏好优先 HLS，否则直通格式走直链。
  bool _initialUseHls(String name) {
    if (_ref.read(playerSettingsProvider).preferTranscode) return true;
    return !_passthroughExts.contains(_extOf(name));
  }

  /// 切换媒体：同步拆除旧会话、同步建立新会话，异步打开流。
  void _switchTo(int sourceId, FileItem file) {
    _reportTimer?.cancel();
    _reportTimer = null;
    if (hasMedia && _everPlayed) {
      unawaited(_report()); // 旧会话最终进度
    }
    // 同步拆除（Player dispose 火忘即可）
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    final oldPlayer = _player;
    if (oldPlayer != null) {
      unawaited(oldPlayer.dispose());
    }

    _sourceId = sourceId;
    _file = file;
    _useHls = _initialUseHls(file.name);
    _swapped = false;
    _everPlayed = false;
    _subsLoaded = false;
    _pendingResume = null;

    loading.value = true;
    error.value = null;
    isVideoMode.value = _guessIsVideo(file);
    sessionVersion.value++; // 通知迷你条等 UI 重建订阅

    _player = _createPlayer(file.name);
    if (isVideoMode.value) {
      _videoController = VideoController(_player!);
    } else {
      _videoController = null;
    }
    _listen();
    unawaited(_openWithResume());
  }

  Future<void> _teardown() async {
    _volumeSaveTimer?.cancel();
    _volumeSaveTimer = null;
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    final p = _player;
    _player = null;
    _videoController = null;
    _sourceId = null;
    _file = null;
    _pendingResume = null;
    if (p != null) {
      await p.dispose();
    }
  }

  /// 释放全部资源（Provider 销毁时）。
  void dispose() {
    _reportTimer?.cancel();
    unawaited(_teardown());
    loading.dispose();
    error.dispose();
    isVideoMode.dispose();
    miniVisible.dispose();
    sessionVersion.dispose();
  }

  // ---------- 内部：Player 创建与状态监听 ----------

  static String _extOf(String name) {
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i + 1).toLowerCase();
  }

  /// 视频/音频初始识别：优先 mediaType，扩展名兜底，未知按视频处理。
  static bool _guessIsVideo(FileItem file) {
    if (file.isVideo) return true;
    if (file.isAudio) return false;
    return !_audioExts.contains(_extOf(file.name));
  }

  /// 创建 Player：平台特定硬解策略（移动端 / 桌面端）。
  static Player _createPlayer(String title) {
    final player = Player(
      configuration: PlayerConfiguration(
        title: title,
        logLevel: kDebugMode ? MPVLogLevel.debug : MPVLogLevel.error,
      ),
    );
    final platform = player.platform;
    if (platform is NativePlayer) {
      if (Platform.isIOS) {
        // iOS：优先使用 VideoToolbox 硬解（H.264/HEVC），功耗低；
        // iOS Simulator 上无 VideoToolbox 硬解，mpv 会自动回退到软解。
        platform.setProperty('hwdec', 'videotoolbox');
        platform.setProperty('videotoolbox-allow-formats', 'all');
        // iOS 上 libmpv 默认 gpu 视频输出在 Simulator 不可用时
        // 会自动回退；显式声明可避免不必要的探测日志。
        platform.setProperty('gpu-api', 'opengl');
        // iOS 音频走 AudioUnit（AVAudioSession）；
        // 模拟器无音频硬件时 mpv 会报 "Could not open/initialize audio device"，
        // 显式声明后端避免反复探测；无音频设备时静默降级（不中断视频播放）。
        platform.setProperty('ao', 'audio_unit');
        // 暂停/结束后保持连接，避免 iOS 后台 AV 清理引发会话异常
        platform.setProperty('keep-open', 'always');
        platform.setProperty('keep-paused', 'yes');
      } else if (Platform.isAndroid) {
        // Android：硬解优先（mediacodec）
        platform.setProperty('hwdec', 'mediacodec');
      } else {
        // 桌面端：保守硬解，规避个别驱动解码异常
        platform.setProperty('hwdec', 'auto-safe');
      }
    }
    return player;
  }

  void _listen() {
    final player = _player!;
    _subs.addAll([
      player.stream.playing.listen(_onPlaying),
      player.stream.tracks.listen(_onTracks),
      player.stream.completed.listen(_onCompleted),
      player.stream.error.listen(_onError),
      player.stream.volume.listen(_onVolume),
    ]);
  }

  /// 音量变化：防抖 300ms 后持久化（重启应用恢复上次音量）。
  void _onVolume(double v) {
    _volumeSaveTimer?.cancel();
    _volumeSaveTimer = Timer(const Duration(milliseconds: 300), () {
      final settings = _ref.read(playerSettingsProvider);
      if ((settings.volume - v).abs() < 0.5) return;
      unawaited(
        _ref
            .read(playerSettingsProvider.notifier)
            .update(settings.copyWith(volume: v)),
      );
    });
  }

  void _onPlaying(bool v) {
    debugPrint('[player] _onPlaying=$v everPlayed=$_everPlayed');
    if (v) {
      _everPlayed = true;
      loading.value = false;
      // 播放中每 5 秒节流上报进度
      _reportTimer?.cancel();
      _reportTimer = Timer.periodic(_reportInterval, (_) => _report());
    } else {
      // 暂停：停止节流并即时上报一次
      _reportTimer?.cancel();
      _reportTimer = null;
      if (_everPlayed) {
        unawaited(_report());
      }
    }
  }

  void _onCompleted(bool v) {
    if (!v) return;
    _reportTimer?.cancel();
    _reportTimer = null;
    // 播完：percent 100（后端自动标记已完成，下次从头播放）
    unawaited(_report(completed: true));
  }

  /// 视频/音频模式自动切换：带 albumart/image 标记的轨道是音频内嵌封面。
  void _onTracks(Tracks tracks) {
    final hasRealVideo =
        tracks.video.any((t) => t.albumart != true && t.image != true);
    // 音视频轨均为空：解复用信息不足，维持当前模式
    if (!hasRealVideo && tracks.audio.isEmpty) return;
    if (hasRealVideo == isVideoMode.value) return;
    if (hasRealVideo && _videoController == null) {
      // 初始误判为音频：补建视频输出
      _videoController = VideoController(_player!);
    }
    isVideoMode.value = hasRealVideo;
  }

  void _onError(String message) {
    // 尚未成功播放过：直链/HLS 互换兜底重试一次
    if (!_everPlayed && !_swapped) {
      _swapped = true;
      _useHls = !_useHls;
      unawaited(_open());
      return;
    }
    // 已成功播放后：mpv error 级日志多为非致命（解码/流读取警告），
    // 不破坏会话与 UI，仅记录（否则会误抑制迷你条/误显错误页）
    if (_everPlayed) {
      debugPrint('[player] 播放中非致命错误（忽略）: $message');
      return;
    }
    final msg = message.trim();
    loading.value = false;
    error.value = msg.isEmpty ? '未知播放错误' : msg;
  }

  // ---------- 内部：打开流 / 字幕 / 进度 ----------

  Future<void> _openWithResume() async {
    final sourceId = _sourceId;
    final file = _file;
    if (sourceId == null || file == null) return;
    _pendingResume = await _fetchResumePosition(sourceId, file.path);
    if (!hasMedia || _file!.path != file.path) return; // 会话已切换
    await _open();
  }

  /// 按当前模式（直链 / HLS）打开播放源，附带 JWT 鉴权头。
  Future<void> _open() async {
    final player = _player;
    final sourceId = _sourceId;
    final file = _file;
    if (player == null || sourceId == null || file == null) return;
    try {
      final token =
          await const FlutterSecureStorage().read(key: kAccessTokenKey);
      if (!identical(_player, player)) return; // 会话已切换
      final url = _useHls
          ? StreamApi.hlsPlaylistUrl(sourceId, file.path)
          : StreamApi.streamUrl(sourceId, file.path);
      await player.open(
        Media(
          url,
          httpHeaders: {
            if (token != null && token.isNotEmpty)
              'Authorization': 'Bearer $token',
          },
        ),
        play: true,
      );
      if (!identical(_player, player)) return;
      final settings = _ref.read(playerSettingsProvider);
      // 应用默认倍速（1.0 时跳过避免多余调用）
      if (settings.defaultSpeed != 1.0) {
        unawaited(player.setRate(settings.defaultSpeed));
      }
      // 恢复上次音量（新建 Player 默认 100）
      if ((player.state.volume - settings.volume).abs() > 0.5) {
        unawaited(player.setVolume(settings.volume));
      }
      // 恢复上次播放位置：open 返回 ≠ 文件加载完成，
      // 此时 seek 会被 mpv 丢弃（表现为从头播放），需等 demuxer 就绪后再 seek。
      // 注意 _pendingResume 在 seek 真正执行时才清除，
      // 保证直链/HLS 兜底互换重新 open 后仍能恢复。
      final resume = _pendingResume;
      if (resume != null) {
        unawaited(_seekWhenReady(player, resume));
      }
      // 外挂字幕自动检测加载（仅一次；失败不影响播放）
      if (!_subsLoaded) {
        _subsLoaded = true;
        unawaited(_loadExternalSubtitles(player, sourceId, file));
      }
    } catch (e) {
      _onError('$e');
    }
  }

  /// 等待 demuxer 就绪（duration 非零）后 seek 到恢复位置。
  ///
  /// media_kit 的 open 仅等待命令下发，网络流加载完成前 mpv 尚无时长，
  /// 期间下达的 seek 会被丢弃；超时或会话切换则静默放弃（从头播放）。
  Future<void> _seekWhenReady(Player player, Duration target) async {
    try {
      if (player.state.duration <= Duration.zero) {
        await player.stream.duration
            .firstWhere((d) => d > Duration.zero)
            .timeout(const Duration(seconds: 20));
      }
      if (!identical(_player, player)) return; // 会话已切换
      if (_pendingResume == null) return; // 已被其他路径消费
      _pendingResume = null;
      await player.seek(target);
    } catch (_) {
      // 超时 / Player 已销毁：放弃恢复
    }
  }

  /// 查询已保存的播放位置（null = 无记录 / 已完成 / 过短从头播放）。
  Future<Duration?> _fetchResumePosition(int sourceId, String path) async {
    try {
      final p =
          await _ref.read(progressRepositoryProvider).get(sourceId, path);
      if (p == null || p.finished) return null;
      if (p.progressJson.isEmpty) return null;
      final decoded = jsonDecode(p.progressJson);
      if (decoded is Map && decoded['position'] is num) {
        final sec = (decoded['position'] as num).toDouble();
        if (sec >= _resumeMinSec) {
          return Duration(milliseconds: (sec * 1000).round());
        }
      }
    } catch (_) {
      // 进度查询失败：从头播放
    }
    return null;
  }

  /// 播放进度上报（节流由调用方控制）。
  Future<void> _report({bool completed = false}) async {
    final player = _player;
    final file = _file;
    final sourceId = _sourceId;
    if (player == null || file == null || sourceId == null) return;
    final duration = player.state.duration;
    final position = player.state.position;
    final percent = duration > Duration.zero
        ? (position.inMilliseconds / duration.inMilliseconds * 100)
            .clamp(0.0, 100.0)
        : 0.0;
    try {
      // 本地 drift + 后端双写（离线时待同步，F-502）
      await _ref.read(progressRepositoryProvider).save(
            sourceId: sourceId,
            filePath: file.path,
            mediaType: file.isAudio ? 'audio' : 'video',
            title: file.name,
            progressJson:
                jsonEncode({'position': position.inMilliseconds / 1000}),
            percent: completed ? 100.0 : percent,
          );
    } catch (_) {
      // 上报失败静默（网络波动等）
    }
  }

  /// 外挂字幕自动检测与加载（TODO 5.6）。
  ///
  /// 匹配同目录下与媒体同名的字幕文件（`movie.srt` / `movie.zh.ass` 等），
  /// 逐条 sub-add，最后一条自动选中；HTTP 鉴权头随播放器全局生效。
  Future<void> _loadExternalSubtitles(
    Player player,
    int sourceId,
    FileItem file,
  ) async {
    try {
      final path = file.path;
      final slash = path.lastIndexOf('/');
      final dir = slash <= 0 ? '/' : path.substring(0, slash);
      final items =
          await _ref.read(fileApiProvider).listFiles(sourceId, dir);
      if (!identical(_player, player)) return;

      var base = file.name;
      final dot = base.lastIndexOf('.');
      if (dot > 0) {
        base = base.substring(0, dot);
      }
      base = base.toLowerCase();

      final subs = <String>[];
      for (final e in items) {
        if (e is! Map<String, dynamic> || e['isDir'] == true) continue;
        final name = e['name'] as String? ?? '';
        final extDot = name.lastIndexOf('.');
        if (extDot <= 0) continue;
        if (!_subtitleExts.contains(name.substring(extDot + 1).toLowerCase())) {
          continue;
        }
        final stem = name.substring(0, extDot).toLowerCase();
        if (stem == base || stem.startsWith('$base.')) {
          subs.add(name);
        }
      }
      if (subs.isEmpty || !identical(_player, player)) return;

      subs.sort();
      for (final name in subs) {
        final subPath = dir == '/' ? '/$name' : '$dir/$name';
        await player.setSubtitleTrack(
          SubtitleTrack.uri(
            StreamApi.subtitleUrl(sourceId, subPath),
            title: name,
          ),
        );
      }
    } catch (_) {
      // 字幕探测/加载失败不影响播放
    }
  }
}
