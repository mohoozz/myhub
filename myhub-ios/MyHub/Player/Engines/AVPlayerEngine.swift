import AVFoundation

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

        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = true   // AirPlay

        self.playerItem = item
        self.player = player
        self.pendingStartAt = startAt
        self.didApplyStartAt = false

        // 音轨 / 字幕轨分组（内嵌轨选择）
        audibleGroup = try? await asset.loadMediaSelectionGroup(for: .audible)
        legibleGroup = try? await asset.loadMediaSelectionGroup(for: .legible)

        installObservers(player: player, item: item)
        onEvent?(.stateChanged(.loading))
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
                guard item.isPlaybackBufferEmpty else { return }
                self?.onEvent?(.stateChanged(.buffering))
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
}
