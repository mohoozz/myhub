import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

/// 系统音量联动：读经 AVAudioSession，写经 MPVolumeView 隐藏滑杆（步进 5% 由手势层量化）。
enum SystemVolume {
    /// 常驻隐藏 MPVolumeView（挂到 keyWindow 保持引用，确保内部 UISlider 完成加载）
    private static var volumeView: MPVolumeView?

    private static var slider: UISlider? {
        volumeView?.subviews.compactMap { $0 as? UISlider }.first
    }

    /// 当前系统音量（真实输出音量；手势起点 / 进入播放页均以此为基准）
    static var current: Float {
        AVAudioSession.sharedInstance().outputVolume
    }

    /// 进入播放页时预安装，确保手势阶段 slider 已就绪（同时保持视图引用不释放）
    static func prepare() {
        DispatchQueue.main.async { installIfNeeded() }
    }

    /// 设置系统音量（0~1）。播放器不维护独立内部音量，统一以系统音量为唯一来源，故写系统音量即同步。
    static func set(_ value: Float) {
        DispatchQueue.main.async {
            installIfNeeded()
            let clamped = min(max(value, 0), 1)
            slider?.value = clamped
        }
    }

    private static func installIfNeeded() {
        if volumeView == nil {
            volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
        }
        guard let view = volumeView, view.superview == nil else { return }
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first else { return }
        window.addSubview(view)
    }
}

/// 中央悬浮胶囊反馈内容（调节时必须显示数值：时间 / 音量% / 亮度%）
enum GestureFeedback: Equatable {
    case seek(target: TimeInterval, duration: TimeInterval)
    case volume(percent: Int)
    case brightness(percent: Int)
    case speed(rate: Float)
}

/// 播放器手势层（iPhone）
struct PlayerGestureLayer: View {
    @ObservedObject var core: PlayerCore
    @Binding var feedback: GestureFeedback?
    /// 中央下拉偏移（PlayerView 据此做跟随动画）
    @Binding var miniDragOffset: CGFloat
    /// 界面锁定状态（锁定后手势层整体失效，由 PlayerView 提供解锁入口）
    @Binding var isLocked: Bool
    let onToggleControls: () -> Void
    /// 下拉过阈值进入 mini
    let onMini: () -> Void
    /// 长按进入界面锁定
    let onLock: () -> Void
    /// 锁定态单击屏幕：唤醒锁图标（重新显示并重置自动隐藏计时）
    let onWakeWhileLocked: () -> Void

    @State private var dragMode: DragMode?
    @State private var seekBase: TimeInterval = 0
    @State private var seekTarget: TimeInterval = 0
    @State private var gestureStartVolume: Float = 0
    @State private var gestureStartBrightness: CGFloat = 0
    @State private var hideTask: Task<Void, Never>?
    /// 最近一次单击时间戳，用于区分单击/双击（单击立即响应，不等待双击识别超时）
    @State private var lastTapAt: Date?

    private enum DragMode { case seek, volume, brightness, mini }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 常规手势层（锁定态失效）
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(dragGesture(in: geometry))
                    .onTapGesture {
                        handleTap()
                    }
                    // 长按 0.5s 立即锁定（按住满阈值即触发，不等松手）；与拖拽/单击/双击共存，不拦截其它手势。
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.5)
                            .onEnded { _ in
                                onLock()
                            }
                    )
                    .allowsHitTesting(!isLocked)

                // 锁定态专用层：仅响应单击，用于唤醒中央锁图标
                if isLocked {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onWakeWhileLocked()
                        }
                }
            }
        }
    }

 // MARK: - 单击 / 双击（单击立即响应）

    /// 单击立即切换控制层；短时间内第二次点击视为双击（播放/暂停）。
    private func handleTap() {
        let now = Date()
        if let last = lastTapAt, now.timeIntervalSince(last) < 0.3 {
            lastTapAt = nil
            AppLogger.shared.log("gesture tap(2) isLocked=\(isLocked)", module: "player-gesture")
            core.togglePlayPause()
        } else {
            lastTapAt = now
            AppLogger.shared.log("gesture tap(1) isLocked=\(isLocked)", module: "player-gesture")
            onToggleControls()
        }
    }

 // MARK: - 拖动手势（进度 / 音量 / 亮度）

    /// 下拉进入 mini 的距离阈值（pt）：拉过此距离松手即进入，不必拖过屏幕 1/6。
    private let miniTriggerDistance: CGFloat = 56
    /// 轻扫判定阈值（pt）：短距离但松手速度够快（按速度外推的终点位移）同样进入
    private let miniFlickDistance: CGFloat = 110

    private func dragGesture(in geometry: GeometryProxy) -> some Gesture {
        // 必须用 .global 坐标空间：miniDragOffset 让包含手势层的整个内容层跟随手指偏移
        let frame = geometry.frame(in: .global)
        return DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                if dragMode == nil {
                    if abs(value.translation.width) > abs(value.translation.height) {
                        dragMode = .seek
                        seekBase = core.currentTime
                        seekTarget = core.currentTime
                    } else {
                        let third = frame.width / 3
                        let startX = value.startLocation.x - frame.minX
                        if startX < third {
                            dragMode = .brightness
                            gestureStartBrightness = UIScreen.main.brightness
                        } else if startX > third * 2 {
                            dragMode = .volume
                            gestureStartVolume = SystemVolume.current
                        } else {
                            dragMode = .mini   // 画面中央下拉进入 mini
                        }
                    }
                    AppLogger.shared.log("gesture drag start mode=\(String(describing: dragMode)) isLocked=\(isLocked)", module: "player-gesture")
                }
                switch dragMode {
                case .seek:
                    guard core.duration > 0 else { return }
                    let ratio = value.translation.width / max(frame.width, 1)
                    // 固定跨度（随滑动距离 5s~60s）：满屏滑动对应 60s，不再随视频总时长放大。
                    let maxDelta: TimeInterval = 60
                    let delta = maxDelta * Double(min(max(ratio, -1), 1))
                    seekTarget = min(max(0, seekBase + delta), core.duration)
                    show(.seek(target: seekTarget, duration: core.duration))
                case .volume:
                    let delta = Float(-value.translation.height / max(frame.height, 1))
                    let stepped = ((gestureStartVolume + delta) / 0.05).rounded() * 0.05   // 步进 5%
                    let clamped = min(max(stepped, 0), 1)
                    SystemVolume.set(clamped)
                    show(.volume(percent: Int((clamped * 100).rounded())))
                case .brightness:
                    let delta = -value.translation.height / max(frame.height, 1)
                    let brightness = min(max(gestureStartBrightness + delta, 0), 1)
                    UIScreen.main.brightness = brightness
                    show(.brightness(percent: Int((brightness * 100).rounded())))
                case .mini:
                    miniDragOffset = max(0, value.translation.height)
                case nil:
                    break
                }
            }
            .onEnded { value in
                switch dragMode {
                case .seek:
                    core.seek(to: seekTarget)
                    hideFeedbackLater()
                case .mini:
                    // 距离过阈值直接进入；短距离但松手够快（速度外推的终点位移超阈值）同样进入
                    let predicted = value.predictedEndTranslation.height
                    if max(0, value.translation.height) > miniTriggerDistance || predicted > miniFlickDistance {
                        onMini()
                    }
                    withAnimation(.appQuick) { miniDragOffset = 0 }
                default:
                    hideFeedbackLater()
                }
                dragMode = nil
            }
    }

 // MARK: - 反馈显示

    private func show(_ newFeedback: GestureFeedback) {
        hideTask?.cancel()
        feedback = newFeedback
    }

    private func hideFeedbackLater() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            feedback = nil
        }
    }
}

/// 中央悬浮胶囊（图标 + 数值）
struct GestureFeedbackCapsule: View {
    let feedback: GestureFeedback

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
            Text(text)
                .monospacedDigit()
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.65))
        .clipShape(Capsule())
        .overlay {
            Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5)
        }
    }

    private var symbol: String {
        switch feedback {
        case .seek: return "clock"
        case .volume(let percent):
            if percent == 0 { return "speaker.slash.fill" }
            return percent < 50 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
        case .brightness: return "sun.max.fill"
        case .speed: return "forward.fill"
        }
    }

    private var text: String {
        switch feedback {
        case .seek(let target, let duration):
            return "\(DisplayFormatters.duration(target)) / \(DisplayFormatters.duration(duration))"
        case .volume(let percent):
            return "\(percent)%"
        case .brightness(let percent):
            return "\(percent)%"
        case .speed(let rate):
            return String(format: "%gx", rate)
        }
    }
}
