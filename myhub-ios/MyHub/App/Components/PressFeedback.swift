import SwiftUI
import UIKit

// MARK: - 按压视觉闸门

/// 按压视觉闸门：保证「快速单点」也能看到完整的按下 → 回弹动画。
struct PressVisualGate<Content: View>: View {
    /// 外部真实按压信号
    let isPressed: Bool
    /// 按压态最短可见时长（快速单点的保底）
    var minimumDuration: Double = PressFeedback.minimumVisibleDuration
    /// 回弹动画
    var releaseAnimation: Animation = .appFast
    /// 以「视觉按压态」渲染内容
    @ViewBuilder let content: (Bool) -> Content

    @State private var visuallyPressed = false
    @State private var pressedAt = Date.distantPast
    @State private var pendingRelease: DispatchWorkItem?

    var body: some View {
        content(visuallyPressed)
            .onChange(of: isPressed) { pressed in apply(pressed) }
            .onAppear { if isPressed { apply(true) } }
            .onDisappear {
                pendingRelease?.cancel()
                pendingRelease = nil
            }
    }

    private func apply(_ pressed: Bool) {
        pendingRelease?.cancel()
        pendingRelease = nil
        if pressed {
            pressedAt = Date()
            // 按下：瞬时切换（无动画），保证跟手
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) { visuallyPressed = true }
        } else {
            // 抬起：按压态可见时长不足则补足再回弹，保证动画完整播放
            let remaining = minimumDuration - Date().timeIntervalSince(pressedAt)
            guard remaining > 0 else {
                withAnimation(releaseAnimation) { visuallyPressed = false }
                return
            }
            let work = DispatchWorkItem {
                withAnimation(releaseAnimation) { visuallyPressed = false }
            }
            pendingRelease = work
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
        }
    }
}

/// 按压态最短可见时长（全局统一）
enum PressFeedback {
    static let minimumVisibleDuration: Double = 0.12
}

// MARK: - UIKit 触摸驱动的按压状态

/// 按压阶段
/// - `began` 手指落下 → 立即点亮（跟手）
enum PressPhase {
    case began
    case ended
    case cancelled
}

/// UIKit 触摸桥接的按压视觉状态（与 `PressVisualGate` 同策略，供 UIViewRepresentable 驱动）
final class PressStateHolder: ObservableObject {
    @Published private(set) var isPressing = false

    /// 按压态最短可见时长（快速单点的保底）
    var minimumDuration: Double = PressFeedback.minimumVisibleDuration
    /// 回弹动画
    var releaseAnimation: Animation = .appFast

    private var pressedAt = Date.distantPast
    private var pendingRelease: DispatchWorkItem?

    func handle(_ phase: PressPhase) {
        pendingRelease?.cancel()
        pendingRelease = nil
        switch phase {
        case .began:
            pressedAt = Date()
            // 按下：瞬时切换（无动画），保证跟手
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) { isPressing = true }
        case .cancelled:
            release()
        case .ended:
            let remaining = minimumDuration - Date().timeIntervalSince(pressedAt)
            guard remaining > 0 else { return release() }
            let work = DispatchWorkItem { [weak self] in self?.release() }
            pendingRelease = work
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
        }
    }

    private func release() {
        guard isPressing else { return }
        withAnimation(releaseAnimation) { isPressing = false }
    }
}

// MARK: - 滚动容器触摸延迟

/// 关闭最近祖先 `UIScrollView` 的 `delaysContentTouches`。
struct ScrollTouchDelayDisabler: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { TouchDelayDisablerView() }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// 向上查找最近的滚动容器并关闭触摸延迟（工具方法，供 UIKit 桥接视图复用）
func disableTouchDelayInEnclosingScrollView(of view: UIView) {
    var current: UIView? = view.superview
    while let candidate = current {
        if let scrollView = candidate as? UIScrollView {
            scrollView.delaysContentTouches = false
            return
        }
        current = candidate.superview
    }
}

private final class TouchDelayDisablerView: UIView {
    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        disableTouchDelayInEnclosingScrollView(of: self)
    }
}

extension View {
    /// 让所在滚动容器立即下发触摸，消除按压反馈的 ~150ms 延迟
    func instantPressInScrollView() -> some View {
        background(ScrollTouchDelayDisabler().allowsHitTesting(false))
    }
}
