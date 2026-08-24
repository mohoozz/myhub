import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

/// 系统音量联动（IOS-201）：读经 AVAudioSession，写经 MPVolumeView 隐藏滑杆（步进 5% 由手势层量化）
enum SystemVolume {
    static var current: Float {
        AVAudioSession.sharedInstance().outputVolume
    }

    static func set(_ value: Float) {
        DispatchQueue.main.async {
            let volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
            guard let window = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
                .first else { return }
            window.addSubview(volumeView)
            let slider = volumeView.subviews.compactMap { $0 as? UISlider }.first
            slider?.value = min(max(value, 0), 1)
            volumeView.removeFromSuperview()
        }
    }
}

/// 中央悬浮胶囊反馈内容（调节时必须显示数值：时间 / 音量% / 亮度%）
enum GestureFeedback: Equatable {
    case seek(target: TimeInterval, duration: TimeInterval)
    case volume(percent: Int)
    case brightness(percent: Int)
    case speed(rate: Float)
    case jump(seconds: TimeInterval)
}

/// 播放器手势层（IOS-201 / IOS-701，iPhone）：
/// - 水平滑动调节进度（松手 seek）；右侧 1/3 竖滑调音量（系统联动，步进 5%）；左侧 1/3 竖滑调亮度；
/// - **画面中央 1/3 向下拖动进入 mini（跟随手指偏移，松手过阈值进入，带过渡动画）**；
/// - 双击左/右快退/快进（步进 AppSettings.Player.seekStepSeconds，默认 10s）；双击中央播放/暂停；
/// - 长按 2x 倍速，松开恢复；单击切换控制层。
struct PlayerGestureLayer: View {
    @ObservedObject var core: PlayerCore
    @Binding var feedback: GestureFeedback?
    /// 中央下拉偏移（PlayerView 据此做跟随动画）
    @Binding var miniDragOffset: CGFloat
    let onToggleControls: () -> Void
    /// 下拉过阈值进入 mini
    let onMini: () -> Void

    @State private var dragMode: DragMode?
    @State private var seekBase: TimeInterval = 0
    @State private var seekTarget: TimeInterval = 0
    @State private var gestureStartVolume: Float = 0
    @State private var gestureStartBrightness: CGFloat = 0
    @State private var rateBeforeLongPress: Float?
    @State private var hideTask: Task<Void, Never>?

    private enum DragMode { case seek, volume, brightness, mini }

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .gesture(dragGesture(in: geometry.size))
                .onTapGesture(count: 2) { point in
                    handleDoubleTap(at: point, in: geometry.size)
                }
                .onTapGesture(count: 1) {
                    onToggleControls()
                }
                .onLongPressGesture(minimumDuration: 0.5) {
                } onPressingChanged: { pressing in
                    handleLongPress(pressing)
                }
        }
    }

    // MARK: - 拖动手势（进度 / 音量 / 亮度）

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if dragMode == nil {
                    if abs(value.translation.width) > abs(value.translation.height) {
                        dragMode = .seek
                        seekBase = core.currentTime
                        seekTarget = core.currentTime
                    } else {
                        let third = size.width / 3
                        if value.startLocation.x < third {
                            dragMode = .brightness
                            gestureStartBrightness = UIScreen.main.brightness
                        } else if value.startLocation.x > third * 2 {
                            dragMode = .volume
                            gestureStartVolume = SystemVolume.current
                        } else {
                            dragMode = .mini   // 画面中央下拉进入 mini
                        }
                    }
                }
                switch dragMode {
                case .seek:
                    guard core.duration > 0 else { return }
                    let ratio = value.translation.width / max(size.width, 1)
                    seekTarget = min(max(0, seekBase + core.duration * ratio), core.duration)
                    show(.seek(target: seekTarget, duration: core.duration))
                case .volume:
                    let delta = Float(-value.translation.height / max(size.height, 1))
                    let stepped = ((gestureStartVolume + delta) / 0.05).rounded() * 0.05   // 步进 5%
                    let clamped = min(max(stepped, 0), 1)
                    SystemVolume.set(clamped)
                    show(.volume(percent: Int((clamped * 100).rounded())))
                case .brightness:
                    let delta = -value.translation.height / max(size.height, 1)
                    let brightness = min(max(gestureStartBrightness + delta, 0), 1)
                    UIScreen.main.brightness = brightness
                    show(.brightness(percent: Int((brightness * 100).rounded())))
                case .mini:
                    miniDragOffset = max(0, value.translation.height)
                case nil:
                    break
                }
            }
            .onEnded { _ in
                switch dragMode {
                case .seek:
                    core.seek(to: seekTarget)
                    hideFeedbackLater()
                case .mini:
                    if miniDragOffset > 120 {
                        onMini()
                    }
                    withAnimation(.appQuick) { miniDragOffset = 0 }
                default:
                    hideFeedbackLater()
                }
                dragMode = nil
            }
    }

    // MARK: - 双击 / 长按

    private func handleDoubleTap(at point: CGPoint, in size: CGSize) {
        let step = AppSettings.Player.seekStepSeconds
        if point.x < size.width / 3 {
            core.seek(by: -step)
            show(.jump(seconds: -step))
        } else if point.x > size.width * 2 / 3 {
            core.seek(by: step)
            show(.jump(seconds: step))
        } else {
            core.togglePlayPause()
            return
        }
        hideFeedbackLater()
    }

    private func handleLongPress(_ pressing: Bool) {
        if pressing {
            rateBeforeLongPress = core.rate
            core.setRate(2.0)
            show(.speed(rate: 2.0))
        } else if let rate = rateBeforeLongPress {
            core.setRate(rate)
            rateBeforeLongPress = nil
            hideFeedbackLater()
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
        case .jump(let seconds): return seconds >= 0 ? "goforward" : "gobackward"
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
        case .jump(let seconds):
            return String(format: "%+ds", Int(seconds))
        }
    }
}
