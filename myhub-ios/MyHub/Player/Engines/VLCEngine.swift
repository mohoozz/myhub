import Foundation
import MobileVLCKit

/// VLC delegate 回调跨线程触发的线程安全时间节流器：
/// 软解时间回报回调可达数十次/秒，若全部派发到主线程会放大发热，限制到约 4 次/秒。
private final class VLCTimeThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last: TimeInterval = 0

    func shouldPass(interval: TimeInterval, now: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard now - last >= interval else { return false }
        last = now
        return true
    }
}

private let vlcTimeThrottle = VLCTimeThrottle()

/// 软解引擎：MobileVLCKit 兜底全格式（mkv/rmvb/avi/flv/wmv/ts…）。
/// 状态/时间经 VLCMediaPlayerDelegate 回报；UI 将 `player.drawable` 指向宿主视图渲染（TODO §4.3）。
@MainActor
final class VLCEngine: NSObject, PlaybackEngine {
    let kind: PlayerEngineKind = .software
    var onEvent: ((PlayerEngineEvent) -> Void)?

    private let player = VLCMediaPlayer()

    private var desiredRate: Float = 1
    private var pendingStartAt: TimeInterval?
    private var didApplyStartAt = false
    private var didEmitReady = false
    /// 最近一次上报给上层的状态：用于「时间在走却仍标记 buffering」的兜底纠正（TODO 353）
    private var lastReportedState: PlaybackState = .idle

    override init() {
        super.init()
        player.delegate = self
    }

    var videoOutput: Any? { player }

    var duration: TimeInterval {
        guard let seconds = player.media?.length.value?.doubleValue, seconds > 0 else { return 0 }
        return seconds / 1000
    }

    var currentTime: TimeInterval {
        guard let seconds = player.time.value?.doubleValue, seconds > 0 else { return 0 }
        return seconds / 1000
    }

    /// VLC 无统一缓冲位置接口
    var bufferedTime: TimeInterval { 0 }

    /// 纯音频模式：断开视频轨（-1）关闭画面解码节电；恢复时选回首个视频轨
    func setVideoEnabled(_ enabled: Bool) {
        if enabled {
            let indexes = (player.videoTrackIndexes as? [NSNumber]) ?? []
            if let first = indexes.first(where: { $0.intValue >= 0 }) {
                player.currentVideoTrackIndex = first.int32Value
            }
        } else {
            player.currentVideoTrackIndex = -1
        }
    }

    // MARK: - 加载

    func load(url: URL, startAt: TimeInterval?) async throws {
        pendingStartAt = startAt
        didApplyStartAt = false
        didEmitReady = false
        let media = VLCMedia(url: url)
        // 优先硬件解码（VideoToolbox）降低软解 CPU 发热；不支持的编码由 avcodec 自动回退软解
        media.addOption(":avcodec-hw=videotoolbox")
        // 弱网抗抖动（TODO 356）：加大解复用前的网络缓冲。VLC 默认 network-caching 仅 1000ms，
        // 弱网下极易耗尽卡顿；用预加载秒数换算并限制在 3~5s，对齐 nPlayer 软解平滑度，兼顾起播速度。
        let networkCachingMs = Int(min(max(AppSettings.Player.preloadSeconds, 3), 5) * 1000)
        media.addOption(":network-caching=\(networkCachingMs)")
        player.media = media
        onEvent?(.stateChanged(.loading))
        // VLCKit 异步起播：opening/buffering/playing 状态经 delegate 回报
    }

    // MARK: - 控制

    func play() {
        player.rate = desiredRate
        player.play()
    }

    func pause() {
        player.pause()
    }

    func stop() {
        player.stop()
        player.media = nil
        pendingStartAt = nil
        didApplyStartAt = false
        didEmitReady = false
        lastReportedState = .idle
    }

    func seek(to seconds: TimeInterval) {
        player.time = VLCTime(number: NSNumber(value: max(0, seconds) * 1000))
    }

    func setRate(_ rate: Float) {
        desiredRate = rate
        player.rate = rate
    }

    // MARK: - 轨道

    var availableAudioTracks: [TrackOption] {
        zipTracks(names: player.audioTrackNames, indexes: player.audioTrackIndexes)
    }

    var availableSubtitleTracks: [TrackOption] {
        zipTracks(names: player.videoSubTitlesNames, indexes: player.videoSubTitlesIndexes)
    }

    var currentAudioTrackID: Int? {
        let id = Int(player.currentAudioTrackIndex)
        return availableAudioTracks.contains { $0.id == id } ? id : nil
    }

    var currentSubtitleTrackID: Int? {
        let id = Int(player.currentVideoSubTitleIndex)
        return id >= 0 ? id : nil
    }

    func selectAudioTrack(_ id: Int) {
        player.currentAudioTrackIndex = Int32(id)
    }

    func selectSubtitleTrack(_ id: Int?) {
        player.currentVideoSubTitleIndex = Int32(id ?? -1)   // -1 = 关闭字幕
    }

    /// 轨道名称与索引配对（VLCKit 返回 [String] / [NSNumber]）
    private func zipTracks(names: [Any]?, indexes: [Any]?) -> [TrackOption] {
        guard let names, let indexes else { return [] }
        return zip(names, indexes).compactMap { name, index in
            guard let id = (index as? NSNumber)?.intValue else { return nil }
            return TrackOption(id: id, name: String(describing: name))
        }
    }

    // MARK: - delegate 状态处理

    /// 统一状态上报出口：记录最近状态，供时间回调兜底纠正
    private func emit(_ state: PlaybackState) {
        lastReportedState = state
        onEvent?(.stateChanged(state))
    }

    fileprivate func handleStateChanged() {
        switch player.state {
        case .opening:
            emit(.loading)
        case .buffering:
            // VLCKit 的 buffering 通知有时在播放中途重复触发：若已在播放（时间在走）则不回退菊花
            if player.isPlaying, currentTime > 0 {
                emit(.playing)
            } else {
                emit(.buffering)
            }
        case .playing:
            applyPendingStartIfNeeded()
            if !didEmitReady {
                didEmitReady = true
                emit(.ready)
                onEvent?(.tracksChanged)
                logAudioDiagnostics()
            }
            emit(.playing)
        case .paused:
            emit(.paused)
        case .stopped:
            emit(.idle)
        case .ended:
            emit(.ended)
        case .error:
            emit(.failed("软解引擎播放失败"))
        default:
            break
        }
    }

    fileprivate func handleTimeChanged() {
        applyPendingStartIfNeeded()
        // 兜底：时间在推进说明实际已在播放，但 VLCKit 的 buffering→playing 状态变更有时不触发，
        // 导致卡在 buffering 菊花不消失（TODO 353）。此处主动纠正为 playing。
        // 限已发过 ready（首帧就绪、轨道已解析）后再纠正，避免抢在 ready/tracksChanged 之前。
        if didEmitReady, lastReportedState == .buffering, player.isPlaying {
            emit(.playing)
        }
        onEvent?(.timeUpdated(current: currentTime, duration: duration))
    }

    /// 历史进度恢复：起播后一次性 seek 到起始位置（精准续播）
    private func applyPendingStartIfNeeded() {
        guard !didApplyStartAt, player.state == .playing, let start = pendingStartAt, start > 1 else { return }
        didApplyStartAt = true
        seek(to: start)
        player.rate = desiredRate
    }

    /// 记录软解音轨信息，定位「有画面无声」——音轨是否被识别/选中（TODO 358）
    private func logAudioDiagnostics() {
        let names = (player.audioTrackNames as? [String]) ?? []
        let indexes = (player.audioTrackIndexes as? [NSNumber]) ?? []
        AppLogger.shared.log(
            "软解音轨诊断 names=[\(names.joined(separator: ","))] indexes=[\(indexes.map { $0.stringValue }.joined(separator: ","))] current=\(player.currentAudioTrackIndex)",
            module: "player-audio"
        )
    }
}

extension VLCEngine: VLCMediaPlayerDelegate {
    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor in self.handleStateChanged() }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        let now = ProcessInfo.processInfo.systemUptime
        guard vlcTimeThrottle.shouldPass(interval: 0.25, now: now) else { return }
        Task { @MainActor in self.handleTimeChanged() }
    }
}
