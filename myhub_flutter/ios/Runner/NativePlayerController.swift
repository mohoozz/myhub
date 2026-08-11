import Foundation
import AVFoundation
import UIKit
import CoreVideo
import MediaPlayer

/// AVPlayer 播放器控制器。
///
/// 用系统 AVPlayer 播放，通过 FlutterTexture（GPU 纹理）渲染到 Flutter。
/// 支持：播放/暂停/seek/音量/倍速、内嵌音轨与字幕轨枚举切换
/// （AVMediaSelectionGroup）、进度/状态事件回传 Flutter。
final class NativePlayerController: NSObject, FlutterTexture {
  private var player: AVPlayer?
  private var playerItem: AVPlayerItem?

  /// 不可见 AVPlayerLayer（iOS 16+ 流式视频需此触发帧输出）。
  private var playerLayer: AVPlayerLayer?

  /// 视频帧输出（Texture 渲染用）。
  private var videoOutput: AVPlayerItemVideoOutput?
  /// CADisplayLink 驱动帧拉取。
  private var displayLink: CADisplayLink?

  /// 当前绑定的事件回传（Flutter EventSink）。
  private var eventSink: FlutterEventSink?

  /// Flutter texture registry 与 id。
  private var textureRegistry: FlutterTextureRegistry?
  /// 注册的 texture id（0 = 未注册），供 Flutter 侧获取渲染。
  var textureId: Int64 = 0

  /// 最新的视频像素缓冲（供 Flutter 拉取）。
  private var currentPixelBuffer: CVPixelBuffer?
  private let pixelBufferLock = NSLock()

  /// 音轨分组（内嵌多音轨切换）。
  private var audioSelectionGroup: AVMediaSelectionGroup?
  /// 字幕分组（内嵌字幕轨切换）。
  private var subtitleSelectionGroup: AVMediaSelectionGroup?

  private var timeObserverToken: Any?
  private var rateObserverToken: NSKeyValueObservation?
  private var statusObserverToken: NSKeyValueObservation?
  private var itemEndObserver: NSObjectProtocol?
  /// 音频会话中断监听（来电/闹钟/其他 App 抢占）。
  private var audioInterruptionObserver: NSObjectProtocol?
  /// App 进入后台监听（视频后台播放：摘除 AVPlayerLayer 退化为纯音频）。
  private var backgroundObserver: NSObjectProtocol?
  /// App 回到前台监听（重新挂回 AVPlayerLayer 恢复视频渲染）。
  private var foregroundObserver: NSObjectProtocol?
  /// 当前媒体标题（锁屏/控制中心展示用）。
  private var mediaTitle: String = ""
  /// 当前媒体总时长（秒），用于锁屏进度展示。
  private var mediaDuration: Double = 0

  private var isPlaying = false
  private var volume: Float = 1.0
  private var speed: Float = 1.0

  /// 是否已播放到末尾。
  ///
  /// AVPlayer 播放完成后 currentTime 停在末尾，直接 play() 不会重播；
  /// 需先 seek 回起点。播放完成通知置位，play() 时消费并从头重播。
  private var didReachEnd = false

  /// 是否已注册远程控制命令（锁屏/控制中心），仅一次。
  private var remoteCommandsRegistered = false

  /// 帧日志计数（节流打印用）。
  private var frameLogCount = 0

  // MARK: - Lifecycle

  init(eventSink: FlutterEventSink?, textureRegistry: FlutterTextureRegistry?) {
    super.init()
    self.eventSink = eventSink
    self.textureRegistry = textureRegistry
  }

  // MARK: - Texture

  /// FlutterTexture 协议：向 Flutter 提供最新视频帧。
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    pixelBufferLock.lock()
    defer { pixelBufferLock.unlock() }
    guard let buf = currentPixelBuffer else { return nil }
    return Unmanaged.passRetained(buf)
  }

  /// 刷新为最新有效的 texture registry（引擎渲染上下文就绪后）。
  func refreshTextureRegistry(_ registry: FlutterTextureRegistry) {
    if textureRegistry !== registry {
      textureRegistry = registry
      // 若已持有旧注册但 id 无效（=0），用新 registry 重新注册
      if textureId == 0 {
        let newId = registry.register(self)
        if newId > 0 {
          textureId = newId
          print("Myhub NativePlayer: 刷新后 texture 注册 id=\(newId)")
          startDisplayLink()
        }
      }
    }
  }

  /// 启动 CADisplayLink 定期拉帧（确保只有一次）。
  private func startDisplayLink() {
    if displayLink != nil { return }
    let link = CADisplayLink(target: self, selector: #selector(renderFrame))
    link.add(to: .main, forMode: .common)
    displayLink = link
    print("Myhub NativePlayer: CADisplayLink 已启动")
  }

  /// 注册 texture 并启动帧拉取。若 registry 尚未就绪（register 返回 0），
  /// 延迟重试直到成功。无论注册路径如何，最终都启动 CADisplayLink 拉帧。
  private func setupTexture() {
    guard let registry = textureRegistry else {
      print("Myhub NativePlayer: textureRegistry 为 nil，无法注册 texture")
      return
    }
    // 始终启动 CADisplayLink（帧拉取依赖它，不依赖注册是否立即成功）
    startDisplayLink()
    if textureId != 0 { return }
    let newId = registry.register(self)
    print("Myhub NativePlayer: texture 注册 id=\(newId)")
    if newId > 0 {
      textureId = newId
    } else {
      // registry 未就绪：延迟重试，成功后设置 textureId
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        guard let self, let reg = self.textureRegistry, self.textureId == 0 else { return }
        let retry = reg.register(self)
        if retry > 0 {
          self.textureId = retry
          print("Myhub NativePlayer: 重试后 texture 注册 id=\(retry)")
        } else {
          print("Myhub NativePlayer: 重试后 texture 注册仍失败 id=\(retry)")
        }
      }
    }
  }

  /// 每帧回调：从 videoOutput 拉取当前帧并通知 Flutter 更新。
  @objc private func renderFrame() {
    guard let output = videoOutput, let player = player else { return }
    let time = player.currentTime()
    if frameLogCount <= 3 {
      frameLogCount += 1
      let hasNew = output.hasNewPixelBuffer(forItemTime: time)
      print("Myhub NativePlayer: renderFrame count=" + String(frameLogCount)
          + " time=" + String(format: "%.2f", time.seconds)
          + " hasNew=" + String(hasNew))
    }
    guard output.hasNewPixelBuffer(forItemTime: time) else { return }
    if let buf = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
      pixelBufferLock.lock()
      currentPixelBuffer = buf
      pixelBufferLock.unlock()
      if textureId != 0 {
        textureRegistry?.textureFrameAvailable(textureId)
      }
    }
  }

  private func teardownTexture() {
    displayLink?.invalidate()
    displayLink = nil
    videoOutput = nil
    if textureId != 0 {
      textureRegistry?.unregisterTexture(textureId)
      textureId = 0
    }
    pixelBufferLock.lock()
    currentPixelBuffer = nil
    pixelBufferLock.unlock()
  }

  // MARK: - Event sink

  func attach(eventSink: FlutterEventSink?) {
    self.eventSink = eventSink
  }

  func detachEventSink() {
    eventSink = nil
  }

  // MARK: - Open

  func open(url: URL, title: String, headers: [String: String], isAudio: Bool = false) {
    print("Myhub NativePlayer: open url=\(url.absoluteString) isAudio=\(isAudio)")
    mediaTitle = title
    // 新会话：重置播放完成标记（新媒体从头播放）
    didReachEnd = false
    // 关闭旧的 item 与纹理
    removeObservers()
    teardownTexture()
    playerItem?.cancelPendingSeeks()
    playerItem = nil

    // 带鉴权头的 AVURLAsset
    let asset = AVURLAsset(
      url: url,
      options: headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers])

    // 音频文件：仅播放音频，不创建任何视频输出/纹理/AVPlayerLayer/CADisplayLink，
    // 避免在 Flutter 端显示一个空的（默认占位）"视频画面"圆圈，也避免
    // AVPlayer 把音频内嵌的封面图（cover art）当视频帧输出。
    // 进度/状态事件仍正常回传 Flutter。
    if isAudio {
      let item = AVPlayerItem(asset: asset)
      playerItem = item
      let p: AVPlayer
      if let existing = player {
        p = existing
        p.replaceCurrentItem(with: item)
      } else {
        p = AVPlayer(playerItem: item)
        player = p
        p.volume = volume
      }
      p.rate = speed
      isPlaying = true
      // 关键：音频模式不调用 setupTexture()，textureId 保持为 0，
      // Flutter 侧 Texture 不会被渲染（显示黑底或 AudioCoverMode 唱片封面）。
      addObservers()
      addSystemObservers()
      registerRemoteControls()
      configureAudioSessionForPlayback()
      emitStatus(["state": "loading"])
      print("Myhub NativePlayer: 音频模式，跳过视频纹理/CADisplayLink")
      return
    }

    // 视频帧输出（Texture 渲染数据源）——必须在 item 创建后立即同步附加。
    // 使用 YUV（420YpCbCr8BiPlanar）格式：硬件解码器原生输出，无需转换，
    // 确保 hasNewPixelBuffer 能正确返回 true（BGRA 在某些情况下不输出）。
    let output = AVPlayerItemVideoOutput(
      pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String:
          NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
      ])
    videoOutput = output

    let item = AVPlayerItem(asset: asset)
    // 立即附加 videoOutput（不等异步加载，确保播放即有帧输出）
    item.add(output)
    print("Myhub NativePlayer: videoOutput 已立即附加到 item")
    playerItem = item

    let p: AVPlayer
    if let existing = player {
      p = existing
      p.replaceCurrentItem(with: item)
    } else {
      p = AVPlayer(playerItem: item)
      player = p
      p.volume = volume
    }
    p.rate = speed
    isPlaying = true

    // 关键修复：iOS 16+ 流式视频的 AVPlayerItemVideoOutput 需要 AVPlayerLayer
    // 来触发帧输出（参考 Flutter video_player 的做法）。创建一个 1x1 不可见
    // AVPlayerLayer 添加到根视图，解锁视频帧输出，使 hasNewPixelBuffer 返回 true。
    if playerLayer == nil {
      let layer = AVPlayerLayer(player: p)
      layer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
      layer.isHidden = true
      playerLayer = layer
      attachPlayerLayer()
    }

    setupTexture()
    addObservers()
    addSystemObservers()
    registerRemoteControls()
    configureAudioSessionForPlayback()
    emitStatus(["state": "loading"])
  }

  /// 将不可见 AVPlayerLayer 附加到根视图层。
  ///
  /// 后台播放关键：进入后台时会摘除 layer（让 AVPlayer 退化为纯音频后台播放，
  /// 否则 iOS 视其为"视频播放"而强制暂停），回到前台后通过此方法重新挂回，
  /// 恢复 iOS 16+ 流式视频的帧输出。
  private func attachPlayerLayer() {
    guard let layer = playerLayer else { return }
    if layer.superlayer != nil { return }
    // 使用 iOS 13+ 推荐的 API 获取根视图（keyWindow 已废弃）
    var rootLayer: CALayer?
    for scene in UIApplication.shared.connectedScenes {
      if let windowScene = scene as? UIWindowScene,
         let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first,
         let rl = window.rootViewController?.view.layer {
        rootLayer = rl
        break
      }
    }
    if let rootLayer = rootLayer {
      rootLayer.addSublayer(layer)
      print("Myhub NativePlayer: AVPlayerLayer 已附加（不可见，用于解锁帧输出）")
    } else {
      print("Myhub NativePlayer: 无法获取根视图，AVPlayerLayer 未附加")
    }
  }

  // MARK: - Playback controls

  func play() {
    // 播放完成后 AVPlayer 停在末尾，play() 不生效，需先 seek 回起点。
    // seek 是异步的，在 completionHandler 中再真正播放并上报状态，
    // 避免 seek 完成前 emitStatus 附带末尾 position 导致进度条闪烁。
    if didReachEnd {
      didReachEnd = false
      player?.seek(to: .zero, completionHandler: { [weak self] _ in
        guard let self else { return }
        self.player?.play()
        self.isPlaying = true
        self.emitStatus(["state": "playing"])
        self.updateNowPlaying()
      })
      return
    }
    player?.play()
    isPlaying = true
    emitStatus(["state": isPlaying ? "playing" : "paused"])
    updateNowPlaying()
  }

  func pause() {
    player?.pause()
    isPlaying = false
    emitStatus(["state": "paused"])
    updateNowPlaying()
  }

  func seek(toMs ms: Int64) {
    // 用户主动 seek 退出"已播完"状态：后续 play() 直接续播
    didReachEnd = false
    let target = CMTime(value: ms, timescale: 1000)
    player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    updateNowPlaying()
  }

  /// 系统音量滑条（MPVolumeView，隐藏实例，控制系统音量且不弹 HUD）。
  private var volumeView: MPVolumeView?
  /// 当前系统音量（0-1），用于去重。
  private var lastSystemVolume: Float = -1
  /// 系统亮度监听器。
  private var systemBrightness: CGFloat = UIScreen.main.brightness
  private var brightnessObserver: NSObjectProtocol?

  /// 设置音量（双向同步系统音量，且不弹系统 HUD）。
  ///
  /// 关键：用 MPVolumeView 控制系统音量时，系统会弹出音量 HUD。
  /// 要「改变系统音量」又「不弹 HUD」，必须：
  ///   1. MPVolumeView 添加到 window（让系统认为音量由 MPVolumeView 接管）
  ///   2. 先 addSubview 再隐藏（提前 isHidden 会导致不接管音量显示）
  ///   3. frame 放在屏幕外 + alpha 极小，使 MPVolumeView 自身不可见
  ///
  /// 这样与 NPlayer 行为一致：调节改变系统音量，但不弹系统音量条。
  func setVolume(_ v: Double) {
    let clamped = min(1.0, max(0.0, v))
    volume = Float(clamped)
    player?.volume = 1.0 // AVPlayer 全量，跟随系统音量
    setSystemVolume(clamped)
  }

  /// 通过 MPVolumeView 控制系统音量（不弹 HUD）。
  private func setSystemVolume(_ value: Double) {
    if volumeView == nil {
      // 屏幕外位置 + 极小 alpha；先 addSubview 再隐藏由内部处理
      let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
      view.showsRouteButton = false
      view.alpha = 0.01
      volumeView = view
      // 必须添加到 window（不能是 rootViewController.view），系统才接管音量显示
      if let window = UIApplication.shared.windows.first {
        window.addSubview(view)
      }
    }
    guard let slider = volumeView?.subviews.compactMap({ $0 as? UISlider }).first else {
      return
    }
    slider.value = Float(value)
  }

  func setSpeed(_ s: Double) {
    speed = Float(s)
    player?.rate = speed
    isPlaying = true
    updateNowPlaying()
  }

  /// 设置亮度（同步系统亮度）。
  func setBrightness(_ b: Double) {
    let clamped = min(1.0, max(0.0, b))
    systemBrightness = CGFloat(clamped)
    UIScreen.main.brightness = CGFloat(clamped)
  }

  /// 读取当前系统亮度（0-1）。
  func currentBrightness() -> Double {
    return Double(UIScreen.main.brightness)
  }

  /// 读取当前系统音量和亮度，供进入播放器时与系统值保持一致。
  /// 音量 0-1（Dart 侧转 0-100），亮度 0-1。
  func systemStatus() -> [String: Any] {
    return [
      "volume": AVAudioSession.sharedInstance().outputVolume,
      "brightness": Double(UIScreen.main.brightness),
    ]
  }

  // MARK: - Tracks

  /// 返回音轨/字幕轨清单（供 Flutter 枚举与切换）。
  func tracks() -> [String: Any] {
    guard let item = playerItem else { return [:] }
    let audio = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible)
    let subtitle = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible)

    audioSelectionGroup = audio
    subtitleSelectionGroup = subtitle

    var audioTracks: [[String: Any]] = []
    var subtitleTracks: [[String: Any]] = []

    let currentAudio: AVMediaSelectionOption?
    if let g = audioSelectionGroup {
      currentAudio = item.selectedMediaOption(in: g)
    } else {
      currentAudio = nil
    }
    let currentSub: AVMediaSelectionOption?
    if let g = subtitleSelectionGroup {
      currentSub = item.selectedMediaOption(in: g)
    } else {
      currentSub = nil
    }

    for (i, opt) in (audio?.options ?? []).enumerated() {
      audioTracks.append([
        "index": i,
        "title": optionTitle(opt),
        "language": mediaLanguage(opt),
        "selected": opt === currentAudio,
      ])
    }
    for (i, opt) in (subtitle?.options ?? []).enumerated() {
      subtitleTracks.append([
        "index": i,
        "title": optionTitle(opt),
        "language": mediaLanguage(opt),
        "selected": opt === currentSub,
      ])
    }
    return ["audio": audioTracks, "subtitle": subtitleTracks]
  }

  private func mediaLanguage(_ opt: AVMediaSelectionOption) -> String {
    if let tag = opt.extendedLanguageTag { return tag }
    if let loc = opt.locale { return loc.languageCode ?? "" }
    return ""
  }

  func selectAudioTrack(_ index: Int) {
    guard let group = audioSelectionGroup, let item = playerItem else { return }
    let options = group.options
    if index >= 0 && index < options.count {
      item.select(options[index], in: group)
    }
  }

  func selectSubtitleTrack(_ index: Int) {
    guard let group = subtitleSelectionGroup, let item = playerItem else { return }
    let options = group.options
    if index >= 0 && index < options.count {
      item.select(options[index], in: group)
    } else {
      // -1 或越界：关闭字幕
      item.select(nil, in: group)
    }
  }

  private func optionTitle(_ opt: AVMediaSelectionOption) -> String {
    return opt.displayName
  }

  // MARK: - Observers

  private func addObservers() {
    guard let player, let item = playerItem else { return }

    // 播放位置周期上报（每 500ms）
    timeObserverToken = player.addPeriodicTimeObserver(
      forInterval: CMTime(value: 500, timescale: 1000), queue: .main
    ) { [weak self] time in
      guard let self, let item = self.playerItem else { return }
      let dur = item.duration
      let durMs = dur.seconds.isFinite ? Int64(dur.seconds * 1000) : 0
      let posMs = Int64(time.seconds * 1000)
      let percent = durMs > 0 ? min(100.0, Double(posMs) / Double(durMs) * 100) : 0
      self.emitStatus([
        "positionMs": posMs,
        "durationMs": durMs,
        "percent": percent,
        "state": self.isPlaying ? "playing" : "paused",
      ])
      // 后台播放：同步锁屏/控制中心进度条
      if durMs > 0 {
        self.mediaDuration = Double(durMs) / 1000.0
        self.updateNowPlaying()
      }
    }

    // 播放/暂停状态
    rateObserverToken = player.observe(\.rate, options: [.new]) { [weak self] p, _ in
      self?.isPlaying = p.rate != 0
      self?.emitStatus(["state": self?.isPlaying == true ? "playing" : "paused"])
    }

    // 播放结束
    itemEndObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
    ) { [weak self] _ in
      // 记录播放完成：再次 play() 时先 seek 回起点重播
      self?.didReachEnd = true
      self?.isPlaying = false
      self?.emitStatus(["state": "completed"])
    }

    // item 状态（可播放/失败）
    statusObserverToken = item.observe(\.status, options: [.new]) { [weak self] it, _ in
      print("Myhub NativePlayer: item status = \(it.status.rawValue)")
      switch it.status {
      case .readyToPlay:
        print("Myhub NativePlayer: readyToPlay, 视频可播放")
        // play() 可能在 item ready 之前被调用而不生效，这里确保真正播放
        if self?.isPlaying == true {
          self?.player?.play()
        }
        self?.mediaDuration = it.duration.seconds.isFinite ? it.duration.seconds : 0
        self?.updateNowPlaying()
        self?.emitStatus(["state": "ready"])
      case .failed:
        let msg = it.error?.localizedDescription ?? "播放失败"
        print("Myhub NativePlayer: 播放失败 - \(msg)")
        self?.emitStatus(["error": msg])
      default:
        break
      }
    }
  }

  private func removeObservers() {
    if let token = timeObserverToken {
      player?.removeTimeObserver(token)
      timeObserverToken = nil
    }
    rateObserverToken?.invalidate()
    rateObserverToken = nil
    statusObserverToken?.invalidate()
    statusObserverToken = nil
    if let itemEndObserver {
      NotificationCenter.default.removeObserver(itemEndObserver)
      self.itemEndObserver = nil
    }
    removeSystemObservers()
  }

  // MARK: - 系统音量/亮度双向同步

  /// 系统音量监听器（KVO）。
  private var systemVolumeObserver: NSKeyValueObservation?

  /// 添加系统音量/亮度监听，实现「播放器 ↔ 系统」双向同步。
  private func addSystemObservers() {
    // 系统音量变化（物理键、控制中心、MPVolumeView 调节等）
    let session = AVAudioSession.sharedInstance()
    systemVolumeObserver = session.observe(\.outputVolume, options: [.new, .initial]) {
      [weak self] session, _ in
      let v = session.outputVolume
      // 去重：仅当音量变化时回传
      if self?.lastSystemVolume != v {
        self?.lastSystemVolume = v
        self?.emitStatus(["systemVolume": Double(v), "volume": Double(v)])
      }
    }

    // 系统亮度变化（控制中心、设置等）
    brightnessObserver = NotificationCenter.default.addObserver(
      forName: UIScreen.brightnessDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      let b = UIScreen.main.brightness
      self?.emitStatus(["systemBrightness": Double(b), "brightness": Double(b)])
    }
    // 初始上报当前亮度
    emitStatus(["systemBrightness": Double(UIScreen.main.brightness),
                "brightness": Double(UIScreen.main.brightness)])

    // 音频会话中断监听：来电/闹钟/其他 App 抢占音频。
    // 中断结束后必须重新激活 AVAudioSession，否则后台播放会停止出声。
    audioInterruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let self,
            let info = notification.userInfo,
            let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw) else {
        return
      }
      switch type {
      case .began:
        // 中断开始：暂停播放（后台场景必须释放音频焦点）
        self.player?.pause()
        self.isPlaying = false
        self.emitStatus(["state": "paused"])
        self.updateNowPlaying()
      case .ended:
        // 中断结束：若系统建议恢复则重新激活会话并继续播放
        if let opt = info[AVAudioSessionInterruptionOptionKey] as? UInt,
           AVAudioSession.InterruptionOptions(rawValue: opt).contains(.shouldResume) {
          try? AVAudioSession.sharedInstance().setActive(true, options: [])
          // 统一走 play()：中断期间若已播完，恢复时从头重播
          self.play()
        }
      @unknown default:
        break
      }
    }

    // App 前后台监听：视频后台播放支持。
    // 后台播放视频时，AVPlayerLayer 若仍挂在视图层级中，系统会将其识别为
    // "视频播放" 并在进入后台时强制暂停。进入后台先摘除 layer，
    // 让 AVPlayer 退化为纯音频后台播放（配合 Info.plist UIBackgroundModes=audio）；
    // 回到前台重新挂回 layer，恢复视频帧输出与渲染。
    // 音频模式无 playerLayer，此逻辑自动跳过。
    backgroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      let hadLayer = self.playerLayer?.superlayer != nil
      if hadLayer {
        self.playerLayer?.removeFromSuperlayer()
        print("Myhub NativePlayer: 进入后台，摘除 AVPlayerLayer（后台纯音频播放）")
        // 摘除 layer 前后系统可能已暂停播放（rate=0）；在播状态下恢复，
        // 保证切后台不中断。
        if self.player?.rate == 0 {
          self.player?.play()
          print("Myhub NativePlayer: 后台恢复播放")
        }
      }
    }
    foregroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      if self.playerLayer != nil {
        self.attachPlayerLayer()
        print("Myhub NativePlayer: 回到前台，重新附加 AVPlayerLayer")
      }
    }
  }

  private func removeSystemObservers() {
    systemVolumeObserver?.invalidate()
    systemVolumeObserver = nil
    if let brightnessObserver {
      NotificationCenter.default.removeObserver(brightnessObserver)
      self.brightnessObserver = nil
    }
    if let audioInterruptionObserver {
      NotificationCenter.default.removeObserver(audioInterruptionObserver)
      self.audioInterruptionObserver = nil
    }
    if let backgroundObserver {
      NotificationCenter.default.removeObserver(backgroundObserver)
      self.backgroundObserver = nil
    }
    if let foregroundObserver {
      NotificationCenter.default.removeObserver(foregroundObserver)
      self.foregroundObserver = nil
    }
    lastSystemVolume = -1
  }

  // MARK: - 后台播放（Now Playing + 远程控制）

  /// 激活后台播放音频会话，并启用远程控制事件接收。
  /// 后台播放必需条件：Info.plist 声明 UIBackgroundModes=audio，
  /// 否则 App 进入后台后系统会暂停播放。
  private func configureAudioSessionForPlayback() {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, options: [])
      try session.setActive(true)
    } catch {
      NSLog("Myhub NativePlayer: 激活播放音频会话失败: \(error)")
    }
    // 启用锁屏/控制中心远程控制事件接收
    UIApplication.shared.beginReceivingRemoteControlEvents()
  }

  /// 注册锁屏/控制中心的远程控制命令（仅一次）。
  /// 必须注册播放/暂停/进度命令，否则控制中心和锁屏无法控制播放。
  private func registerRemoteControls() {
    guard !remoteCommandsRegistered else { return }
    remoteCommandsRegistered = true

    let center = MPRemoteCommandCenter.shared()
    // 播放（统一走 play()：播放完成后会先 seek 回起点重播）
    center.playCommand.addTarget { [weak self] _ in
      self?.play()
      return .success
    }
    // 暂停
    center.pauseCommand.addTarget { [weak self] _ in
      self?.player?.pause()
      self?.isPlaying = false
      self?.emitStatus(["state": "paused"])
      self?.updateNowPlaying()
      return .success
    }
    // 播放/暂停切换（非播放态统一走 play()，处理播完重播）
    center.togglePlayPauseCommand.addTarget { [weak self] _ in
      guard let self else { return .commandFailed }
      if self.isPlaying {
        self.player?.pause()
        self.isPlaying = false
        self.emitStatus(["state": "paused"])
      } else {
        self.play()
      }
      self.updateNowPlaying()
      return .success
    }
    // 进度 seek（锁屏/控制中心进度条拖动）
    center.changePlaybackPositionCommand.isEnabled = true
    center.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let self,
            let posEvent = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      self.player?.seek(
        to: CMTime(seconds: posEvent.positionTime, preferredTimescale: 600),
        toleranceBefore: .zero, toleranceAfter: .zero)
      self.updateNowPlaying()
      return .success
    }
    // 禁用默认的上一首/下一首（单媒体会话无列表）
    center.nextTrackCommand.isEnabled = false
    center.previousTrackCommand.isEnabled = false
  }

  /// 更新锁屏/控制中心 Now Playing 元数据（标题、时长、进度、播放速率）。
  /// 后台播放时展示在锁屏和控制中心。
  private func updateNowPlaying() {
    guard let player else { return }
    let duration = playerItem?.duration.seconds ?? 0
    let position = player.currentTime().seconds
    mediaDuration = duration.isFinite && duration > 0 ? duration : mediaDuration
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: mediaTitle,
      MPMediaItemPropertyPlaybackDuration: mediaDuration,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: position.isFinite ? position : 0,
      MPNowPlayingInfoPropertyPlaybackRate: player.rate,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
    ]
    // 时长已知时展示进度条
    if mediaDuration > 0 {
      info[MPMediaItemPropertyPlaybackDuration] = mediaDuration
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  // MARK: - Emit

  private func emitStatus(_ payload: [String: Any]) {
    // 自动附带当前播放位置，避免 state 事件缺失 positionMs 导致
    // Dart 侧把进度重置为 0（进度条回开头）。
    var merged = payload
    if merged["positionMs"] == nil {
      let pos = player?.currentTime().seconds ?? 0
      merged["positionMs"] = pos.isFinite ? Int64(pos * 1000) : 0
    }
    if merged["durationMs"] == nil {
      let dur = playerItem?.duration.seconds ?? 0
      merged["durationMs"] = dur.isFinite ? Int64(dur * 1000) : 0
    }
    eventSink?(merged)
  }

  func dispose() {
    removeObservers()
    teardownTexture()
    playerLayer?.removeFromSuperlayer()
    playerLayer = nil
    volumeView?.removeFromSuperview()
    volumeView = nil
    player?.pause()
    player = nil
    playerItem = nil
    eventSink = nil
    // 清理锁屏/控制中心信息与远程控制
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    UIApplication.shared.endReceivingRemoteControlEvents()
    remoteCommandsRegistered = false
  }
}
