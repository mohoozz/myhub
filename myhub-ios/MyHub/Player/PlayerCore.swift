import AVFoundation
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
/// - url：本地文件直接给 file://；网络源由数据源层（ResourceLoaderProxy 边下边播）解析提供。
struct PlaybackRequest {
    let item: PlayableItem
    /// 本地串流代理被重建后可换新端口重用同一会话（`LocalStreamProxy.revivedURL`），故为 var
    var url: URL
    let mediaType: MediaType
    var startAt: TimeInterval? = nil
    /// 缺省跟随全局偏好 `AppSettings.Player.decodePreference`
    var decodePreference: DecodePreference? = nil
}

/// 统一播放门面（，参考 nPlayer）。
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
    /// 视频画面尺寸（像素）；.zero = 未知（纯音频 / 未就绪）。
    @Published private(set) var videoSize: CGSize = .zero
    /// 纯音频播放模式（视频可切仅音频，关闭画面解码节电）
    @Published private(set) var isAudioOnly = false
    @Published private(set) var audioTracks: [TrackOption] = []
    @Published private(set) var subtitleTracks: [TrackOption] = []
    @Published private(set) var selectedAudioTrackID: Int?
    @Published private(set) var selectedSubtitleTrackID: Int?
    /// 进行中的 seek 目标（秒）。网络差时 seek 到未缓冲位置引擎会进入缓冲等待
    @Published private(set) var seekTarget: TimeInterval?

    /// 进度上报回调：播放中每 5s 节流上报，暂停 / seek / 结束 / 退出强制上报
    var onProgressReport: ((PlaybackProgressReport) -> Void)?

    private var engine: PlaybackEngine?
    private var pendingRequest: PlaybackRequest?
    private var didBecomeReady = false
    /// 本地串流代理连接被拒后是否已做过「换端口重建重试」（同一会话只重试一次，避免死循环）
    private var didRetryAfterProxyRebuild = false
    /// 会话代次：每次打开 / 关闭自增。异步解析与引擎加载完成后据此判断自己是否已过期
    private var sessionGeneration = 0
    /// 起播超时看门狗：引擎加载迟迟不就绪（媒体探测 / 等待 item 就绪无响应）时按失败处理
    private var loadWatchdog: Task<Void, Never>?
    /// 起播超时（秒）：从 startEngine 到首个 ready / playing 的上限
    private static let startupTimeout: TimeInterval = 30
    private var lastReportAt: TimeInterval = 0
    /// 时间刷新节流：软解引擎（VLC）时间回调可达数十次/秒，限制 UI 时间刷新到约 4 次/秒，避免高频重绘发热
    private var lastTimeRefreshAt: TimeInterval = 0
    /// 状态自愈兜底：上一次时间回调的播放位置与系统时刻
    private var lastProgressTime: TimeInterval = 0
    private var lastProgressUptime: TimeInterval = 0
    /// 跳转到「尚未缓冲」的位置时：先停住旧画面并进入缓冲态，待 seek 完成后自动续播。
    private var pendingResumeAfterSeek = false
    /// seek 等待看门狗代数：每次进入/取消等待自增，超时任务据此判断自己是否已过期
    private var seekWaitGeneration = 0
    /// 本次 seek 的起点位置：前跳用「越过目标」判到达，后退用「落到目标附近」判到达
    private var seekOrigin: TimeInterval = 0
    /// seek 等待超时（秒）：目标位置迟迟不就绪时不再干等，交给引擎自身缓冲策略继续
    private static let seekResumeTimeout: TimeInterval = 8

    private init() {}

    var isPlaying: Bool { state == .playing }

    /// 用户主动暂停时间（UI / 控制中心调用 pause() 时记录）。
    private(set) var pausedAt: Date?

    /// 是否处于 seek 等待（目标位置尚未缓冲到），UI 据此显示加载菊花
    var isSeeking: Bool { seekTarget != nil }

    /// 渲染输出（AVPlayer / VLCMediaPlayer）， 渲染层接管
    var videoOutput: Any? { engine?.videoOutput }

    /// 当前播放请求（字幕/封面等周边模块读取连接与来源信息）
    var request: PlaybackRequest? { pendingRequest }

    /// 引擎内部状态快照（诊断日志用）：如 AVPlayer 等待原因 / VLC 状态
    var engineDiagnostics: String {
        "\(engineKind?.rawValue ?? "nil") \(engine?.diagnosticSnapshot ?? "engine=nil")"
    }

 // MARK: - 打开 / 关闭

    func open(_ request: PlaybackRequest) async {
        var request = request
        if request.decodePreference == nil {
            request.decodePreference = AppSettings.Player.decodePreference
        }
        // 打开上下文：起播时的完整环境快照，复现「熄屏一段时间后无法播放」时
        AppLogger.shared.log(
            "open file=\(request.item.title) mediaType=\(request.mediaType.rawValue) decode=\(request.decodePreference?.rawValue ?? "nil") startAt=\(request.startAt.map { String(Int($0)) } ?? "nil") url=\(request.url.absoluteString) 锁定=[\(RoutedWebDAVAdapter.lockSnapshot())] 代理=\(LocalStreamProxy.shared.healthSnapshot()) 网络=\(NetworkPathMonitor.shared.snapshot())",
            level: .info, module: "player-audio"
        )
        teardownSession()
        let generation = sessionGeneration
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
        lastProgressTime = 0
        lastProgressUptime = 0
        pendingResumeAfterSeek = false
        seekWaitGeneration += 1
        seekOrigin = 0
        pausedAt = nil
        didRetryAfterProxyRebuild = false
        state = .loading

        let kind = await EngineRouter.resolve(url: request.url, preference: request.decodePreference ?? .auto)
        // 解析期间用户又打开了别的媒体或已退出：本次打开作废（不启动引擎，避免两路同时加载）
        guard generation == sessionGeneration else {
            AppLogger.shared.log(
                "open 解析完成但会话已过期（已切换 / 已退出），丢弃本次打开 kind=\(kind.rawValue) file=\(request.item.title)",
                level: .warn, module: "player-audio"
            )
            return
        }
        startEngine(kind: kind)
    }

    /// 直接退出播放（不进入 mini，mini 路由由 PlayerPresenter 管理）
    func close() {
        // 已播完退出时仍按「已完成」上报：否则 100% 的进度会被写成未完成
        let atEnd = state == .ended || (duration > 0 && currentTime >= duration - 0.5)
        report(finished: atEnd, force: true)
        teardownSession()
        pendingRequest = nil
        currentItem = nil
        engineKind = nil
        state = .idle
    }

 // MARK: - 播放控制

    func play() {
        // 用户主动起播：解除该文件的「已删进度」抑制窗口，新会话进度应正常落库
        if let item = currentItem, let connectionID = item.connectionID {
            PlaybackProgressStore.shared.resume(connectionID: connectionID, path: item.path)
        }
        pausedAt = nil
        // 用户主动起播：取消「seek 等待后自动续播」的挂起意图，避免重复起播
        pendingResumeAfterSeek = false
        seekWaitGeneration += 1
        // 播放完成后再次播放：引擎已停在结尾，仅 play() 不会回到开头重启。
        if state == .ended {
            AppLogger.shared.log("播放已结束，从头重新播放", module: "player-audio")
            seek(to: 0)
        }
        engine?.play()
    }

    /// 从历史记录重新进入同一媒体：若已播放结束则自动从头重播
    func replayIfFinished() {
        guard state == .ended else { return }
        play()
    }

    func pause() {
        pausedAt = Date()
        // 用户主动暂停：取消「seek 完成后自动续播」，让引擎回报的 paused 正常生效
        pendingResumeAfterSeek = false
        seekWaitGeneration += 1
        engine?.pause()
        // seek 等待期间引擎已经被我们停过一次，再 pause() 不会有新的 paused 回调
        if state == .buffering || state == .playing { state = .paused }
        if seekTarget != nil {
            // 与引擎回报 paused 的处理保持一致：解除吸附，进度条跟随实际位置
            seekTarget = nil
            currentTime = engine?.currentTime ?? currentTime
        }
        report(force: true)
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func seek(to seconds: TimeInterval) {
        guard let engine else { return }
        let upperBound = duration > 0 ? max(0, duration - 0.2) : seconds
        let target = min(max(0, seconds), upperBound)
        // 拖到片尾（末尾 0.3s 内）单独处理：AVPlayer 对「片尾附近的精准 seek」经常不再回调完成
        let isTailSeek = duration > 0 && target >= duration - 0.3
        // 目标落在已缓冲区间之外（进度条灰色缓冲段没覆盖到）时，AVPlayer 会把旧位置的画面
        let buffered = engine.bufferedTime
        let notBuffered = buffered > 0 && target > buffered - 1
        let wasPlaying = state == .playing || state == .buffering
        seekOrigin = currentTime     // 记录跳转起点，判断前跳/后退用的「到达」条件不同
        currentTime = target
        seekTarget = target
        if !isTailSeek, notBuffered, wasPlaying || pendingResumeAfterSeek {
            enterSeekWait()
        }
        engine.seek(to: target)
        if isTailSeek {
            settleEndedAtTail()
            return
        }
        if !notBuffered, pendingResumeAfterSeek {
            leaveSeekWait()
        }
        report(force: true)
    }

    /// 片尾落定：媒体时间到达片尾时主动切到 ended（不允许停在「播放中」）。
    private func settleEndedAtTail() {
        guard duration > 0, state != .ended, !state.isFailed else { return }
        seekTarget = nil
        pendingResumeAfterSeek = false
        seekWaitGeneration += 1
        loadWatchdog?.cancel()
        // 进度直接落到片尾：进度条 100% 与「已播完」一致
        currentTime = duration
        // 停住引擎：否则它在片尾空转，悬挂的 seek 也不会结束
        engine?.pause()
        AppLogger.shared.log(
            "到达片尾 time=\(String(format: "%.2f", currentTime))s duration=\(String(format: "%.2f", duration))s -> ended",
            level: .info, module: "player-audio"
        )
        state = .ended
        report(finished: true, force: true)
    }

    /// 相对跳转（双击快进/快退，步进 AppSettings.Player.seekStepSeconds）
    func seek(by delta: TimeInterval) {
        seek(to: currentTime + delta)
    }

 // MARK: - seek 等待（跳转到未缓冲位置）

    /// 进入 seek 等待：立刻停住旧画面并切换到缓冲态（菊花与进度条同一帧生效）
    private func enterSeekWait() {
        pendingResumeAfterSeek = true
        engine?.pause()
        if state != .buffering { state = .buffering }
        scheduleSeekResumeWatchdog()
    }

    /// 结束 seek 等待：恢复播放（此前是播放中才会走到这里），并让看门狗失效
    private func leaveSeekWait() {
        guard pendingResumeAfterSeek else { return }
        pendingResumeAfterSeek = false
        seekWaitGeneration += 1
        // 已播完（例如直接拖到片尾）：不续播，否则引擎会按「重播」把位置跳回 0
        guard state != .ended else { return }
        engine?.play()
        // 目标帧已就绪（或已超时放弃等待）：立即按播放态呈现，避免菊花多留一拍
        if state == .buffering { state = .playing }
    }

    /// seek 等待超时保护：目标位置长时间不就绪（弱网 / 空响应）时不再干等
    private func scheduleSeekResumeWatchdog() {
        seekWaitGeneration += 1
        let generation = seekWaitGeneration
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.seekResumeTimeout * 1_000_000_000))
            guard let self, self.pendingResumeAfterSeek, self.seekWaitGeneration == generation else { return }
            AppLogger.shared.log(
                "seek 等待超时（\(Int(Self.seekResumeTimeout))s），解除吸附并恢复播放 target=\(Int(self.seekTarget ?? 0))s 已缓冲=\(Int(self.bufferedTime))s",
                level: .warn, module: "player-audio"
            )
            self.seekTarget = nil
            self.currentTime = self.engine?.currentTime ?? self.currentTime
            self.leaveSeekWait()
        }
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

    /// 选择字幕轨；nil = 关闭字幕（外挂字幕匹配见 SubtitleManager）
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
        // 换引擎（硬解失败回退软解等）：旧的 seek 等待作废，避免新引擎事件被误抑制
        self.pendingResumeAfterSeek = false
        self.seekWaitGeneration += 1

        let generation = sessionGeneration
        scheduleStartupWatchdog(generation: generation, kind: kind)

        Task {
            // load 两级面包屑：外层「开始/返回/抛错 + 耗时」，内层引擎各自明细
            let loadStart = ProcessInfo.processInfo.systemUptime
            do {
                try await engine.load(url: request.url, startAt: request.startAt)
                AppLogger.shared.log(
                    "engine.load 返回 kind=\(kind.rawValue) 耗时=\(Int((ProcessInfo.processInfo.systemUptime - loadStart) * 1000))ms",
                    level: .info, module: "player-audio"
                )
                guard isCurrentSession(generation, engine: engine) else {
                    // 会话已切走（用户打开了别的视频 / 已退出）：本次加载作废并释放引擎
                    AppLogger.shared.log(
                        "engine.load 返回但会话已过期，停止该引擎 kind=\(kind.rawValue)", level: .warn, module: "player-audio"
                    )
                    engine.stop()
                    return
                }
                engine.play()
            } catch {
                AppLogger.shared.log(
                    "engine.load 抛错 kind=\(kind.rawValue) 耗时=\(Int((ProcessInfo.processInfo.systemUptime - loadStart) * 1000))ms error=\(error.localizedDescription)",
                    level: .error, module: "player-audio"
                )
                guard isCurrentSession(generation, engine: engine) else {
                    AppLogger.shared.log(
                        "engine.load 抛错但会话已过期，忽略 kind=\(kind.rawValue)", level: .warn, module: "player-audio"
                    )
                    engine.stop()
                    return
                }
                handleFailure(error, from: kind)
            }
        }
    }

    /// 该引擎/代次是否仍属于当前会话（异步加载返回后必须先校验，避免过期会话污染新播放）
    private func isCurrentSession(_ generation: Int, engine: PlaybackEngine) -> Bool {
        generation == sessionGeneration && self.engine === engine
    }

    /// 起播超时看门狗：引擎加载迟迟不就绪（媒体探测无响应 / 等待 item 就绪卡住）时按失败处理
    private func scheduleStartupWatchdog(generation: Int, kind: PlayerEngineKind) {
        loadWatchdog?.cancel()
        loadWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.startupTimeout * 1_000_000_000))
            guard !Task.isCancelled, let self,
                  self.sessionGeneration == generation,
                  self.engineKind == kind,
                  !self.didBecomeReady,
                  !self.state.isFailed else { return }
            // 数据确实在流入（已缓冲）说明只是慢，不是卡死，交给引擎自己完成
            guard self.bufferedTime < 0.5, self.state != .ended else { return }
            AppLogger.shared.log(
                "起播超时（\(Int(Self.startupTimeout))s）仍未就绪，按失败处理 state=\(self.state.logDescription) 引擎=\(self.engineDiagnostics)",
                level: .error, module: "player-audio"
            )
            self.handleFailure(PlayerPlaybackError("视频加载超时，请重试"), from: kind)
        }
    }

    private func handle(event: PlayerEngineEvent, from kind: PlayerEngineKind) {
        // 引擎切换（硬解失败回退软解）或重载后，旧引擎的迟到事件不得污染新会话状态
        guard kind == engineKind else { return }
        switch event {
        case .stateChanged(let newState):
            if case .failed(let message) = newState {
                handleFailure(PlayerPlaybackError(message), from: kind)
                return
            }
            // 已结束不允许被迟到事件降级：片尾主动 pause 引擎会回报 paused
            if state == .ended, newState == .paused || newState == .ready {
                return
            }
            // seek 等待期间是我们自己让引擎暂停的：这次 paused 不是用户意图
            if newState == .paused, pendingResumeAfterSeek { return }
            if (newState == .ready || newState == .playing), !didBecomeReady {
                didBecomeReady = true
                loadWatchdog?.cancel()
                refreshTracks()
                engine?.setRate(rate)
                engine?.setVideoEnabled(!isAudioOnly)
            }
            if state != newState {
                // 状态迁移面包屑：loading/buffering 卡住或回跳时定位卡点
                AppLogger.shared.log(
                    "播放状态 \(state.logDescription) -> \(newState.logDescription) kind=\(kind.rawValue) 时间=\(Int(currentTime))s",
                    level: .debug, module: "player-audio"
                )
            }
            state = newState
            if newState == .ended {
                seekTarget = nil
                // 进度落到片尾：避免「已播完」时进度条还差最后半秒
                if duration > 0 { currentTime = duration }
                report(finished: true, force: true)
                // 已播完（如拖到片尾）：作废 seek 等待，别让看门狗稍后再把播放拉起来
                pendingResumeAfterSeek = false
                seekWaitGeneration += 1
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
            if seekTarget == nil, now - lastTimeRefreshAt < 0.25 { return }
            lastTimeRefreshAt = now
            // seek 吸附：目标位置尚未缓冲到时引擎回调仍回报旧位置，进度条保持在目标值
            if let target = seekTarget {
                // 前跳：越过目标附近即算到达；后退：必须真的落到目标附近才解除吸附
                let landed = target >= seekOrigin ? current >= target - 0.5 : abs(current - target) <= 0.5
                if landed {
                    seekTarget = nil
                    currentTime = current
                    // seek 已到达目标（引擎在暂停态也会因时间跳变回调）：恢复此前为等待而暂停的播放
                    leaveSeekWait()
                } else {
                    currentTime = target
                }
            } else if state != .ended || current >= currentTime {
                // 片尾落定后位置已按片尾上报，迟到的旧位置回调不得把进度条往回拉
                currentTime = current
            }
            bufferedTime = engine?.bufferedTime ?? 0
            refreshVideoSize()
            healStateIfActuallyPlaying(now: now)
            // 片尾兜底（本次修复）：引擎真实时间已到片尾却既没收到结束通知、时间也不再推进
            if seekTarget == nil, duration > 0, current >= duration - 0.2 {
                settleEndedAtTail()
            }
            report()
        case .tracksChanged:
            refreshTracks()
        }
    }

    /// 状态自愈兜底：媒体时间在两次回调间只前进了一点点（排除 seek 跳变）
    private func healStateIfActuallyPlaying(now: TimeInterval) {
        let previousTime = lastProgressTime
        let previousAt = lastProgressUptime
        lastProgressTime = currentTime
        lastProgressUptime = now
        // seek 吸附期间 currentTime 是目标值而非真实播放位置，不能当作「在播放」的证据
        guard seekTarget == nil else { return }
        // 间隔过长（如长时间暂停后恢复）或时间未推进，都不作为「正在播放」的证据
        guard previousAt > 0, now - previousAt <= 2 else { return }
        // 增量上限排除 seek 跳变；上限按 2.5s 给足，兼容 3 倍速下回调间隔抖动
        let delta = currentTime - previousTime
        guard delta > 0, delta <= 2.5 else { return }
        guard state == .loading || state == .buffering else { return }
        AppLogger.shared.log(
            "时间在推进但状态仍为 \(state.logDescription)，纠正为 playing kind=\(engineKind?.rawValue ?? "nil") time=\(Int(currentTime))s",
            level: .warn, module: "player-audio"
        )
        // 若关键的 ready/playing 事件整条丢失，轨道刷新与倍速/纯音频下发也会被跳过，这里补齐
        if !didBecomeReady {
            didBecomeReady = true
            refreshTracks()
            engine?.setRate(rate)
            engine?.setVideoEnabled(!isAudioOnly)
        }
        state = .playing
    }

    /// 失败处理：自动模式下硬解起播失败回退软解（探测容器/编码选择引擎的兜底路径）
    private func handleFailure(_ error: Error, from kind: PlayerEngineKind) {
        let preference = pendingRequest?.decodePreference ?? .auto

        // 本地串流代理端口已失效（App 挂起后回环监听被系统回收，且被动标记不会翻转）
        if !didRetryAfterProxyRebuild, isLoopbackConnectFailure(error), let request = pendingRequest {
            didRetryAfterProxyRebuild = true
            AppLogger.shared.log(
                "检测到本地串流代理连接被拒（回环监听可能已被系统回收），重建代理换端口重试一次 error=\(error.localizedDescription) kind=\(kind.rawValue) 代理=\(LocalStreamProxy.shared.healthSnapshot())",
                level: .warn, module: "player-audio"
            )
            do {
                let revivedURL = try LocalStreamProxy.shared.revivedURL(for: request.url)
                pendingRequest?.url = revivedURL
                startEngine(kind: kind)
                return
            } catch {
                AppLogger.shared.log(
                    "本地串流代理换端口复用失败 error=\(error.localizedDescription)",
                    level: .error, module: "player-audio"
                )
            }
        }

        if kind == .hardware, preference == .auto, !didBecomeReady {
            // 回退面包屑：同时出现「硬解失败 + 软解失败」才最终失败，缺此条会误判卡点
            AppLogger.shared.log(
                "硬解起播失败，自动回退软解 error=\(error.localizedDescription) 引擎=\(engineDiagnostics)",
                level: .warn, module: "player-audio"
            )
            startEngine(kind: .software)
            return
        }
        // 记录失败时的完整环境快照：配合 network-route / stream / lifecycle 日志定位
        AppLogger.shared.log(
            "播放失败 kind=\(kind.rawValue) error=\(error.localizedDescription) item=\(currentItem?.title ?? "nil") startAt=\(pendingRequest?.startAt.map { String(Int($0)) } ?? "nil") 引擎=\(engineDiagnostics) 锁定=[\(RoutedWebDAVAdapter.lockSnapshot())] 代理=\(LocalStreamProxy.shared.healthSnapshot()) 网络=\(NetworkPathMonitor.shared.snapshot()) state=\(state.logDescription)",
            level: .error, module: "player-audio"
        )
        loadWatchdog?.cancel()
        loadWatchdog = nil
        state = .failed(error.localizedDescription)
    }

    /// 判断错误是否为「本地串流代理回环连接被拒」：目标地址是回环且属于连接失败。
    private func isLoopbackConnectFailure(_ error: Error) -> Bool {
        guard let host = pendingRequest?.url.host,
              host == "127.0.0.1" || host == "localhost" else { return false }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCannotConnectToHost {
            return true
        }
        // 软解（VLC）错误多被包装成字符串，按文案兜底识别
        return nsError.localizedDescription.contains("Could not connect to the server")
    }

    private func refreshTracks() {
        audioTracks = engine?.availableAudioTracks ?? []
        subtitleTracks = engine?.availableSubtitleTracks ?? []
        selectedAudioTrackID = engine?.currentAudioTrackID
        selectedSubtitleTrackID = engine?.currentSubtitleTrackID
        refreshVideoSize()

        // 记录音轨解析结果与系统音频环境，定位「有画面无声」
        let session = AVAudioSession.sharedInstance()
        AppLogger.shared.log(
            "refreshTracks kind=\(engineKind?.rawValue ?? "nil") count=\(audioTracks.count) audio=\(audioTracks.map { "\($0.id):\($0.name)" }.joined(separator: ",")) selected=\(selectedAudioTrackID.map(String.init) ?? "nil") audioOnly=\(isAudioOnly) volume=\(String(format: "%.2f", session.outputVolume)) category=\(session.category.rawValue)",
            module: "player-audio"
        )
    }

    /// 同步视频画面尺寸：软解要等首帧输出后才有尺寸，故在时间回调里持续补齐
    private func refreshVideoSize() {
        guard !isAudioOnly else {
            if videoSize != .zero { videoSize = .zero }
            return
        }
        guard let size = engine?.videoNaturalSize,
              size.width > 1, size.height > 1,
              size.width.isFinite, size.height.isFinite else { return }
        if videoSize != size { videoSize = size }
    }

    private func teardownSession() {
        // 先作废代次：进行中的 open / engine.load 返回后会据此自行停掉引擎并丢弃结果
        sessionGeneration += 1
        loadWatchdog?.cancel()
        loadWatchdog = nil
        // 注销边下边播串流会话：释放 CachedRangeReader 并取消其 in-flight / 预取任务
        if let url = pendingRequest?.url {
            LocalStreamProxy.shared.unregister(url)
        }
        engine?.stop()
        engine = nil
        // 画面输出随会话一起解绑：全屏 / mini 共用同一渲染视图，旧引擎的输出不得残留到新会话
        VideoSurface.shared.unbind()
        seekTarget = nil
        audioTracks = []
        subtitleTracks = []
        selectedAudioTrackID = nil
        selectedSubtitleTrackID = nil
        currentTime = 0
        duration = 0
        bufferedTime = 0
        videoSize = .zero
        lastProgressTime = 0
        lastProgressUptime = 0
        pendingResumeAfterSeek = false
        seekWaitGeneration += 1
        seekOrigin = 0
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
