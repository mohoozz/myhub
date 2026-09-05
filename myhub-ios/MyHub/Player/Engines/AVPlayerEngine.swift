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

    // MARK: - 加载

    func load(url: URL, startAt: TimeInterval?) async throws {
        let asset = AVURLAsset(url: url)
        let playable = (try? await asset.load(.isPlayable)) ?? false
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
        item.preferredForwardBufferDuration = max(0, AppSettings.Player.preloadSeconds)
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
        onEvent?(.stateChanged(.loading))

        // 异步记录音轨编码，定位「有画面无声」——判断音频编码是否被硬解支持（TODO 358）
        Task { await logAudioDiagnostics(asset: asset) }
    }

    // MARK: - 控制

    func play() {
        guard let player else { return }
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
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerItem = nil
        audibleGroup = nil
        legibleGroup = nil
        pendingStartAt = nil
        didApplyStartAt = false
    }

    /// 精准 seek（容差为零，保证历史进度恢复不偏移）
    func seek(to seconds: TimeInterval) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
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
                self.onEvent?(.timeUpdated(current: time.seconds, duration: self.duration))
            }
        }

        observations.append(item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.applyPendingStartIfNeeded()
                    self.onEvent?(.stateChanged(.ready))
                    self.onEvent?(.tracksChanged)
                case .failed:
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
                    self.onEvent?(.stateChanged(.playing))
                case .paused:
                    self.onEvent?(.stateChanged(.paused))
                case .waitingToPlayAtSpecifiedRate:
                    self.onEvent?(.stateChanged(.buffering))
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
                    self.onEvent?(.stateChanged(.buffering))
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
                    self.onEvent?(.stateChanged(.playing))
                } else if player.timeControlStatus == .paused {
                    self.onEvent?(.stateChanged(.ready))
                }
            }
        })

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onEvent?(.stateChanged(.ended))
            }
        }
    }

    /// 历史进度恢复：首帧就绪后一次性 seek 到起始位置（精准续播，不先 0 后跳）
    private func applyPendingStartIfNeeded() {
        guard !didApplyStartAt, let start = pendingStartAt, start > 1 else { return }
        didApplyStartAt = true
        seek(to: start)
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
