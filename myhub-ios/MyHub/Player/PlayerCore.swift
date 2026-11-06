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
/// - url：本地文件直接给 file://；网络源由 §4.2 数据源层（ResourceLoaderProxy 边下边播）解析提供。
/// - startAt：历史进度恢复位置，引擎在首帧就绪后一次性精准 seek（精准续播见 TODO §4.2）。
struct PlaybackRequest {
    let item: PlayableItem
    /// 本地串流代理被重建后可换新端口重用同一会话（`LocalStreamProxy.revivedURL`），故为 var
    var url: URL
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
    /// 本地串流代理连接被拒后是否已做过「换端口重建重试」（同一会话只重试一次，避免死循环）
    private var didRetryAfterProxyRebuild = false
    private var lastReportAt: TimeInterval = 0
    /// 时间刷新节流：软解引擎（VLC）时间回调可达数十次/秒，限制 UI 时间刷新到约 4 次/秒，避免高频重绘发热
    private var lastTimeRefreshAt: TimeInterval = 0
    /// 状态自愈兜底（TODO 353）：上一次时间回调的播放位置与系统时刻，
    /// 用于判断「播放时间确实在推进」从而纠正卡住的 loading/buffering 状态
    private var lastProgressTime: TimeInterval = 0
    private var lastProgressUptime: TimeInterval = 0
    /// 跳转到「尚未缓冲」的位置时：先停住旧画面并进入缓冲态，待 seek 完成后自动续播。
    /// 置位期间忽略引擎因这次主动暂停而回报的 paused，状态保持 buffering（显示加载动画）
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
    /// 系统自动暂停（退后台、VLCKit 自动暂停、音频中断）不经过 pause()，保持 nil，
    /// 后台保活据此区分「用户不想播」与「系统误暂停」。
    private(set) var pausedAt: Date?

    /// 是否处于 seek 等待（目标位置尚未缓冲到），UI 据此显示加载菊花
    var isSeeking: Bool { seekTarget != nil }

    /// 渲染输出（AVPlayer / VLCMediaPlayer），§4.3 渲染层接管
    var videoOutput: Any? { engine?.videoOutput }

    /// 当前播放请求（字幕/封面等周边模块读取连接与来源信息）
    var request: PlaybackRequest? { pendingRequest }

    /// 引擎内部状态快照（诊断日志用，TODO 380）：如 AVPlayer 等待原因 / VLC 状态
    var engineDiagnostics: String {
        "\(engineKind?.rawValue ?? "nil") \(engine?.diagnosticSnapshot ?? "engine=nil")"
    }

    // MARK: - 打开 / 关闭

    func open(_ request: PlaybackRequest) async {
        var request = request
        if request.decodePreference == nil {
            request.decodePreference = AppSettings.Player.decodePreference
        }
        // 打开上下文（TODO 380）：起播时的完整环境快照，复现「熄屏一段时间后无法播放」时
        // 对照同刻 lifecycle / network-route / stream 日志定位是地址锁定、代理端口还是媒体探测卡住
        AppLogger.shared.log(
            "open file=\(request.item.title) mediaType=\(request.mediaType.rawValue) decode=\(request.decodePreference?.rawValue ?? "nil") startAt=\(request.startAt.map { String(Int($0)) } ?? "nil") url=\(request.url.absoluteString) 锁定=[\(RoutedWebDAVAdapter.lockSnapshot())] 代理=\(LocalStreamProxy.shared.healthSnapshot()) 网络=\(NetworkPathMonitor.shared.snapshot())",
            level: .info, module: "player-audio"
        )
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
        lastProgressTime = 0
        lastProgressUptime = 0
        pendingResumeAfterSeek = false
        seekWaitGeneration += 1
        seekOrigin = 0
        pausedAt = nil
        didRetryAfterProxyRebuild = false
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
        pausedAt = nil
        // 用户主动起播：取消「seek 等待后自动续播」的挂起意图，避免重复起播
        pendingResumeAfterSeek = false
        seekWaitGeneration += 1
        // 播放完成后再次播放：引擎已停在结尾，仅 play() 不会回到开头重启。
        // 先 seek 回 0 重置位置（顺带把「已完成」进度复位为 0 / 未完成，下次从历史记录也从头起播），再播放
        if state == .ended {
            AppLogger.shared.log("播放已结束，从头重新播放", module: "player-audio")
            seek(to: 0)
        }
        engine?.play()
    }

    /// 从历史记录重新进入同一媒体：若已播放结束则自动从头重播；
    /// 播放中 / 暂停中保持原状态，仅由 UI 展开，避免打断正在进行或用户暂停的播放
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
        // seek 等待期间引擎已经被我们停过一次，再 pause() 不会有新的 paused 回调，
        // 这里主动落到暂停态，否则会一直停在 buffering（菊花不消失）
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
        // 目标落在已缓冲区间之外（进度条灰色缓冲段没覆盖到）时，AVPlayer 会把旧位置的画面
        // 继续播到它自己「想停下」为止，然后才暂停并等数据——表现为进度条已经跳了、画面还在
        // 放旧内容，过一会才出菊花。这里主动先暂停并切到缓冲态，让画面切换与进度条同步发生，
        // seek 到达目标后（timeUpdated 解除吸附时）自动续播。
        let buffered = engine.bufferedTime
        let notBuffered = buffered > 0 && target > buffered - 1
        let wasPlaying = state == .playing || state == .buffering
        seekOrigin = currentTime     // 记录跳转起点，判断前跳/后退用的「到达」条件不同
        currentTime = target
        seekTarget = target
        if notBuffered, wasPlaying || pendingResumeAfterSeek {
            enterSeekWait()
        }
        engine.seek(to: target)
        if !notBuffered, pendingResumeAfterSeek {
            // 新目标已在缓冲区内，无需等待：立刻把之前为等待而暂停的播放恢复回去
            leaveSeekWait()
        }
        report(force: true)
    }

    /// 相对跳转（双击快进/快退，步进 AppSettings.Player.seekStepSeconds）
    func seek(by delta: TimeInterval) {
        seek(to: currentTime + delta)
    }

    // MARK: - seek 等待（跳转到未缓冲位置）

    /// 进入 seek 等待：立刻停住旧画面并切换到缓冲态（菊花与进度条同一帧生效），
    /// seek 到达目标或看门狗超时后由 `leaveSeekWait()` 自动续播
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
        // 目标帧已就绪（或已超时放弃等待）：立即按播放态呈现，避免菊花多留一拍；
        // 若随后真的缺数据，引擎会再回报 buffering
        if state == .buffering { state = .playing }
    }

    /// seek 等待超时保护：目标位置长时间不就绪（弱网 / 空响应）时不再干等，
    /// 解除吸附并交给引擎自身的缓冲策略继续，避免菊花无限转
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

    /// 选择字幕轨；nil = 关闭字幕（外挂字幕匹配见 §4.3 SubtitleManager）
    func selectSubtitleTrack(_ id: Int?) {
        engine?.selectSubtitleTrack(id)
        selectedSubtitleTrackID = id
    }

    // MARK: - 引擎生命周期

    private func startEngine(kind: PlayerEngineKind) {
        guard let request = pendingRequest else { return }
        engine?.stop()
        AppLogger.shared.log(
            "startEngine kind=\(kind.rawValue) url=\(request.url.lastPathComponent) ext=\(request.url.pathExtension) mediaType=\(request.mediaType.rawValue)",
            module: "player-audio"
        )

        let engine: PlaybackEngine = kind == .hardware ? AVPlayerEngine() : VLCEngine()
        engine.onEvent = { [weak self] event in self?.handle(event: event, from: kind) }
        self.engine = engine
        self.engineKind = kind
        self.didBecomeReady = false
        // 换引擎（硬解失败回退软解等）：旧的 seek 等待作废，避免新引擎事件被误抑制
        self.pendingResumeAfterSeek = false
        self.seekWaitGeneration += 1

        Task {
            // load 两级面包屑（TODO 380）：外层「开始/返回/抛错 + 耗时」，内层引擎各自明细，
            // 定位熄屏后卡在「媒体探测 / 轨道加载 / 起播」哪一步
            let loadStart = ProcessInfo.processInfo.systemUptime
            AppLogger.shared.log(
                "engine.load 开始 kind=\(kind.rawValue) url=\(request.url.absoluteString)",
                level: .debug, module: "player-audio"
            )
            do {
                try await engine.load(url: request.url, startAt: request.startAt)
                AppLogger.shared.log(
                    "engine.load 返回 kind=\(kind.rawValue) 耗时=\(Int((ProcessInfo.processInfo.systemUptime - loadStart) * 1000))ms",
                    level: .info, module: "player-audio"
                )
                engine.play()
            } catch {
                AppLogger.shared.log(
                    "engine.load 抛错 kind=\(kind.rawValue) 耗时=\(Int((ProcessInfo.processInfo.systemUptime - loadStart) * 1000))ms error=\(error.localizedDescription)",
                    level: .error, module: "player-audio"
                )
                handleFailure(error, from: kind)
            }
        }
    }

    private func handle(event: PlayerEngineEvent, from kind: PlayerEngineKind) {
        // 引擎切换（硬解失败回退软解）或重载后，旧引擎的迟到事件不得污染新会话状态：
        // 旧引擎的 buffering / paused 若晚到一步，会让画面在播却停在菊花或播放键上
        guard kind == engineKind else { return }
        switch event {
        case .stateChanged(let newState):
            if case .failed(let message) = newState {
                handleFailure(PlayerPlaybackError(message), from: kind)
                return
            }
            // seek 等待期间是我们自己让引擎暂停的：这次 paused 不是用户意图，
            // 若放行会把状态从 buffering 改成 paused（菊花消失、进度条回弹到旧位置）
            if newState == .paused, pendingResumeAfterSeek { return }
            if (newState == .ready || newState == .playing), !didBecomeReady {
                didBecomeReady = true
                refreshTracks()
                engine?.setRate(rate)
                engine?.setVideoEnabled(!isAudioOnly)
            }
            if state != newState {
                // 状态迁移面包屑（TODO 380）：loading/buffering 卡住或回跳时定位卡点
                AppLogger.shared.log(
                    "播放状态 \(state.logDescription) -> \(newState.logDescription) kind=\(kind.rawValue) 时间=\(Int(currentTime))s",
                    level: .debug, module: "player-audio"
                )
            }
            state = newState
            if newState == .ended {
                seekTarget = nil
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
            // seek 吸附期间不节流：等待新位置时引擎通常处于暂停态，只会在 seek 完成时回调一次，
            // 若被节流丢掉就只能等 8s 看门狗，表现为「菊花多转几秒」
            let now = ProcessInfo.processInfo.systemUptime
            if seekTarget == nil, now - lastTimeRefreshAt < 0.25 { return }
            lastTimeRefreshAt = now
            // seek 吸附：目标位置尚未缓冲到时引擎回调仍回报旧位置，进度条保持在目标值，
            // 待引擎实际播放到达目标附近（或越过）后解除并跟随真实位置
            if let target = seekTarget {
                // 前跳：越过目标附近即算到达；后退：必须真的落到目标附近才解除吸附
                // （后退时 seek 未完成前引擎仍回调旧的大位置，用 >= 判断会立刻误判为到达）
                let landed = target >= seekOrigin ? current >= target - 0.5 : abs(current - target) <= 0.5
                if landed {
                    seekTarget = nil
                    currentTime = current
                    // seek 已到达目标（引擎在暂停态也会因时间跳变回调）：恢复此前为等待而暂停的播放
                    leaveSeekWait()
                } else {
                    currentTime = target
                }
            } else {
                currentTime = current
            }
            bufferedTime = engine?.bufferedTime ?? 0
            healStateIfActuallyPlaying(now: now)
            report()
        case .tracksChanged:
            refreshTracks()
        }
    }

    /// 状态自愈兜底（TODO 353）：媒体时间在两次回调间只前进了一点点（排除 seek 跳变），
    /// 说明确实在播放；此时若状态仍停在 loading/buffering，就是引擎的状态事件缺失或乱序
    /// （短时长片源在首帧与结尾附近最容易发生），主动纠正为 playing，避免画面在动却一直转菊花。
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

        // 本地串流代理端口已失效（App 挂起后回环监听被系统回收，且被动标记不会翻转）：
        // 硬解与软解都会以 -1004 立即失败，回退软解毫无意义。
        // 此时重建代理、用新端口复用同一会话重试一次（TODO 366）
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
            // 回退面包屑（TODO 380）：同时出现「硬解失败 + 软解失败」才最终失败，缺此条会误判卡点
            AppLogger.shared.log(
                "硬解起播失败，自动回退软解 error=\(error.localizedDescription) 引擎=\(engineDiagnostics)",
                level: .warn, module: "player-audio"
            )
            startEngine(kind: .software)
            return
        }
        // 记录失败时的完整环境快照（TODO 366/380）：配合 network-route / stream / lifecycle 日志定位
        // 「熄屏后无法播放」的根因是网络/路由、串流代理还是媒体本身
        AppLogger.shared.log(
            "播放失败 kind=\(kind.rawValue) error=\(error.localizedDescription) item=\(currentItem?.title ?? "nil") startAt=\(pendingRequest?.startAt.map { String(Int($0)) } ?? "nil") 引擎=\(engineDiagnostics) 锁定=[\(RoutedWebDAVAdapter.lockSnapshot())] 代理=\(LocalStreamProxy.shared.healthSnapshot()) 网络=\(NetworkPathMonitor.shared.snapshot()) state=\(state.logDescription)",
            level: .error, module: "player-audio"
        )
        state = .failed(error.localizedDescription)
    }

    /// 判断错误是否为「本地串流代理回环连接被拒」：目标地址是回环且属于连接失败。
    /// 仅连接被拒（NSURLErrorCannotConnectToHost）才说明端口无人监听；
    /// 其余失败（网络不可达、媒体损坏）不在此列，避免误触发重建重试。
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

        // 记录音轨解析结果与系统音频环境，定位「有画面无声」（TODO 358）
        let session = AVAudioSession.sharedInstance()
        AppLogger.shared.log(
            "refreshTracks kind=\(engineKind?.rawValue ?? "nil") count=\(audioTracks.count) audio=\(audioTracks.map { "\($0.id):\($0.name)" }.joined(separator: ",")) selected=\(selectedAudioTrackID.map(String.init) ?? "nil") audioOnly=\(isAudioOnly) volume=\(String(format: "%.2f", session.outputVolume)) category=\(session.category.rawValue)",
            module: "player-audio"
        )
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
