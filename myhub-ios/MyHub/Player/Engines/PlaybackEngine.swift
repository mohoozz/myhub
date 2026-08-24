import Foundation

/// 引擎类型（《需求分析文档》§4.3 双引擎解码策略）
enum PlayerEngineKind: String, Equatable {
    case hardware   // AVPlayer / VideoToolbox 硬解（H.264/HEVC 等）
    case software   // MobileVLCKit 软解兜底（mkv/rmvb/avi/flv/wmv/ts…）

    var displayName: String {
        switch self {
        case .hardware: return "硬解"
        case .software: return "软解"
        }
    }
}

/// 播放状态（UI 经 PlayerCore 订阅）
enum PlaybackState: Equatable {
    case idle
    case loading      // 引擎加载/探测中
    case ready        // 首帧就绪（已应用起始 seek）
    case playing
    case paused
    case buffering
    case ended
    case failed(String)

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// 音轨 / 字幕轨选项
struct TrackOption: Equatable, Identifiable {
    let id: Int
    let name: String
}

/// 播放错误
struct PlayerPlaybackError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// 引擎 → PlayerCore 事件
enum PlayerEngineEvent {
    case stateChanged(PlaybackState)
    case timeUpdated(current: TimeInterval, duration: TimeInterval)
    case tracksChanged   // 解析完成，音轨/字幕轨列表可用
}

/// 双引擎统一接口（PlayerCore 之下的引擎层，参考 nPlayer 架构）。
/// 实现：AVPlayerEngine（硬解）/ VLCEngine（软解）；切换对上层透明。
@MainActor
protocol PlaybackEngine: AnyObject {
    var kind: PlayerEngineKind { get }
    var onEvent: ((PlayerEngineEvent) -> Void)? { get set }

    /// 渲染输出：AVPlayer（硬解，供 AVPlayerLayer/AVPlayerViewController）/
    /// VLCMediaPlayer（软解，UI 将 drawable 指向宿主视图）——TODO §4.3 渲染层接管
    var videoOutput: Any? { get }

    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get }
    /// 已缓冲到的位置（秒，进度条缓冲段显示；软解无此信息时返回 0）
    var bufferedTime: TimeInterval { get }

    /// 纯音频模式：关闭画面解码/渲染（软解断开视频轨节电；硬解仅隐藏画面）
    func setVideoEnabled(_ enabled: Bool)

    /// 加载媒体；startAt 为历史进度恢复位置（首帧就绪后一次性精准 seek，不得先 0 后跳）
    func load(url: URL, startAt: TimeInterval?) async throws
    func play()
    func pause()
    func stop()

    func seek(to seconds: TimeInterval)
    func setRate(_ rate: Float)

    var availableAudioTracks: [TrackOption] { get }
    var availableSubtitleTracks: [TrackOption] { get }
    var currentAudioTrackID: Int? { get }
    var currentSubtitleTrackID: Int? { get }
    func selectAudioTrack(_ id: Int)
    /// 选择字幕轨；nil = 关闭字幕
    func selectSubtitleTrack(_ id: Int?)
}
