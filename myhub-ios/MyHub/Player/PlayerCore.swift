import Foundation

/// 播放进度上报（进度持久化 / 「正在阅读」自动刷新由 PlaybackProgressStore 订阅）
struct PlaybackProgressReport {
    let connectionID: Int64?
    let mediaType: MediaType
    let title: String
    let path: String
    let position: TimeInterval
    let duration: TimeInterval
    let finished: Bool
}

/// 打开播放的请求。
/// - url：本地文件直接给 file://；网络源由 §4.2 数据源层（ResourceLoaderProxy 边下边播）解析提供。
/// - startAt：历史进度恢复位置，引擎在首帧就绪后一次性精准 seek（精准续播见 TODO §4.2）。
struct PlaybackRequest {
    let item: PlayableItem
    let url: URL
    let mediaType: MediaType
    var startAt: TimeInterval? = nil
    /// 缺省跟随全局偏好 `AppSettings.Player.decodePreference`
    var decodePreference: DecodePreference? = nil
}

/// 统一播放门面（《需求分析文档》§4.3，参考 nPlayer）。
/// 播放/暂停/seek/倍速/音轨/字幕/进度上报 —— 面向 UI 的统一接口；
/// 内部按格式路由硬解（AVPlayer）/软解（MobileVLCKit）引擎，切换对上层透明。
@MainActor
final class PlayerCore: ObservableObject {
    static let shared = PlayerCore()

    // MARK: - 发布状态（UI 订阅）

    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var engineKind: PlayerEngineKind?
    @Published private(set) var currentItem: PlayableItem?
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var bufferedTime: TimeInterval = 0
    @Published private(set) var rate: Float = 1
    /// 纯音频播放模式（视频可切仅音频，关闭画面解码节电）
    @Published private(set) var isAudioOnly = false
    @Published private(set) var audioTracks: [TrackOption] = []
    @Published private(set) var subtitleTracks: [TrackOption] = []
    @Published private(set) var selectedAudioTrackID: Int?
    @Published private(set) var selectedSubtitleTrackID: Int?
    /// 进行中的 seek 目标（秒）。网络差时 seek 到未缓冲位置引擎会进入缓冲等待，
    /// 期间引擎时间回调仍回报旧位置；UI 进度条吸附在目标值不回跳，待引擎实际到达后解除
    @Published private(set) var seekTarget: TimeInterval?

    /// 进度上报回调：播放中每 5s 节流上报，暂停 / seek / 结束 / 退出强制上报
    var onProgressReport: ((PlaybackProgressReport) -> Void)?

    private var engine: PlaybackEngine?
    private var pendingRequest: PlaybackRequest?
    private var didBecomeReady = false
    private var lastReportAt: TimeInterval = 0
    /// 时间刷新节流：软解引擎（VLC）时间回调可达数十次/秒，限制 UI 时间刷新到约 4 次/秒，避免高频重绘发热
    private var lastTimeRefreshAt: TimeInterval = 0

    private init() {}

    var isPlaying: Bool { state == .playing }

    /// 是否处于 seek 等待（目标位置尚未缓冲到），UI 据此显示加载菊花
    var isSeeking: Bool { seekTarget != nil }

    /// 渲染输出（AVPlayer / VLCMediaPlayer），§4.3 渲染层接管
    var videoOutput: Any? { engine?.videoOutput }

    /// 当前播放请求（字幕/封面等周边模块读取连接与来源信息）
    var request: PlaybackRequest? { pendingRequest }

    // MARK: - 打开 / 关闭

    func open(_ request: PlaybackRequest) async {
        var request = request
        if request.decodePreference == nil {
            request.decodePreference = AppSettings.Player.decodePreference
        }
        teardownSession()
        pendingRequest = request
        currentItem = request.item
        currentTime = request.startAt ?? 0
        duration = 0
        bufferedTime = 0
        isAudioOnly = request.mediaType == .audio
            || (request.mediaType == .video && AppSettings.Player.audioOnlyByDefault)
        rate = Float(min(3.0, max(0.5, AppSettings.Player.defaultSpeed)))
        lastReportAt = 0
        lastTimeRefreshAt = 0
        state = .loading

        let kind = await EngineRouter.resolve(url: request.url, preference: request.decodePreference ?? .auto)
        startEngine(kind: kind)
    }

    /// 直接退出播放（不进入 mini，mini 路由由 PlayerPresenter 管理）
    func close() {
        report(force: true)
        teardownSession()
        pendingRequest = nil
        currentItem = nil
        engineKind = nil
        state = .idle
    }

    // MARK: - 播放控制

    func play() {
        engine?.play()
    }

    func pause() {
        engine?.pause()
        report(force: true)
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func seek(to seconds: TimeInterval) {
        let target = max(0, seconds)
        currentTime = target
        seekTarget = target
        engine?.seek(to: target)
        report(force: true)
    }

    /// 相对跳转（双击快进/快退，步进 AppSettings.Player.seekStepSeconds）
    func seek(by delta: TimeInterval) {
        seek(to: currentTime + delta)
    }

    /// 倍速（0.5x ~ 3.0x）
    func setRate(_ rate: Float) {
        self.rate = min(3.0, max(0.5, rate))
        engine?.setRate(self.rate)
    }

    /// 纯音频播放模式切换（视频可切仅音频）
    func setAudioOnly(_ enabled: Bool) {
        isAudioOnly = enabled
        engine?.setVideoEnabled(!enabled)
    }

    /// 选择音轨
    func selectAudioTrack(_ id: Int) {
        engine?.selectAudioTrack(id)
        selectedAudioTrackID = id
    }

    /// 选择字幕轨；nil = 关闭字幕（外挂字幕匹配见 §4.3 SubtitleManager）
    func selectSubtitleTrack(_ id: Int?) {
        engine?.selectSubtitleTrack(id)
        selectedSubtitleTrackID = id
    }

    // MARK: - 引擎生命周期

    private func startEngine(kind: PlayerEngineKind) {
        guard let request = pendingRequest else { return }
        engine?.stop()

        let engine: PlaybackEngine = kind == .hardware ? AVPlayerEngine() : VLCEngine()
        engine.onEvent = { [weak self] event in self?.handle(event: event, from: kind) }
        self.engine = engine
        self.engineKind = kind
        self.didBecomeReady = false

        Task {
            do {
                try await engine.load(url: request.url, startAt: request.startAt)
                engine.play()
            } catch {
                handleFailure(error, from: kind)
            }
        }
    }

    private func handle(event: PlayerEngineEvent, from kind: PlayerEngineKind) {
        switch event {
        case .stateChanged(let newState):
            if case .failed(let message) = newState {
                handleFailure(PlayerPlaybackError(message), from: kind)
                return
            }
            if (newState == .ready || newState == .playing), !didBecomeReady {
                didBecomeReady = true
                refreshTracks()
                engine?.setRate(rate)
                engine?.setVideoEnabled(!isAudioOnly)
            }
            state = newState
            if newState == .ended {
                seekTarget = nil
                report(finished: true, force: true)
            } else if newState == .paused {
                // 暂停会中断进行中的 seek（引擎在暂停态不会完成跳转），解除吸附并把进度条同步到实际位置
                if seekTarget != nil {
                    seekTarget = nil
                    currentTime = engine?.currentTime ?? currentTime
                }
            }
        case .timeUpdated(let current, let duration):
            if duration > 0 { self.duration = duration }
            // 节流：仅约每 0.25s 刷新一次 currentTime，避免软解引擎高频回调驱动整棵视图树重绘
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastTimeRefreshAt >= 0.25 else { return }
            lastTimeRefreshAt = now
            // seek 吸附：目标位置尚未缓冲到时引擎回调仍回报旧位置，进度条保持在目标值，
            // 待引擎实际播放到达目标附近（或越过）后解除并跟随真实位置
            if let target = seekTarget {
                if current >= target - 0.5 {
                    seekTarget = nil
                    currentTime = current
                } else {
                    currentTime = target
                }
            } else {
                currentTime = current
            }
            bufferedTime = engine?.bufferedTime ?? 0
            report()
        case .tracksChanged:
            refreshTracks()
        }
    }

    /// 失败处理：自动模式下硬解起播失败回退软解（探测容器/编码选择引擎的兜底路径）
    private func handleFailure(_ error: Error, from kind: PlayerEngineKind) {
        let preference = pendingRequest?.decodePreference ?? .auto
        if kind == .hardware, preference == .auto, !didBecomeReady {
            startEngine(kind: .software)
            return
        }
        state = .failed(error.localizedDescription)
    }

    private func refreshTracks() {
        audioTracks = engine?.availableAudioTracks ?? []
        subtitleTracks = engine?.availableSubtitleTracks ?? []
        selectedAudioTrackID = engine?.currentAudioTrackID
        selectedSubtitleTrackID = engine?.currentSubtitleTrackID
    }

    private func teardownSession() {
        // 注销边下边播串流会话：释放 CachedRangeReader 并取消其 in-flight / 预取任务，
        // 避免播放器关闭后后台预取继续占用 NAS 连接，拖垮后续封面抽帧
        if let url = pendingRequest?.url {
            LocalStreamProxy.shared.unregister(url)
        }
        engine?.stop()
        engine = nil
        seekTarget = nil
        audioTracks = []
        subtitleTracks = []
        selectedAudioTrackID = nil
        selectedSubtitleTrackID = nil
        currentTime = 0
        duration = 0
        bufferedTime = 0
    }

    // MARK: - 进度上报

    private func report(finished: Bool = false, force: Bool = false) {
        guard let item = currentItem, let request = pendingRequest else { return }
        let now = Date().timeIntervalSince1970
        guard force || now - lastReportAt >= 5 else { return }
        lastReportAt = now
        onProgressReport?(PlaybackProgressReport(
            connectionID: item.connectionID,
            mediaType: request.mediaType,
            title: item.title,
            path: item.path,
            position: currentTime,
            duration: duration,
            finished: finished
        ))
    }
}
