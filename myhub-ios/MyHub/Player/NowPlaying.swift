import AVFoundation
import Combine
import MediaPlayer
import UIKit

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
    /// 当前条目的锁屏封面（由播放页/封面服务回填，随条目切换清空）
    private var artwork: MPMediaItemArtwork?
    private var artworkPath: String?

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
            .sink { item in
                Task { @MainActor [weak self] in
                    self?.handleItemChange(item)
                }
            }
            .store(in: &cancellables)

        setupRemoteCommands()

        // 后台保活：软解引擎(VLCKit)退后台瞬间可能自动暂停，延迟重断言播放
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleEnterBackground() }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleWillEnterForeground() }
            }
            .store(in: &cancellables)

        // 音频中断（来电/Siri/其他 App 抢占音频）结束后的恢复
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] note in
                Task { @MainActor [weak self] in self?.handleInterruption(note) }
            }
            .store(in: &cancellables)
    }

    // MARK: - 封面（与播放页共享 CoverService 缓存）

    /// 条目切换：清空旧封面并异步加载（复用 CoverService 内存/磁盘缓存，与浏览/播放页同源）
    private func handleItemChange(_ item: PlayableItem?) {
        updateInfo()
        guard let item, item.path != artworkPath else {
            if item == nil { artwork = nil; artworkPath = nil }
            return
        }
        artwork = nil
        artworkPath = item.path
        Task { [weak self] in
            let result = await CoverService.shared.cover(forItem: item)
            await MainActor.run {
                guard let self, self.artworkPath == item.path, let image = result.image else { return }
                self.setArtwork(image, for: item.path)
            }
        }
    }

    /// 由播放页在已加载封面时回填，避免锁屏重复加载
    func setArtwork(_ image: UIImage, for path: String) {
        guard PlayerCore.shared.currentItem?.path == path else { return }
        artworkPath = path
        artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        updateInfo()
    }

    // MARK: - 会话与信息

    private func handleState(_ state: PlaybackState) {
        let session = AVAudioSession.sharedInstance()
        switch state {
        case .loading, .buffering, .ready, .playing:
            if !sessionConfigured {
                do {
                    try session.setCategory(.playback, mode: .moviePlayback)
                    sessionConfigured = true
                } catch {
                    AppLogger.shared.log(
                        "设置音频会话 category 失败 error=\(error.localizedDescription)",
                        level: .error, module: "player-audio"
                    )
                }
            }
            do {
                try session.setActive(true)
            } catch {
                AppLogger.shared.log(
                    "激活音频会话失败 error=\(error.localizedDescription)",
                    level: .error, module: "player-audio"
                )
            }
        case .idle, .ended, .failed:
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            artwork = nil
            artworkPath = nil
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
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - 后台保活 / 音频中断

    /// 退后台瞬间是否正在播放（重断言只针对「系统自动暂停」，用户主动暂停不干预）
    private var playingBeforeBackground = false
    /// 音频被打断前是否在播放
    private var playingBeforeInterruption = false

    /// 退后台：VLCKit/系统可能在退后台瞬间自动暂停，短暂延迟后按播放意图重断言一次
    private func handleEnterBackground() {
        let core = PlayerCore.shared
        playingBeforeBackground = core.isPlaying
        guard playingBeforeBackground else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.playingBeforeBackground else { return }
                let core = PlayerCore.shared
                // 用户在控制中心主动暂停(pausedAt != nil)则不干预；仅恢复系统自动暂停
                if core.state == .paused, core.pausedAt == nil {
                    core.play()
                }
                self.playingBeforeBackground = false
            }
        }
    }

    /// 回前台兜底：若退后台期间被系统自动暂停（非用户主动）则恢复
    private func handleWillEnterForeground() {
        let core = PlayerCore.shared
        guard playingBeforeBackground, core.state == .paused, core.pausedAt == nil else { return }
        core.play()
        playingBeforeBackground = false
    }

    /// 音频中断：来电/其他 App 抢占用结束后，按系统建议恢复播放
    private func handleInterruption(_ notification: Notification) {
        guard
            let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
        else { return }
        switch type {
        case .began:
            playingBeforeInterruption = PlayerCore.shared.isPlaying
        case .ended:
            let shouldResume = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
            try? AVAudioSession.sharedInstance().setActive(true)
            if playingBeforeInterruption, shouldResume {
                PlayerCore.shared.play()
            }
            playingBeforeInterruption = false
        @unknown default:
            break
        }
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
