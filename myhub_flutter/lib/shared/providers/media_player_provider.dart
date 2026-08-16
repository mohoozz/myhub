import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:myhub_flutter/core/api/dio_client.dart';
import 'package:myhub_flutter/core/api/file_api.dart';
import 'package:myhub_flutter/core/api/stream_api.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/core/settings/server_config_provider.dart';
import 'package:myhub_flutter/core/settings/settings_provider.dart';
import 'package:myhub_flutter/data/repositories/progress_repository.dart';
import 'package:myhub_flutter/shared/providers/auth_state_provider.dart';
import 'package:myhub_flutter/shared/providers/av_player_adapter.dart';
import 'package:myhub_flutter/shared/providers/native_player_controller.dart';
import 'package:path_provider/path_provider.dart';

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
  AvPlayerAdapter? _avPlayer;
  VideoController? _videoController;
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _reportTimer;

  /// 周期性诊断日志计时器（播放中每 3 秒输出缓冲/解码/demuxer 状态）。
  Timer? _diagTimer;

  /// 诊断日志文件 IOSink（懒加载，首次写日志时打开）。
  IOSink? _diagSink;

  /// 诊断日志写入串行队列：避免并发 _diagLog 同时触发 _openDiagSink，
  /// 导致同一文件被打开多个 IOSink 而报 "StreamSink is bound to a stream"。
  Future<void> _diagQueue = Future.value();

  /// 音量持久化的防抖计时器。
  Timer? _volumeSaveTimer;

  int? _sourceId;
  FileItem? _file;

  bool _useHls = false;

  /// 直链/HLS 是否已互换兜底过一次。
  bool _swapped = false;

  /// iOS 软解兜底标记：AVPlayer 硬解失败（无视频帧）后，
  /// 切到 media_kit 软解（hwdec=no）播放，避免服务端转码。
  bool _softDecode = false;

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

  /// 当前播放器实例（iOS 为 AvPlayerAdapter，其他平台为 media_kit Player）。
  /// 类型为 dynamic，因为 UI 组件需要兼容两种播放器。
  dynamic get player => _avPlayer ?? _player;
  VideoController? get videoController => _videoController;

  /// AVPlayer 渲染 texture id（仅 iOS 使用 AVPlayer 时有效）。
  ValueNotifier<int>? get textureId => _avPlayer?.textureId;

  /// 视频真实宽高（仅 iOS AVPlayer 模式有效；软解/其他平台由
  /// media_kit 的 VideoController 自动按比例渲染，无需此项）。
  ValueNotifier<int>? get videoWidth => _avPlayer?.videoWidth;
  ValueNotifier<int>? get videoHeight => _avPlayer?.videoHeight;

  /// 是否使用 AVPlayer（iOS 平台）。
  bool get useAvPlayer => _avPlayer != null;

  int? get sourceId => _sourceId;
  FileItem? get file => _file;

  /// 是否有已加载的媒体会话。
  bool get hasMedia => (_player != null || _avPlayer != null) && _file != null;

  /// 是否处于 iOS 软解兜底模式（media_kit 软解）。
  ///
  /// 软解模式下音量/亮度应走系统（mpv 音量锁定 100，避免双重衰减），
  /// UI 据此决定音量/亮度操作是否同步系统。
  bool get isSoftDecode => _softDecode;

  /// 系统音量（0-100），软解模式下 UI 应显示/调节此值而非 mpv 内部音量。
  ValueNotifier<double> get systemVolume =>
      _ref.read(nativePlayerProvider).volume;

  /// 系统亮度（0-1），软解模式下 UI 应显示/调节此值。
  ValueNotifier<double> get systemBrightness =>
      _ref.read(nativePlayerProvider).brightness;

  /// 设置系统音量（0-100）。
  Future<void> setSystemVolume(double v) {
    debugPrint('[player] setSystemVolume: v=$v softDecode=$_softDecode');
    return _ref.read(nativePlayerProvider).setVolume(v);
  }

  /// 设置系统亮度（0-1）。
  Future<void> setSystemBrightness(double b) =>
      _ref.read(nativePlayerProvider).setBrightness(b);

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
    _diagTimer?.cancel();
    _diagTimer = null;
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
    _diagTimer?.cancel();
    _diagTimer = null;
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
    _softDecode = false;
    _everPlayed = false;
    _subsLoaded = false;
    _pendingResume = null;

    loading.value = true;
    error.value = null;
    isVideoMode.value = _guessIsVideo(file);
    sessionVersion.value++; // 通知迷你条等 UI 重建订阅

    if (Platform.isIOS) {
      // iOS：使用 AVPlayer 适配器，解决 media_kit 在 iOS 上 120fps 视频卡顿
      // （vo=libmpv 不支持 vf 滤镜/display-sync/decoder framedrop）。
      // 硬解失败（无视频帧，如 HEVC L6.2）时，通过 onNoVideoFrame 回调
      // 切到 media_kit 软解（见 _switchToSoftDecode）。
      _avPlayer = AvPlayerAdapter(_ref.read(nativePlayerProvider));
      _avPlayer!.startListening();
      _videoController = null;
      _listenAvPlayer();
      final native = _ref.read(nativePlayerProvider);
      native.onNoVideoFrame = _onAvNoVideoFrame;
      native.play(sourceId, file);
      unawaited(_openAvPlayerWithResume());
      // 视频文件：并行探测编码，HEVC 等无法硬解的直接切软解，
      // 比「黑屏 3 秒后无帧检测兜底」快得多，避免长时间黑屏。
      if (file.isVideo) {
        unawaited(_probeAndMaybeSoftDecode(sourceId, file));
      }
    } else {
      _avPlayer = null;
      _player = _createPlayer(file.name);
      if (isVideoMode.value) {
        // iOS：必须通过 VideoControllerConfiguration 指定硬解后端，否则
        // VideoController 创建时会把 hwdec 覆盖为 auto，导致 iOS 走软解
        // 高分辨率视频 CPU 满载、画面+声音一起卡顿。
        _videoController = VideoController(
          _player!,
          configuration: const VideoControllerConfiguration(
            hwdec: 'videotoolbox-copy',
            vo: 'libmpv',
          ),
        );
      } else {
        _videoController = null;
      }
      _listen();
      unawaited(_openWithResume());
    }
  }

  Future<void> _teardown() async {
    _volumeSaveTimer?.cancel();
    _volumeSaveTimer = null;
    _diagTimer?.cancel();
    _diagTimer = null;
    await _diagLog('[session] 播放会话结束');
    await _closeDiagSink();
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    // 移除 AVPlayer 的 ValueNotifier 监听与无帧回调
    if (_avPlayer != null) {
      final native = _ref.read(nativePlayerProvider);
      native.loading.removeListener(_onAvLoading);
      native.error.removeListener(_onAvError);
      native.isVideoMode.removeListener(_onAvVideoMode);
      native.onNoVideoFrame = null;
    }
    final p = _player;
    final av = _avPlayer;
    _player = null;
    _avPlayer = null;
    _videoController = null;
    _sourceId = null;
    _file = null;
    _pendingResume = null;
    if (av != null) {
      av.stopListening();
      await _ref.read(nativePlayerProvider).stop();
      await av.dispose();
    }
    if (p != null) {
      await p.dispose();
    }
  }

  /// 释放全部资源（Provider 销毁时）。
  void dispose() {
    _reportTimer?.cancel();
    _diagTimer?.cancel();
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
        // 增大 demuxer 读入缓冲（默认 32MB）：高码率视频（如 20Mbps）在
        // iOS 有声播放（音频为时钟）时，默认 32MB 缓存易被吃穿触发反复
        // 缓冲；增大到 256MB 让 demuxer 缓存更长时间数据，显著降低缓冲。
        bufferSize: 256 * 1024 * 1024,
      ),
    );
    final platform = player.platform;
    if (platform is NativePlayer) {
      if (Platform.isIOS) {
        // iOS 硬解：用 videotoolbox-copy（硬解帧拷贝回内存走滤镜链）。
        platform.setProperty('hwdec', 'videotoolbox-copy');
        platform.setProperty('videotoolbox-allow-formats', 'all');
        // 120fps 视频 fps 滤镜（vf/vf-add）在 media_kit 的 vo=libmpv 模式下
        // 不生效（日志确认 vf= 始终为空，vf-fps=120）。
        // 改用 framedrop=decoder+insert：在解码阶段就丢弃多余帧，
        // 避免解码 120fps 全部帧导致数据消费过快 + vo 层丢帧。
        platform.setProperty('framedrop', 'decoder+insert');
        // video-sync=display-vdrop：以显示器刷新率为时钟，丢弃多余视频帧
        // 而不是等待音频时钟。60Hz 显示器下 120fps 视频会丢弃一半帧，
        // 实际渲染 60fps，数据消费速度减半。
        platform.setProperty('video-sync', 'display-vdrop');
        // vf 滤镜在 open 之后再尝试设置一次（部分 mpv 版本需要媒体加载后设置）。
        platform.setProperty('vf-add', 'fps=60');
        // iOS 音频：显式指定 audiounit 后端（media_kit 的 iOS mpv 唯一编译的
        // 音频后端，见 libmpv 构建配置 -Daudiounit=enabled）。后端注册名是
        // "audiounit"（不是带下划线的 audio_unit）。必须显式指定，否则 mpv
        // 自动初始化 AudioUnit 会拖累整个播放时钟导致视频卡顿；显式指定后
        // 配合 AppDelegate 激活的 AVAudioSession 即可正常出声且视频流畅。
        platform.setProperty('ao', 'audiounit');
        // audiounit 后端默认 audio-buffer=0（易触发 dropout，声音断续）。
        // 历史调参：0.5s → 声音断续（回调抖动吸收不足）；
        //           5s   → 声音正常但 A/V 同步偏移导致视频周期性定格加载。
        // 2 秒是平衡点：足够吸收 audiounit 回调抖动稳定音频时钟，
        // 又不会因缓冲过大导致视频等待音频时钟追赶。
        platform.setProperty('audio-buffer', '2');

        // ---------- 网络流预读策略 ----------
        //
        // 根因分析（mpv demux.c 源码确认）：
        // mpv demuxer 在独立线程运行，基于数据时间戳和字节数自主预读，
        // 不受音频时钟约束。预读决策公式：
        //   min_secs = max(demuxer-readahead-secs, cache-secs)  // 网络流
        //   预读条件: queue->last_ts - base_ts < min_secs
        //   停止条件: total_fw_bytes >= max_bytes (256MB)
        //
        // 真正瓶颈是 raw-input-rate（ffmpeg lavf HTTP 读取速度），
        // 在 iOS 上不如 AVPlayer 的原生 NSURLSession。增大预读目标
        // 让 demuxer 更积极地拉取数据，充分利用 256MB 缓冲区。
        //
        // 注意：cache-secs 默认 3600s，之前设 30 反而降低了预读目标。

        // demuxer 独立线程全速预读（默认 yes，显式确认）。
        platform.setProperty('demuxer-thread', 'yes');
        // 预读目标：mpv 源码中网络流 min_secs = max(readahead, cache-secs)。
        // 设为 10 秒：demuxer 预读 10 秒数据后开始播放，平衡启动速度和缓冲。
        platform.setProperty('demuxer-readahead-secs', '10');
        platform.setProperty('cache-secs', '10');
        // demuxer-seekable-cache：让 seek 后保留缓存，避免重新请求。
        platform.setProperty('demuxer-seekable-cache', 'yes');
        // MP4 moov-at-end 优化：日志显示 debug-byte-level-seeks 疯狂增长
        // （每 3 秒 100-200 次字节级 seek），每次 seek 都是一次 HTTP Range
        // 请求。根因是 MP4 moov atom 在文件末尾，mpv 需反复 seek 读取索引。
        //
        // 关键优化：demuxer-lavf-probe-info=no 跳过 lavf 对 MP4 的完整探测，
        // 只读取最小必要信息就开始播放，大幅减少初始 byte-level seeks。
        // 同时设 demuxer-lavf-analyzeduration=0 和 probesize=32K 减少探测开销。
        platform.setProperty('demuxer-lavf-probe-info', 'no');
        platform.setProperty('demuxer-lavf-analyzeduration', '0');
        platform.setProperty('demuxer-lavf-probesize', '32768');

        // ---------- 缓冲暂停策略 ----------
        //
        // 关闭 cache-pause：缓冲不足时不暂停播放，避免周期性定格。
        // 配合 framedrop=insert 丢弃无法及时渲染的帧，减少解码压力。
        // 之前关闭 cache-pause 导致音频断续，但当时 vf 滤镜也没生效（120fps
        // 全速解码）。现在 framedrop=insert 应该能改善。
        platform.setProperty('cache-pause', 'no');

        // ---------- 缓存配置 ----------
        //
        // cache=yes 启用内存缓存，cache-on-disk=no 关闭磁盘缓存
        // （media_kit 默认 cache-on-disk=yes，网络流先写盘再读回会拖慢 I/O）。
        platform.setProperty('cache', 'yes');
        platform.setProperty('cache-on-disk', 'no');

        // ---------- 连接保持 ----------
        platform.setProperty('keep-open', 'always');
        platform.setProperty('keep-paused', 'yes');
        // 网络超时：单位秒，过大值（如 30000）转微秒会溢出 int32 报错。
        platform.setProperty('network-timeout', '15');
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

  /// 创建软解播放器（iOS 专用）：AVPlayer 硬解失败时兜底。
  ///
  /// 复用 [_createPlayer] 的完整配置（网络预读、MP4 moov 索引、seek 缓存、
  /// 缓冲策略等），仅在最后把 hwdec 覆盖为 'no' 强制软件解码，
  /// 像 nPlayer 一样本地软解超出硬解能力的视频（如 HEVC Level 6.2）。
  ///
  /// 注意：hwdec 仍需在 VideoController 创建时显式传 'no'（默认 auto
  /// 会覆盖），见 _switchToSoftDecode。
  static Player _createSoftPlayer(String title) {
    final player = _createPlayer(title);
    final platform = player.platform;
    if (platform is NativePlayer && Platform.isIOS) {
      // 关键：禁用硬件解码，强制软件解码。
      platform.setProperty('hwdec', 'no');
      // 清除硬解路径为 120fps 视频加的 fps=60 滤镜：
      // 软解 HEVC 时该滤镜会在 seek 后强制插帧/丢帧，破坏时间戳，
      // 导致 seek 后画面与目标时间/音频错位。软解兜底不追求高帧率
      // 平滑，清除滤镜保证 seek 正确性。
      platform.setProperty('vf', '');
      // 软解 HEVC 高规格视频 CPU 压力大，丢弃解码器来不及处理的帧，
      // 避免音频时钟追赶导致周期性定格（与硬解路径 framedrop 策略一致）。
      platform.setProperty('framedrop', 'decoder+insert');
      // 恢复 MP4 完整探测以支持精确 seek：
      // 该视频 moov atom 在文件末尾（约 9.9MB），_createPlayer 为了顺序
      // 播放流畅设了 demuxer-lavf-probe-info=no + analyzeduration=0 +
      // probesize=32KB，代价是 mpv 不读取末尾 moov → seek 索引缺失 →
      // 跳转位置不准。软解兜底场景用户需要 seek，这里恢复默认完整探测：
      //   - probe-info=auto：让 mpv 按需 seek 读取末尾 moov 构建索引；
      //   - probesize 足够大（64MB）覆盖 9.9MB 的 moov；
      //   - analyzeduration 设 30s（单位是秒）给 lavf 充足探测时间。
      platform.setProperty('demuxer-lavf-probe-info', 'auto');
      platform.setProperty('demuxer-lavf-analyzeduration', '30');
      platform.setProperty('demuxer-lavf-probesize', '67108864');
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
      // 缓冲状态变化即时日志：定位卡顿是否由 cache-pause 触发
      player.stream.buffering.listen((b) {
        debugPrint('[player] buffering=$b');
        if (b) {
          // 进入缓冲：立即输出一次 demuxer 缓存详情
          unawaited(_diagLog('[buffering] 触发缓冲暂停'));
          unawaited(_diagSnapshot('buffering-start'));
          // 缓冲期间显示加载中（与 AVPlayer 路径 native.loading=true 行为一致）。
          loading.value = true;
        } else {
          unawaited(_diagLog('[buffering] 缓冲恢复'));
          // 缓冲恢复：mpv 缓冲期间 playing 属性保持 true，恢复后 playing 流
          // 不会再触发，必须在这里主动清除 loading，否则 UI 一直显示加载中。
          // 仅当已进入播放状态（_everPlayed）才清除，避免首帧前误撤加载遮罩。
          if (_everPlayed) {
            loading.value = false;
          }
        }
      }),
    ]);
  }

  /// AVPlayer 模式的状态监听。
  void _listenAvPlayer() {
    final av = _avPlayer!;
    final native = _ref.read(nativePlayerProvider);
    // 监听 loading 状态
    native.loading.addListener(_onAvLoading);
    // 监听错误状态
    native.error.addListener(_onAvError);
    // 监听视频/音频模式
    native.isVideoMode.addListener(_onAvVideoMode);
    // 播放完成
    _subs.add(av.stream.completed.listen((completed) {
      if (completed) {
        _reportTimer?.cancel();
        unawaited(_reportAv(completed: true));
      }
    }));
  }

  void _onAvLoading() {
    final native = _ref.read(nativePlayerProvider);
    if (!native.loading.value) {
      _everPlayed = true;
      loading.value = false;
      _reportTimer?.cancel();
      _reportTimer = Timer.periodic(_reportInterval, (_) => _reportAv());
    }
  }

  void _onAvError() {
    final native = _ref.read(nativePlayerProvider);
    final err = native.error.value;
    if (err != null) {
      error.value = err;
      loading.value = false;
    }
  }

  void _onAvVideoMode() {
    final native = _ref.read(nativePlayerProvider);
    isVideoMode.value = native.isVideoMode.value;
  }

  /// AVPlayer 无视频帧兜底：切到 media_kit 软解。
  ///
  /// 触发场景：iOS AVPlayer 对无法硬解的视频（如 HEVC Level 6.2）
  /// 静默丢弃视频轨（有声音无画面），原生层检测到持续无帧后上报。
  /// 这里切换到软解播放器（hwdec=no），像 nPlayer 一样本地软解。
  void _onAvNoVideoFrame() {
    if (_softDecode) return; // 已切软解，避免重复触发
    _softDecode = true;
    debugPrint('[player] AVPlayer 硬解失败，切换 media_kit 软解');
    unawaited(_switchToSoftDecode());
  }

  /// 播放前探测编码：HEVC 等 iOS 无法硬解的编码直接切软解。
  ///
  /// 在 AVPlayer 开始播放的同时并行探测（服务端 ffprobe，约几百 ms），
  /// 探测到无法硬解的编码后立即切软解，避免「黑屏 3 秒后无帧检测兜底」
  /// 的长时间黑屏。探测失败/非 HEVC 则保持 AVPlayer（无帧检测仍兜底）。
  Future<void> _probeAndMaybeSoftDecode(int sourceId, FileItem file) async {
    try {
      final dio = _ref.read(dioProvider);
      // dioProvider 的 baseUrl 是 /api 前缀，这里用相对路径即可。
      final resp = await dio.get<Map<String, dynamic>>(
        '/stream/probe?source=$sourceId&path=${Uri.encodeComponent(file.path)}',
      );
      // 服务端统一响应结构为 {code, data, message}，真实数据在 data 字段。
      final data = resp.data?['data'] as Map<String, dynamic>?;
      final codec = (data?['codec'] as String?)?.toLowerCase() ?? '';
      debugPrint('[player] 探测编码: codec=$codec resp=${resp.data}');
      // 会话已切换或已切软解：放弃本次探测结果
      if (!hasMedia || _file?.path != file.path || _softDecode) return;
      if (codec == 'hevc' || codec == 'h265' || codec == 'x265') {
        _softDecode = true;
        debugPrint('[player] 探测到 HEVC，提前切换 media_kit 软解');
        unawaited(_switchToSoftDecode());
      }
    } catch (e) {
      // 探测失败（网络/无 ffprobe 等）：保持 AVPlayer，靠无帧检测兜底
      debugPrint('[player] 编码探测失败，保持 AVPlayer: $e');
    }
  }

  /// 从 AVPlayer 切换到 media_kit 软解播放器（iOS）。
  ///
  /// 拆掉 AVPlayer 会话，创建软解 Player 并用直链打开（软解无需 HLS 转码），
  /// 同时恢复进度。保留当前媒体与播放位置。
  Future<void> _switchToSoftDecode() async {
    final sourceId = _sourceId;
    final file = _file;
    if (sourceId == null || file == null) return;

    // 记录当前播放位置，切软解后恢复
    final native = _ref.read(nativePlayerProvider);
    final curPos = native.state.value?.positionMs ?? 0;
    // curPos 仅在该媒体确实播放起来（≥恢复阈值 3s）时才可信：
    //  - 探测 HEVC 提前切换：AVPlayer 刚 open（pos≈0，且 play() 已清空
    //    旧会话残留的 state），应恢复历史进度而不是 0/残留位置；
    //  - 无帧检测切换：已播放一段时间（pos 有效），才用当前播放位置续播。
    final resume = curPos >= (_resumeMinSec * 1000)
        ? Duration(milliseconds: curPos)
        : await _fetchResumePosition(sourceId, file.path);
    debugPrint('[player] _switchToSoftDecode: curPos=$curPos '
        'resume=${resume?.inMilliseconds}');

    // 拆除 AVPlayer
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    final av = _avPlayer;
    if (av != null) {
      native.loading.removeListener(_onAvLoading);
      native.error.removeListener(_onAvError);
      native.isVideoMode.removeListener(_onAvVideoMode);
      native.onNoVideoFrame = null;
      av.stopListening();
      await native.stop();
      await av.dispose();
    }
    _avPlayer = null;

    // 通知 UI 重建：渲染方式从 AVPlayer 的 Texture 切到 media_kit 的 Video。
    sessionVersion.value++;
    loading.value = true;

    // 创建软解 Player 并用直链打开
    _player = _createSoftPlayer(file.name);
    if (isVideoMode.value) {
      // 关键：VideoControllerConfiguration 的 hwdec 默认是 auto，
      // 不显式指定会被覆盖回 auto 导致软解失效。这里必须 hwdec: 'no'。
      _videoController = VideoController(
        _player!,
        configuration: const VideoControllerConfiguration(
          hwdec: 'no',
          vo: 'libmpv',
        ),
      );
    } else {
      _videoController = null;
    }
    _useHls = false; // 软解直连，不走 HLS
    _everPlayed = false;
    _listen();
    // 软解模式音量统一走系统：mpv 音量锁定 100 不做衰减，
    // 否则 mpv 内部音量 × 系统音量会双重衰减，且与系统音量脱节。
    // （iOS 上 mpv 用 audiounit 输出，系统音量即为最终音量。）
    unawaited(_player!.setVolume(100));
    _pendingResume = resume;
    await _open();
  }

  /// AVPlayer 模式的进度上报。
  Future<void> _reportAv({bool completed = false}) async {
    final file = _file;
    final sourceId = _sourceId;
    if (file == null || sourceId == null) return;
    final s = _ref.read(nativePlayerProvider).state.value;
    if (s == null) return;
    try {
      await _ref.read(progressRepositoryProvider).save(
            sourceId: sourceId,
            filePath: file.path,
            mediaType: file.isAudio ? 'audio' : 'video',
            title: file.name,
            progressJson: jsonEncode({'position': s.positionMs / 1000}),
            percent: completed ? 100.0 : s.percent,
          );
    } catch (_) {}
  }

  /// AVPlayer 模式：打开媒体并恢复进度。
  /// NativePlayerController.play 已处理 URL 构建、鉴权头、倍速恢复，
  /// 并与系统当前音量/亮度保持一致，这里只负责进度恢复。
  Future<void> _openAvPlayerWithResume() async {
    final sourceId = _sourceId;
    final file = _file;
    if (sourceId == null || file == null) return;
    // NativePlayerController.play 已在 _switchTo 中调用，
    // 这里只需等待加载完成并恢复进度（进度恢复由 NativePlayerController 内部处理）。
    // 无需额外操作。
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
      // 诊断：播放 3 秒后（解码器已建立）确认硬解状态
      Timer(const Duration(seconds: 3), _diagnoseHwdec);
      // 记录播放会话信息到日志文件
      unawaited(_diagLog('[session] 开始播放 file=${_file?.name} '
          'sourceId=$_sourceId useHls=$_useHls'));
      // 周期性诊断：每 3 秒输出缓冲/解码/demuxer 状态
      _diagTimer?.cancel();
      _diagTimer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => unawaited(_diagSnapshot('periodic')),
      );
    } else {
      // 暂停/缓冲：停止进度上报与诊断
      _reportTimer?.cancel();
      _reportTimer = null;
      _diagTimer?.cancel();
      _diagTimer = null;
      if (_everPlayed) {
        unawaited(_report());
      }
      // 不在这里设置 loading=true：
      //  - 主动暂停（playing=false 且未缓冲）应显示暂停状态，而非加载遮罩；
      //  - 缓冲加载由 stream.buffering 监听管理（b=true → loading=true），
      //    缓冲结束恢复播放时 playing=true 会清除 loading，闭环完整。
    }
  }

  // ---------- 诊断日志 ----------

  /// 写入一行诊断日志到文件（同时输出到 debugPrint）。
  ///
  /// 日志文件路径：应用文档目录/player_diag.log
  /// 每次 新播放会话 写入分隔线，便于区分多次播放。
  Future<void> _diagLog(String line) {
    final ts = DateTime.now().toIso8601String().substring(11, 23); // HH:mm:ss.SSS
    final formatted = '[$ts] $line';
    debugPrint('[player]$line');
    // 串行写入：所有 _diagLog 按调用顺序排队执行，避免并发打开多个 IOSink
    // 写同一文件（"StreamSink is bound to a stream"）。
    _diagQueue = _diagQueue.then((_) async {
      try {
        _diagSink ??= await _openDiagSink();
        _diagSink!.writeln(formatted);
        await _diagSink!.flush();
      } catch (e) {
        debugPrint('[player] 诊断日志写入失败: $e');
      }
    });
    return _diagQueue;
  }

  /// 懒加载打开诊断日志文件 IOSink。
  Future<IOSink> _openDiagSink() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/player_diag.log';
    final file = File(path);
    final sink = file.openWrite(mode: FileMode.append);
    sink.writeln('');
    sink.writeln('========== 新播放会话 ${DateTime.now().toIso8601String()} ======');
    sink.writeln('文件: ${_file?.name} sourceId=$_sourceId useHls=$_useHls');
    await sink.flush();
    return sink;
  }

  /// 关闭诊断日志文件。
  Future<void> _closeDiagSink() async {
    final sink = _diagSink;
    _diagSink = null;
    if (sink != null) {
      try {
        sink.writeln('========== 会话结束 ==========');
        await sink.flush();
        await sink.close();
      } catch (_) {}
    }
  }

  /// 诊断：播放稳定后读取 mpv 硬解/解码器/渲染状态，确认 VideoToolbox
  /// 硬解是否真正生效（判断卡顿是解码还是音频导致）。
  void _diagnoseHwdec() {
    final player = _player;
    if (player == null) return;
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    unawaited(() async {
      try {
        final hwdecCur =
            await platform.getProperty('hwdec-current');
        final decoder = await platform.getProperty('decoder-desc');
        final videoParams = await platform.getProperty('video-params');
        final fps = await platform.getProperty('estimated-vf-fps');
        final audioParams = await platform.getProperty('audio-params');
        final audioFormat =
            await platform.getProperty('audio-format');
        final demuxCacheTime =
            await platform.getProperty('demuxer-cache-time');
        debugPrint('[player] 诊断 hwdec-current=$hwdecCur decoder=$decoder');
        debugPrint('[player] 诊断 video-params=$videoParams fps=$fps');
        debugPrint('[player] 诊断 audio-params=$audioParams '
            'audio-format=$audioFormat');
        debugPrint('[player] 诊断 demuxer-cache-time=$demuxCacheTime');
        await _diagLog('[hwdec] hwdec-current=$hwdecCur decoder=$decoder');
        await _diagLog('[hwdec] video-params=$videoParams fps=$fps');
        await _diagLog('[hwdec] audio-params=$audioParams audio-format=$audioFormat');
        await _diagLog('[hwdec] demuxer-cache-time=$demuxCacheTime');
      } catch (e) {
        debugPrint('[player] 诊断失败: $e');
      }
    }());
  }

  /// 周期性快照：输出播放中的关键运行时指标，定位卡顿根因。
  ///
  /// 关键指标：
  /// * position/duration — 当前播放位置/总时长
  /// * demuxer-cache-time — demuxer 缓存的可播放时长（秒），低于 cache-pause-wait 会触发暂停
  /// * demuxer-cache-duration — 同上（mpv 不同版本属性名不同）
  /// * demuxer-cache-state — demuxer 缓存详细状态（含 eof/underrun 标志）
  /// * estimated-vf-fps — 视频滤镜输出帧率（接近源帧率=正常，远低于=解码/渲染瓶颈）
  /// * fps — 实际渲染帧率
  /// * avsync — 音视频同步偏差（ms），正值=视频落后音频
  /// * total-avsync-change — 累计 A/V 同步调整量
  /// * hwdec-current — 当前硬解后端（确认 VideoToolbox 生效）
  /// * drop-frame-count — 累计丢帧数（>0 说明解码/渲染跟不上）
  /// * vo-drop-frame-count — 视频输出丢帧数
  /// * cache-speed — demuxer 读取速度（KB/s）
  Future<void> _diagSnapshot(String tag) async {
    final player = _player;
    if (player == null) return;
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    try {
      final props = <String>[
        'demuxer-cache-time',
        'demuxer-cache-duration',
        'demuxer-cache-state',
        'estimated-vf-fps',
        'fps',
        'avsync',
        'total-avsync-change',
        'hwdec-current',
        'drop-frame-count',
        'vo-drop-frame-count',
        'cache-speed',
        'audio-pts',
        'video-pts',
        'paused-for-cache',
        'cache-buffering-state',
        'demuxer-is-seekable',
        'stream-cache-size',
        'video-sync',
        'video-out-params',
        'vf',
        'current-vo',
        'container-fps',
        'estimated-vf-fps',
        'frame-drop-count',
        'decoder-frame-drop-count',
        'mistimed-frame-count',
        'vsync-ratio',
        'display-sync-active',
        'video-time-pos',
        'time-pos',
        'audio-params',
        'current-ao',
      ];
      final results = <String, String?>{};
      for (final p in props) {
        try {
          results[p] = await platform.getProperty(p);
        } catch (_) {
          results[p] = null; // 属性不存在
        }
      }
      final pos = player.state.position;
      final dur = player.state.duration;
      final buf = player.state.buffer;
      await _diagLog('[$tag] pos=${pos.inSeconds}s dur=${dur.inSeconds}s '
          'buf=${buf.inSeconds}s');
      await _diagLog('[$tag] demuxer-cache-time=${results['demuxer-cache-time']} '
          'duration=${results['demuxer-cache-duration']} '
          'paused-for-cache=${results['paused-for-cache']} '
          'cache-buffering=${results['cache-buffering-state']}');
      await _diagLog('[$tag] vf-fps=${results['estimated-vf-fps']} '
          'fps=${results['fps']} '
          'avsync=${results['avsync']} '
          'total-avsync-change=${results['total-avsync-change']}');
      await _diagLog('[$tag] hwdec=${results['hwdec-current']} '
          'drop-frames=${results['drop-frame-count']} '
          'vo-drop-frames=${results['vo-drop-frame-count']} '
          'cache-speed=${results['cache-speed']}');
      await _diagLog('[$tag] vf=${results['vf']} '
          'video-sync=${results['video-sync']} '
          'vo=${results['current-vo']} '
          'ao=${results['current-ao']}');
      await _diagLog('[$tag] demuxer-cache-state=${results['demuxer-cache-state']}');
      await _diagLog('[$tag] audio-pts=${results['audio-pts']} '
          'video-pts=${results['video-pts']}');
      await _diagLog('[$tag] video-sync=${results['video-sync']} '
          'vo=${results['current-vo']} '
          'ao=${results['current-ao']} '
          'container-fps=${results['container-fps']} '
          'display-sync=${results['display-sync-active']}');
      await _diagLog('[$tag] time-pos=${results['time-pos']} '
          'video-time-pos=${results['video-time-pos']} '
          'vsync-ratio=${results['vsync-ratio']} '
          'mistimed-frames=${results['mistimed-frame-count']}');
      await _diagLog('[$tag] frame-drop=${results['frame-drop-count']} '
          'decoder-drop=${results['decoder-frame-drop-count']} '
          'video-out-params=${results['video-out-params']}');
    } catch (e) {
      debugPrint('[player][$tag] 诊断失败: $e');
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
      // 初始误判为音频：补建视频输出（必须带硬解配置，否则默认 hwdec=auto
      // 会覆盖掉 Player 上设置的 videotoolbox，导致 iOS 走软解卡顿）。
      // 软解兜底模式下则用 hwdec=no，避免覆盖软解。
      _videoController = VideoController(
        _player!,
        configuration: VideoControllerConfiguration(
          hwdec: _softDecode ? 'no' : 'videotoolbox-copy',
          vo: 'libmpv',
        ),
      );
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
      final baseUrl = _ref.read(apiBaseUrlProvider);
      final url = _useHls
          ? StreamApi.hlsPlaylistUrl(sourceId, file.path, baseUrl: baseUrl)
          : StreamApi.streamUrl(sourceId, file.path, baseUrl: baseUrl);
      // 恢复进度：优先用 Media.start 让 mpv 打开时直接定位到目标位置
      // （比 open 后再 seek 更可靠：软解 HEVC 大文件 moov 在末尾，
      //  open 后立即 seek 常被 mpv 丢弃，表现为从头播放）。
      final resume = _pendingResume;
      await player.open(
        Media(
          url,
          httpHeaders: {
            if (token != null && token.isNotEmpty)
              'Authorization': 'Bearer $token',
          },
          start: resume,
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
      // 进度恢复已通过 Media.start 在 open 时指定（见上方），
      // 这里无需再 seek。清除 _pendingResume 避免下次 open 重复。
      if (resume != null) {
        _pendingResume = null;
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
            StreamApi.subtitleUrl(
              sourceId,
              subPath,
              baseUrl: _ref.read(apiBaseUrlProvider),
            ),
            title: name,
          ),
        );
      }
    } catch (_) {
      // 字幕探测/加载失败不影响播放
    }
  }
}
