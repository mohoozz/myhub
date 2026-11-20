import SwiftUI
import UIKit

// MARK: - 阅读器左滑退出（fullScreenCover 无系统侧滑返回，补一个屏幕左边缘右滑手势）

/// 阅读器左边缘右滑退出手势桥接。
struct EdgeSwipeBack: UIViewRepresentable {
    let onChanged: (CGFloat) -> Void
    /// 松手回调：（横向位移，横向速度 pt/s）
    let onEnded: (CGFloat, CGFloat) -> Void

    func makeUIView(context: Context) -> EdgeSwipeBackView {
        let view = EdgeSwipeBackView()
        view.onChanged = onChanged
        view.onEnded = onEnded
        return view
    }

    func updateUIView(_ view: EdgeSwipeBackView, context: Context) {
        view.onChanged = onChanged
        view.onEnded = onEnded
    }
}

/// 左滑退出手势宿主。自身不参与布局与命中测试（交互全部穿透）
final class EdgeSwipeBackView: UIView, UIGestureRecognizerDelegate {
    var onChanged: ((CGFloat) -> Void)?
    var onEnded: ((CGFloat, CGFloat) -> Void)?

    private weak var edgeGesture: UIScreenEdgePanGestureRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false // 自身不拦截任何触摸，交互全部穿透给正文
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window {
            guard edgeGesture == nil else { return }
            let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handle(_:)))
            edge.edges = .left
            edge.delegate = self
            window.addGestureRecognizer(edge)
            edgeGesture = edge
        } else if let edge = edgeGesture {
            // 阅读器 dismiss：从旧 window 移除手势，避免残留影响其它界面
            edge.view?.removeGestureRecognizer(edge)
            edgeGesture = nil
        }
    }

    @objc private func handle(_ g: UIScreenEdgePanGestureRecognizer) {
        let translation = g.translation(in: g.view).x
        switch g.state {
        case .began, .changed:
            onChanged?(max(0, translation))
        case .ended, .cancelled, .failed:
            onEnded?(max(0, translation), g.velocity(in: g.view).x)
        default:
            break
        }
    }

    // 允许与缩放/点击等手势并存，保证边缘右滑一定能被捕获
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        !(other.view is UIScrollView)
    }

    // 边缘手势必须先失败、滚动视图的 pan 才能识别（方向与系统侧滑返回一致）
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        other.view is UIScrollView
    }
}
