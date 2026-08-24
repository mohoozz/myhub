import AVFoundation
import Combine
import MediaPlayer

/// 后台音频播放 + 锁屏/控制中心（IOS-602）：
/// - `AVAudioSession(.playback)`：锁屏/后台继续播放音频；
/// - `MPNowPlayingInfoCenter`：锁屏「正在播放」标题/作者/进度；
/// - `MPRemoteCommandCenter`：远程控制（播放/暂停/快进快退/拖动定位）。
/// App 启动时 attach（MyHubApp 根视图 onAppear）。
@MainActor
final class NowPlaying {
    static let shared = NowPlaying()

    private var cancellables = Set<AnyCancellable>()
    private var sessionConfigured = false

    private init() {}

    func attach() {
        let core = PlayerCore.shared

        core.$state
            .sink { state in Task { @MainActor [weak self] in self?.handleState(state) } }
            .store(in: &cancellables)

        core.$currentTime
            .throttle(for: .seconds(5), scheduler: DispatchQueue.main, latest: true)
            .sink { _ in Task { @MainActor [weak self] in self?.updateInfo() } }
            .store(in: &cancellables)

        core.$currentItem
            .sink { _ in Task { @MainActor [weak self] in self?.updateInfo() } }
            .store(in: &cancellables)

        setupRemoteCommands()
    }

    // MARK: - 会话与信息

    private func handleState(_ state: PlaybackState) {
        let session = AVAudioSession.sharedInstance()
        switch state {
        case .loading, .buffering, .ready, .playing:
            if !sessionConfigured {
                try? session.setCategory(.playback, mode: .moviePlayback)
                sessionConfigured = true
            }
            try? session.setActive(true)
        case .idle, .ended, .failed:
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        case .paused:
            break
        }
        updateInfo()
    }

    private func updateInfo() {
        let core = PlayerCore.shared
        guard let item = core.currentItem, core.state != .idle else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        let parsed = Self.parseAuthorTitle(item.title)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: parsed.title,
            MPMediaItemPropertyPlaybackDuration: core.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: core.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: core.isPlaying ? core.rate : 0,
        ]
        if let author = parsed.author {
            info[MPMediaItemPropertyArtist] = author
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - 远程控制

    private func setupRemoteCommands() {
        let core = PlayerCore.shared
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { _ in
            Task { @MainActor in core.play() }
            return .success
        }
        center.pauseCommand.addTarget { _ in
            Task { @MainActor in core.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in core.togglePlayPause() }
            return .success
        }

        let step = AppSettings.Player.seekStepSeconds
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: step)]
        center.skipForwardCommand.addTarget { _ in
            Task { @MainActor in core.seek(by: step) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: step)]
        center.skipBackwardCommand.addTarget { _ in
            Task { @MainActor in core.seek(by: -step) }
            return .success
        }

        center.changePlaybackPositionCommand.addTarget { event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in core.seek(to: positionEvent.positionTime) }
            return .success
        }
    }

    // MARK: - 「作者 - 标题」文件名解析

    static func parseAuthorTitle(_ fileName: String) -> (author: String?, title: String) {
        let stem = (fileName as NSString).deletingPathExtension
        guard let range = stem.range(of: " - ") else { return (nil, stem) }
        let author = String(stem[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let title = String(stem[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (author.isEmpty ? nil : author, title.isEmpty ? stem : title)
    }
}
