import SwiftUI
import UIKit

// MARK: - 阅读器左滑退出（fullScreenCover 无系统侧滑返回，补一个屏幕左边缘右滑手势）

/// 阅读器左边缘右滑退出手势桥接。
/// 阅读器经 `.fullScreenCover` 呈现（模态，非 NavigationStack push），没有系统侧滑返回手势。
/// 这里把 `UIScreenEdgePanGestureRecognizer` 挂到承载视图所在的 **window** 上：
/// - window 位于整个视图层级最外层，SwiftUI 内部（TabView 翻页 / ScrollView 滚动）的手势
///   无法将其吞掉，从根本上解决「窄条 overlay 上的边缘手势被内层滚动手势抢占而无法触发」的问题；
/// - `edges = .left` 由系统保证仅屏幕左边缘起手才识别，不影响正文任意区域的翻页/滚动/点击；
/// - 允许与其它手势同时识别（simultaneous），确保边缘右滑一定能被捕获。
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

/// 左滑退出手势宿主。自身不参与布局与命中测试（交互全部穿透），
/// 仅负责在挂载到 window 时把屏幕左边缘手势注册到 window、在移除时清理，避免泄漏到其它界面。
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

    // 允许与缩放/点击等手势并存，保证边缘右滑一定能被捕获；
    // 但与滚动视图（ScrollView/TabView 翻页）的 pan 不同时识别 —— 配合下面的失败依赖，
    // 一旦左缘右滑退出开始，正文不再跟着上下滚动（避免斜拖抖动）
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        !(other.view is UIScrollView)
    }

    // 边缘手势必须先失败、滚动视图的 pan 才能识别（方向与系统侧滑返回一致）：
    // 非左缘起手时边缘手势立即失败，正常滚动无任何延迟；
    // 左缘垂直下滑也会让边缘手势快速失败后正常滚动
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        other.view is UIScrollView
    }
}
