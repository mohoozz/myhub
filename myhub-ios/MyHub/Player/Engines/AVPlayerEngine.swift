import AVFoundation
import CoreMedia

/// 硬解引擎：AVPlayer / VideoToolbox。
/// 处理 H.264/HEVC 等主流格式；`allowsExternalPlayback` 支持 AirPlay；
/// 暴露 `AVPlayer` 供 §4.3 渲染层（AVPlayerLayer / AVPlayerViewController）启用 PiP。
@MainActor
final class AVPlayerEngine: PlaybackEngine {
    let kind: PlayerEngineKind = .hardware
    var onEvent: ((PlayerEngineEvent) -> Void)?

    private(set) var player: AVPlayer?
    private var playerItem: AVPlayerItem?

    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    /// 等待播放日志节流（TODO 380）：弱网下 waiting KVO 可能高频触发，至少间隔 2s 记一条
    private var lastWaitingLogAt: TimeInterval = 0
    /// 本次 load 起始时刻（诊断日志用，TODO 380）
    private var loadStartedAt: TimeInterval = 0
    /// 最近一次上报给上层的状态：用于兜底纠正「时间在走却仍标记 loading/buffering」（TODO 353）
    private var lastReportedState: PlaybackState = .idle
    /// 上一次时间回调的媒体时间：判断媒体时间是否真的在推进（排除 seek 跳变）
    private var lastReportedTime: TimeInterval = 0
    /// 已收到「播放到结尾」通知：结尾处补发的 buffering / paused 事件不得再覆盖 ended
    private var didReachEnd = false

    private var desiredRate: Float = 1
    private var pendingStartAt: TimeInterval?
    private var didApplyStartAt = false

    private var audibleGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?

    var videoOutput: Any? { player }

    var duration: TimeInterval {
        guard let d = playerItem?.duration, d.isNumeric, d.seconds.isFinite else { return 0 }
        return max(0, d.seconds)
    }

    var currentTime: TimeInterval {
        guard let t = player?.currentTime(), t.isNumeric, t.seconds.isFinite else { return 0 }
        return max(0, t.seconds)
    }

    var bufferedTime: TimeInterval {
        guard let ranges = playerItem?.loadedTimeRanges else { return 0 }
        let ends = ranges.map { $0.timeRangeValue.end.seconds }.filter { $0.isFinite }
        return max(0, ends.max() ?? 0)
    }

    /// 硬解仅隐藏画面（AVPlayer 无便捷途径关闭视频解码；音频文件本就无视频轨）
    func setVideoEnabled(_ enabled: Bool) {}

    /// 引擎内部状态快照（诊断日志用，TODO 380）
    var diagnosticSnapshot: String {
        guard let player else { return "player=nil item=nil" }
        var parts = [
            "timeControl=\(Self.describeTimeControl(player.timeControlStatus))",
            "rate=\(player.rate)",
        ]
        if let reason = player.reasonForWaitingToPlay {
            parts.append("waitingReason=\(reason.rawValue)")
        }
        if let item = playerItem {
            parts.append("itemStatus=\(Self.describeItemStatus(item.status))")
            parts.append("bufferEmpty=\(item.isPlaybackBufferEmpty)")
            parts.append("keepUp=\(item.isPlaybackLikelyToKeepUp)")
        } else {
            parts.append("item=nil")
        }
        return parts.joined(separator: " ")
    }

    private static func describeTimeControl(_ status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .paused: return "paused"
        case .waitingToPlayAtSpecifiedRate: return "waiting"
        case .playing: return "playing"
        @unknown default: return "unknown"
        }
    }

    private static func describeItemStatus(_ status: AVPlayerItem.Status) -> String {
        switch status {
        case .unknown: return "unknown"
        case .readyToPlay: return "ready"
        case .failed: return "failed"
        @unknown default: return "unknown"
        }
    }

    // MARK: - 加载

    func load(url: URL, startAt: TimeInterval?) async throws {
        // 加载面包屑（TODO 380）：开始 / 媒体探测结果 / 提交 三段耗时，
        // 熄屏回来后若卡住可判断是「探测无响应」（无后续日志）还是「建连慢」
        let loadStart = ProcessInfo.processInfo.systemUptime
        loadStartedAt = loadStart
        lastReportedState = .idle
        lastReportedTime = 0
        didReachEnd = false
        AppLogger.shared.log(
            "硬解加载开始 url=\(url.absoluteString) startAt=\(startAt.map { String(Int($0)) } ?? "nil") 网络=\(NetworkPathMonitor.shared.snapshot())",
            level: .debug, module: "player-audio"
        )
        let asset = AVURLAsset(url: url)
        let playable: Bool
        do {
            playable = try await asset.load(.isPlayable)
        } catch {
            AppLogger.shared.log(
                "硬解媒体探测失败 url=\(url.absoluteString) error=\(error.localizedDescription) 耗时=\(Self.elapsedMs(since: loadStart))ms",
                level: .error, module: "player-audio"
            )
            throw error
        }
        AppLogger.shared.log(
            "硬解媒体探测 playable=\(playable) 耗时=\(Self.elapsedMs(since: loadStart))ms",
            level: .debug, module: "player-audio"
        )
        guard playable else { throw PlayerPlaybackError("系统原生无法解码该格式") }

        // 检测「有视频轨却无音频轨」：AVFoundation 对 DTS/DTS-HD/TrueHD/E-AC-3 等不支持的音频编码
        // 会直接不暴露音轨（loadTracks 返回空），导致起播成功但「有画面无声」（TODO 358）。
        // 抛错触发 PlayerCore 在 auto 模式下回退 VLC 软解兜底；纯音频文件无视频轨，不会误触发。
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        if !videoTracks.isEmpty, audioTracks.isEmpty {
            AppLogger.shared.log(
                "硬解音轨缺失 video=\(videoTracks.count) audio=0 -> 回退软解",
                module: "player-audio"
            )
            throw PlayerPlaybackError("该视频音频编码不受系统支持")
        }

        let item = AVPlayerItem(asset: asset)
        // 弱网抗抖动（TODO 356）：本地回环代理会让 AVPlayer 误判带宽极高（连的是 127.0.0.1），
        // 于是只维持很浅的缓冲；一旦代理后端弱网拉取阻塞就瞬间耗尽卡顿。显式设定前向缓冲目标时长，
        // 强制 AVPlayer 主动多囤数据抗抖动（0 为系统自动，此处用预加载秒数对齐软解 network-caching 策略）。
        // 发热优化：目标时长按 forwardBufferCapSeconds 封顶——高码率片源下 30s 缓冲即上百 MB，
        // AVPlayer 会满速下载并经代理逐片落盘，持续播放时网络/磁盘全程满载。
        item.preferredForwardBufferDuration = max(
            0, min(AppSettings.Player.preloadSeconds, AppSettings.Player.forwardBufferCapSeconds)
        )
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = true   // AirPlay
        // 退后台默认策略(.automatic)在无 PiP 时会暂停视频；改为尽可能继续播放（配合 UIBackgroundModes=audio）
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible

        self.playerItem = item
        self.player = player
        self.pendingStartAt = startAt
        self.didApplyStartAt = false

        // 音轨 / 字幕轨分组（内嵌轨选择）
        audibleGroup = try? await asset.loadMediaSelectionGroup(for: .audible)
        legibleGroup = try? await asset.loadMediaSelectionGroup(for: .legible)

        installObservers(player: player, item: item)
        report(.loading)
        AppLogger.shared.log(
            "硬解加载提交 video=\(videoTracks.count) audio=\(audioTracks.count) 总耗时=\(Self.elapsedMs(since: loadStart))ms 网络=\(NetworkPathMonitor.shared.snapshot())（等待 item 就绪）",
            level: .info, module: "player-audio"
        )

        // 异步记录音轨编码，定位「有画面无声」——判断音频编码是否被硬解支持（TODO 358）
        Task { await logAudioDiagnostics(asset: asset) }
    }

    // MARK: - 控制

    func play() {
        guard let player else { return }
        // 仅在「确实播放到结尾」时回退起点：此前只按位置判断，会把「刚 seek 到片尾附近再起播」
        // 误判成播放完毕而跳回 0（seek 等待结束后的自动续播正好走这条路径）
        let wasEnded = didReachEnd
        // 重新播放：解除「已播完」锁定，后续事件恢复正常上报
        didReachEnd = false
        // 播放完成后再次播放：AVPlayer 停在结尾时仅设置 rate 不会重启，先 seek 回起点
        if wasEnded, let item = playerItem, item.duration.isNumeric, item.duration.seconds > 0,
           player.currentTime().seconds >= item.duration.seconds - 1 {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            lastReportedTime = 0
        }
        player.rate = desiredRate
    }

    func pause() {
        player?.pause()
    }

    func stop() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        observations.forEach { $0.invalidate() }
        observations = []
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        if let stallObserver {
            NotificationCenter.default.removeObserver(stallObserver)
        }
        stallObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerItem = nil
        audibleGroup = nil
        legibleGroup = nil
        pendingStartAt = nil
        didApplyStartAt = false
        lastReportedState = .idle
        lastReportedTime = 0
        didReachEnd = false
    }

    /// 精准 seek（容差为零，保证历史进度恢复不偏移）
    func seek(to seconds: TimeInterval) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        // 从结尾往回拖：解除「已播完」锁定，否则后续 buffering/paused 事件会被丢弃、状态卡死
        if seconds < currentTime - 0.5 { didReachEnd = false }
        lastReportedTime = seconds
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setRate(_ rate: Float) {
        desiredRate = rate
        if player?.timeControlStatus == .playing {
            player?.rate = rate
        }
    }

    // MARK: - 轨道

    var availableAudioTracks: [TrackOption] {
        guard let group = audibleGroup else { return [] }
        return group.options.enumerated().map { TrackOption(id: $0.offset, name: $0.element.displayName) }
    }

    var availableSubtitleTracks: [TrackOption] {
        guard let group = legibleGroup else { return [] }
        return group.options.enumerated().map { TrackOption(id: $0.offset, name: $0.element.displayName) }
    }

    var currentAudioTrackID: Int? {
        guard let group = audibleGroup,
              let option = playerItem?.selectedMediaOption(in: group) else { return nil }
        return group.options.firstIndex(of: option)
    }

    var currentSubtitleTrackID: Int? {
        guard let group = legibleGroup,
              let option = playerItem?.selectedMediaOption(in: group) else { return nil }
        return group.options.firstIndex(of: option)
    }

    func selectAudioTrack(_ id: Int) {
        guard let group = audibleGroup, group.options.indices.contains(id) else { return }
        playerItem?.select(group.options[id], in: group)
    }

    func selectSubtitleTrack(_ id: Int?) {
        guard let group = legibleGroup else { return }
        if let id, group.options.indices.contains(id) {
            playerItem?.select(group.options[id], in: group)
        } else {
            playerItem?.select(nil, in: group)   // 关闭字幕
        }
    }

    // MARK: - 观测

    private func installObservers(player: AVPlayer, item: AVPlayerItem) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, time.isNumeric, time.seconds.isFinite else { return }
                self.healStateIfActuallyPlaying(current: time.seconds)
                self.onEvent?(.timeUpdated(current: time.seconds, duration: self.duration))
            }
        }

        observations.append(item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    // item 就绪耗时（TODO 380）：从 load 开始到可播的建连/拉流耗时，
                    // 熄屏回来若「加载提交」后长时间无此条，说明卡在服务器不响应
                    AppLogger.shared.log(
                        "硬解 item 就绪 起播总耗时=\(Int((ProcessInfo.processInfo.systemUptime - self.loadStartedAt) * 1000))ms",
                        level: .info, module: "player-audio"
                    )
                    self.applyPendingStartIfNeeded()
                    self.report(.ready)
                    self.onEvent?(.tracksChanged)
                case .failed:
                    // item 失败详情（TODO 380）：error 带域名/错误码，errorLog 带 HTTP 状态码，
                    // 用于区分「网络请求被拒/超时」与「媒体本身问题」
                    AppLogger.shared.log(
                        "硬解 item 失败 error=\(item.error.map { "\($0)" } ?? "nil") errorLog=\(Self.errorLogSummary(item)) 网络=\(NetworkPathMonitor.shared.snapshot())",
                        level: .error, module: "player-audio"
                    )
                    self.onEvent?(.stateChanged(.failed(item.error?.localizedDescription ?? "媒体加载失败")))
                default:
                    break
                }
            }
        })

        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch player.timeControlStatus {
                case .playing:
                    self.applyPendingStartIfNeeded()
                    self.report(.playing)
                case .paused:
                    self.report(.paused)
                case .waitingToPlayAtSpecifiedRate:
                    // 等待原因面包屑（TODO 380）：reason 区分「缓冲不足 / 评测起播码率 / 无 item」，
                    // 附缓冲水位与网络路径，定位熄屏回前台后起播卡在等待态的原因
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - self.lastWaitingLogAt >= 2 {
                        self.lastWaitingLogAt = now
                        AppLogger.shared.log(
                            "硬解等待播放 reason=\(player.reasonForWaitingToPlay?.rawValue ?? "nil") 缓冲空=\(item.isPlaybackBufferEmpty) 可续播=\(item.isPlaybackLikelyToKeepUp) 已缓冲=\(Int(self.bufferedTime))s 网络=\(NetworkPathMonitor.shared.snapshot())",
                            level: .warn, module: "player-audio"
                        )
                    }
                    self.report(.buffering)
                default:
                    break
                }
            }
        })

        observations.append(item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, item.isPlaybackBufferEmpty else { return }
                // 缓冲耗尽：仅在引擎确非播放态时上报缓冲，避免与 timeControlStatus 抢报
                if player.timeControlStatus != .playing {
                    self.report(.buffering)
                }
            }
        })

        // 缓冲恢复：数据重新充足到可持续播放时，若已在播放则切回 playing，
        // 清除「缓冲耗尽后卡在 buffering」——此前只监听 isPlaybackBufferEmpty 发 buffering，
        // 缓冲补上后 timeControlStatus 未变化不触发 KVO，状态无人切回，菊花一直转（TODO 353）。
        observations.append(item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, item.isPlaybackLikelyToKeepUp else { return }
                if player.timeControlStatus == .playing {
                    self.report(.playing)
                } else if player.timeControlStatus == .paused {
                    self.report(.ready)
                }
            }
        })

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 先置位再上报：短时长片源在结尾处 timeControlStatus→paused /
                // isPlaybackBufferEmpty→true 的 KVO 往往晚到一步，若放行会把已结束的播放
                // 拉回 buffering（菊花常转）或 paused（显示播放键），盖掉 ended
                self.didReachEnd = true
                self.report(.ended)
            }
        }

        // 播放停滞通知（TODO 380）：系统判定「数据断流」时记录水位与 errorLog，
        // 用于区分熄屏回前台后是「网络拉不动」还是「解码停顿」
        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                AppLogger.shared.log(
                    "硬解播放停滞（playbackStalled）time=\(Int(self.currentTime))s 已缓冲=\(Int(self.bufferedTime))s 缓冲空=\(item.isPlaybackBufferEmpty) 可续播=\(item.isPlaybackLikelyToKeepUp) errorLog=\(Self.errorLogSummary(item)) 网络=\(NetworkPathMonitor.shared.snapshot())",
                    level: .warn, module: "player-audio"
                )
            }
        }
    }

    // MARK: - 状态上报（含纠错兜底）

    /// 统一状态上报出口（TODO 353）：记录最近状态并过滤「与事实相反」的迟到事件。
    /// - 已播完（didReachEnd）：结尾处补发的 buffering / paused 一律改报 ended，
    ///   避免短时长片源（十余秒）在结尾处被迟到的 KVO 事件盖成永久菊花；
    /// - 实际仍在播放（timeControlStatus == .playing）：不上报 buffering。
    private func report(_ state: PlaybackState) {
        if didReachEnd, state == .buffering || state == .paused || state == .ready {
            if lastReportedState != .ended {
                lastReportedState = .ended
                onEvent?(.stateChanged(.ended))
            }
            return
        }
        if state == .buffering, player?.timeControlStatus == .playing {
            return
        }
        lastReportedState = state
        onEvent?(.stateChanged(state))
    }

    /// 时间推进兜底纠正（TODO 353）：媒体时间在一次回调间只前进了一点点（排除 seek 跳变），
    /// 且 AVPlayer 自述正在播放，说明画面确实在动；此时若上层仍停在 loading/buffering，
    /// 就主动纠正为 playing——KVO 事件缺失或乱序（短时长片源在结尾尤其容易）时不至于菊花常转。
    private func healStateIfActuallyPlaying(current: TimeInterval) {
        let previous = lastReportedTime
        lastReportedTime = current
        guard let player, player.timeControlStatus == .playing, player.rate > 0 else { return }
        // 增量上限排除 seek 跳变（本引擎的 seek / 重播都会同步 lastReportedTime，故增量只可能是播放推进）；
        // 上限放到 2.5s 以兼容 3 倍速下 0.5s 回调间隔的抖动
        guard current - previous > 0, current - previous <= 2.5 else { return }
        guard lastReportedState == .loading || lastReportedState == .buffering || lastReportedState == .ready else {
            return
        }
        AppLogger.shared.log(
            "硬解时间在推进但状态仍为 \(lastReportedState.logDescription)，纠正为 playing time=\(Int(current))s",
            level: .warn, module: "player-audio"
        )
        report(.playing)
    }

    /// 历史进度恢复：首帧就绪后一次性 seek 到起始位置（精准续播，不先 0 后跳）
    private func applyPendingStartIfNeeded() {
        guard !didApplyStartAt, let start = pendingStartAt, start > 1 else { return }
        didApplyStartAt = true
        AppLogger.shared.log("硬解恢复历史进度 seek=\(Int(start))s", level: .debug, module: "player-audio")
        seek(to: start)
    }

    /// 距起点毫秒数（诊断日志用，TODO 380）
    private static func elapsedMs(since start: TimeInterval) -> Int {
        Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
    }

    /// AVPlayerItem 错误日志摘要（HTTP 状态码等，TODO 380）
    private static func errorLogSummary(_ item: AVPlayerItem) -> String {
        guard let log = item.errorLog(), !log.events.isEmpty else { return "none" }
        return log.events.suffix(3).map { event in
            "[\(event.errorStatusCode) \(event.errorDomain ?? "?") \(event.errorComment ?? "") \(event.uri ?? "")]"
        }.joined(separator: " ")
    }

    /// 记录硬解音轨编码信息，定位「有画面无声」——判断音频编码是否被系统原生支持（TODO 358）
    private func logAudioDiagnostics(asset: AVURLAsset) async {
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        var parts: [String] = []
        for (i, track) in tracks.enumerated() {
            let descs = (try? await track.load(.formatDescriptions)) ?? []
            let codecs = descs.map { Self.fourCC(CMFormatDescriptionGetMediaSubType($0)) }.joined(separator: "+")
            parts.append("\(i):\(codecs.isEmpty ? "?" : codecs)")
        }
        AppLogger.shared.log(
            "硬解音轨诊断 url=\(asset.url.lastPathComponent) tracks=\(tracks.count) codecs=[\(parts.joined(separator: ","))] audibleOptions=\(audibleGroup?.options.count ?? 0)",
            module: "player-audio"
        )
    }

    /// FourCharCode 转可读字符串（如 'aac ' / 'ac-3' / 'ec-3' / 'dtsc' / 'Opus'）
    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        let ascii = bytes.map { (32...126).contains($0) ? $0 : UInt8(46) }   // 非可打印字符以 '.' 占位
        return String(bytes: ascii, encoding: .ascii) ?? "?"
    }
}
