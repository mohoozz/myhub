import Foundation
import MobileVLCKit

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

    override init() {
        super.init()
        player.delegate = self
    }

    var videoOutput: Any? { player }

    var duration: TimeInterval {
        guard let seconds = player.media?.length?.value?.doubleValue, seconds > 0 else { return 0 }
        return seconds / 1000
    }

    var currentTime: TimeInterval {
        guard let seconds = player.time?.value?.doubleValue, seconds > 0 else { return 0 }
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
        player.media = VLCMedia(url: url)
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

    fileprivate func handleStateChanged() {
        switch player.state {
        case .opening:
            onEvent?(.stateChanged(.loading))
        case .buffering:
            onEvent?(.stateChanged(.buffering))
        case .playing:
            applyPendingStartIfNeeded()
            if !didEmitReady {
                didEmitReady = true
                onEvent?(.stateChanged(.ready))
                onEvent?(.tracksChanged)
            }
            onEvent?(.stateChanged(.playing))
        case .paused:
            onEvent?(.stateChanged(.paused))
        case .stopped:
            onEvent?(.stateChanged(.idle))
        case .ended:
            onEvent?(.stateChanged(.ended))
        case .error:
            onEvent?(.stateChanged(.failed("软解引擎播放失败")))
        default:
            break
        }
    }

    fileprivate func handleTimeChanged() {
        applyPendingStartIfNeeded()
        onEvent?(.timeUpdated(current: currentTime, duration: duration))
    }

    /// 历史进度恢复：起播后一次性 seek 到起始位置（精准续播）
    private func applyPendingStartIfNeeded() {
        guard !didApplyStartAt, player.state == .playing, let start = pendingStartAt, start > 1 else { return }
        didApplyStartAt = true
        seek(to: start)
        player.rate = desiredRate
    }
}

extension VLCEngine: VLCMediaPlayerDelegate {
    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor in self.handleStateChanged() }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor in self.handleTimeChanged() }
    }
}
