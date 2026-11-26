import AVFoundation
import MobileVLCKit
import UIKit

/// 画面承载方式
enum VideoSurfaceStyle {
    /// 全屏：等比完整显示（不裁切、不拉伸）
    case fullscreen
    /// mini 预览：填满裁切（对齐 Flutter `BoxFit.cover`）
    case cover

    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fullscreen: return .resizeAspect
        case .cover: return .resizeAspectFill
        }
    }

    /// 是否为全屏宿主（画面优先给全屏，避免退场动画期间来回搬动）
    var isFullscreen: Bool {
        switch self {
        case .fullscreen: return true
        case .cover: return false
        }
    }
}

/// 全局唯一的视频画面承载视图（硬解 AVPlayerLayer / 软解 VLC drawable 都挂在它上面）。
///
/// 为什么共享：libvlc 的 `drawable` 只在 vout（视频输出）创建时被读取一次，
/// 播放过程中改写 `mediaPlayer.drawable` 只是赋值一个变量，既不会重建 vout，
/// 也不会把已经在跑的画面迁到新视图上——表现为「切到 mini 后黑屏，再回全屏还是黑屏」。
/// 因此全屏与 mini 不再各自持有一个渲染视图，而是共用这一个 UIView，
/// 进出 mini 时只做「换父视图」（reparent），vout 全程不重建，画面连续不中断。
@MainActor
final class VideoSurface {
    static let shared = VideoSurface()

    /// 共享画面视图
    let view = PlayerRenderUIView()

    /// 硬解渲染层（画中画依赖它）
    private(set) var playerLayer: AVPlayerLayer?

    /// 当前绑定的输出（AVPlayer / VLCMediaPlayer）
    private weak var boundOutput: AnyObject?
    /// 当前正在承载画面的宿主
    private weak var owner: SurfaceHostView?
    /// 宿主栈：后声明者优先；宿主退场时把画面交还给仍在窗口中的上一个宿主
    private var hosts: [SurfaceHostView] = []

    private init() {}

    // MARK: - 绑定输出

    /// 绑定渲染输出，同一输出幂等。
    /// 必须在视图进入窗口之前就调用：vout 创建时要能读到 `drawable-nsobject`，否则软解无画面。
    func bind(_ output: Any?) {
        let object = output as AnyObject?
        if let object, object === boundOutput { return }
        unbind()
        guard let object else { return }

        if let player = object as? AVPlayer {
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspect
            layer.backgroundColor = UIColor.black.cgColor
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
            playerLayer = layer
            AppLogger.shared.log("渲染桥绑定 硬解 AVPlayerLayer", level: .debug, module: "player")
        } else if let mediaPlayer = object as? VLCMediaPlayer {
            mediaPlayer.drawable = view
            AppLogger.shared.log("渲染桥绑定 软解 VLC drawable", level: .debug, module: "player")
        } else {
            return
        }
        boundOutput = object
    }

    /// 解绑（仅在「换输出 / 会话结束」时调用；视图进出 mini 不解绑，否则 vout 无法重建）
    func unbind() {
        if let mediaPlayer = boundOutput as? VLCMediaPlayer,
           mediaPlayer.drawable as? PlayerRenderUIView === view {
            mediaPlayer.drawable = nil
        }
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        boundOutput = nil
    }

    // MARK: - 宿主流转

    /// 宿主声明自己要承载画面（进入窗口 / 布局时调用）
    func claim(_ host: SurfaceHostView) {
        // 先剔除已离场的宿主，避免栈被拆掉的视图撑住
        hosts.removeAll { $0 !== host && $0.window == nil }
        hosts.removeAll { $0 === host }
        hosts.append(host)
        activatePreferred()
    }

    /// 宿主退场：把画面交还给仍在窗口中的上一个宿主（全屏 ↔ mini 双向切换都靠这里兜底）
    func release(_ host: SurfaceHostView) {
        hosts.removeAll { $0 === host }
        guard owner === host else { return }
        owner = nil
        if preferredHost() != nil {
            activatePreferred()
        } else {
            // 没有宿主了：先留在自己身上，等下一次 claim 再搬（VLC 仍在往这里输出）
            view.removeFromSuperview()
        }
    }

    /// 画面优先给全屏宿主：既避免「进 mini 时全屏还在退场动画里就先把画面抽走」造成的闪烁，
    /// 也保证「mini 退场动画期间展开全屏」时画面立刻回到全屏。
    private func preferredHost() -> SurfaceHostView? {
        let alive = hosts.filter { $0.window != nil }
        return alive.last(where: { $0.style.isFullscreen }) ?? alive.last
    }

    private func activatePreferred() {
        guard let host = preferredHost() else { return }
        activate(host)
    }

    private func activate(_ host: SurfaceHostView) {
        let changed = owner !== host
        owner = host
        // 这里只搬画面，不碰输出绑定：绑定由 `bind(_:)` 单独负责，
        // 避免退场中的旧宿主把自己的（已过期）输出重新绑回来。
        if let layer = playerLayer, layer.videoGravity != host.style.videoGravity {
            layer.videoGravity = host.style.videoGravity
        }
        if view.superview !== host {
            view.frame = host.bounds
            host.addSubview(view)
        } else if view.frame != host.bounds {
            view.frame = host.bounds
        }
        if changed {
            AppLogger.shared.log(
                "画面宿主切换 style=\(host.style.isFullscreen ? "full" : "mini") 宿主数=\(hosts.count)",
                level: .debug, module: "player"
            )
        }
    }
}

/// 承载共享画面的容器视图（一个 SwiftUI 全屏层 / mini 各持有一个）。
/// 画面本体是 `VideoSurface.shared.view`，同一时刻只能有一个父视图，所以「搬家」是原子的。
final class SurfaceHostView: UIView {
    /// 承载方式（全屏等比 / mini 填满）
    var style: VideoSurfaceStyle = .fullscreen

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            VideoSurface.shared.claim(self)
        } else {
            VideoSurface.shared.release(self)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 只在窗口内的宿主参与画面流转，退场中的视图不得把画面拽走
        guard window != nil else { return }
        VideoSurface.shared.claim(self)
    }
}

/// 画面本体：随布局同步子层（AVPlayerLayer / VLC 的 GL 子视图）尺寸
final class PlayerRenderUIView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.sublayers?.forEach { $0.frame = bounds }
    }
}
