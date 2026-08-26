import SwiftUI
import UIKit

// MARK: - 菜单项

/// 弹出菜单项
struct PopupMenuItem: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String?
    let destructive: Bool
    let action: () -> Void

    init(title: String, systemImage: String? = nil, destructive: Bool = false, action: @escaping () -> Void = {}) {
        self.title = title
        self.systemImage = systemImage
        self.destructive = destructive
        self.action = action
    }
}

// MARK: - 全局菜单呈现器

/// 统一弹出菜单入口（TODO §1.1）：… 菜单 / 长按菜单 / 右键菜单（iPad·Mac 指针）
/// 由 RootView 顶层悬浮层承载；长按走底部抽屉，… 按钮 / 指针右键走锚点圆角卡片。
final class PopupMenuPresenter: ObservableObject {
    /// 菜单呈现样式
    enum Style {
        case popover   // 锚点圆角卡片：… 按钮 / iPad·Mac 指针右键
        case drawer    // 底部抽屉：iOS 长按（参照 Flutter showModalBottomSheet）
    }

    struct State {
        var items: [PopupMenuItem]
        var anchor: CGRect   // 触发视图的全局坐标（popover 定位用）
        var style: Style
    }

    @Published var state: State?

    func show(items: [PopupMenuItem], anchor: CGRect = .zero, style: Style = .popover) {
        state = State(items: items, anchor: anchor, style: style)
    }

    func dismiss() {
        state = nil
    }
}

// MARK: - 菜单悬浮层

/// 圆角菜单卡片 + 精致弹出动画（缩放 + 淡入，≤ 200ms），点击空白关闭。
struct PopupMenuLayer: View {
    let state: PopupMenuPresenter.State
    let onDismiss: () -> Void

    @State private var visible = false

    private let cardWidth: CGFloat = 220
    private let rowHeight: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }

                card
                    .frame(width: cardWidth)
                    .position(position(in: geo.size))
                    .scaleEffect(visible ? 1 : 0.85, anchor: .topTrailing)
                    .opacity(visible ? 1 : 0)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.appQuick) { visible = true }
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            ForEach(state.items) { item in
                Button {
                    dismiss()
                    item.action()
                } label: {
                    HStack(spacing: 10) {
                        if let icon = item.systemImage {
                            Image(systemName: icon)
                                .frame(width: 18)
                        }
                        Text(item.title)
                            .font(.subheadline)
                        Spacer()
                    }
                    .foregroundStyle(item.destructive ? Color.red : AppColors.textPrimary)
                    .padding(.horizontal, 14)
                    .frame(height: rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressScale)

                if item.id != state.items.last?.id {
                    Divider()
                        .overlay(AppColors.separator)
                        .padding(.leading, 14)
                }
            }
        }
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppColors.separator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    }

    /// 默认显示在锚点右下方，贴边时向内收 / 翻转到上方
    private func position(in size: CGSize) -> CGPoint {
        let estimatedHeight = CGFloat(state.items.count) * rowHeight
        var x = state.anchor.maxX - 8 - cardWidth / 2
        x = min(x, size.width - cardWidth / 2 - 12)
        x = max(x, cardWidth / 2 + 12)
        var y = state.anchor.maxY + 8 + estimatedHeight / 2
        if y + estimatedHeight / 2 > size.height - 12 {
            y = state.anchor.minY - 8 - estimatedHeight / 2
        }
        y = max(y, estimatedHeight / 2 + 12)
        return CGPoint(x: x, y: y)
    }

    private func dismiss() {
        withAnimation(.appQuick) { visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            onDismiss()
        }
    }
}

// MARK: - 底部抽屉菜单

/// 底部滑出抽屉式菜单（参照 Flutter showModalBottomSheet，iOS 长按统一入口）：
/// 顶部拖拽把手（可下拉关闭）+ 可滚动列表（超高时内部滚动）+ 点击蒙层关闭；
/// iPad 上限宽居中，圆角顶边，与全局菜单同一悬浮层承载。
struct BottomMenuDrawer: View {
    let items: [PopupMenuItem]
    let onDismiss: () -> Void

    @State private var visible = false
    @State private var dragOffset: CGFloat = 0

    private let rowHeight: CGFloat = 50
    private let handleHeight: CGFloat = 26   // 把手区（5 + 上 8 + 下 13）
    private let bottomPadding: CGFloat = 8
    private let maxHeightRatio: CGFloat = 0.75
    private let cornerRadius: CGFloat = 16
    private let maxWidth: CGFloat = 520      // iPad 限宽居中

    var body: some View {
        GeometryReader { geo in
            let height = drawerHeight(in: geo)
            ZStack(alignment: .bottom) {
                Color.black.opacity(visible ? 0.35 : 0)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }

                VStack(spacing: 0) {
                    // 拖拽把手（参照 Flutter showDragHandle，下拉关闭）
                    Capsule()
                        .fill(AppColors.textSecondary.opacity(0.35))
                        .frame(width: 36, height: 5)
                        .padding(.top, 8)
                        .padding(.bottom, 13)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .gesture(dragToDismiss)

                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(items) { item in
                                Button {
                                    dismiss()
                                    item.action()
                                } label: {
                                    HStack(spacing: 14) {
                                        if let icon = item.systemImage {
                                            Image(systemName: icon)
                                                .font(.system(size: 17))
                                                .frame(width: 24)
                                        }
                                        Text(item.title)
                                            .font(.body)
                                        Spacer()
                                    }
                                    .foregroundStyle(item.destructive ? Color.red : AppColors.textPrimary)
                                    .padding(.horizontal, 20)
                                    .frame(height: rowHeight)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(DrawerRowStyle())
                            }
                        }
                    }

                    Color.clear.frame(height: bottomPadding)
                }
                .frame(height: height)
                .frame(maxWidth: maxWidth)
                .background(AppColors.cardBackground)
                .clipShape(UnevenRoundedRectangle(
                    topLeadingRadius: cornerRadius,
                    topTrailingRadius: cornerRadius,
                    style: .continuous
                ))
                .shadow(color: .black.opacity(0.15), radius: 16, y: -4)
                .frame(maxWidth: .infinity)   // iPad 限宽后居中
                .offset(y: visible ? max(0, dragOffset) : height)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.appQuick) { visible = true }
        }
    }

    /// 抽屉高度：把手 + 列表 + 底部留白 + Home 指示条区；超过上限时列表内部滚动
    private func drawerHeight(in geo: GeometryProxy) -> CGFloat {
        let content = handleHeight + CGFloat(items.count) * rowHeight + bottomPadding + geo.safeAreaInsets.bottom
        return min(content, geo.size.height * maxHeightRatio)
    }

    private var dragToDismiss: some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                if value.translation.height > 80 || value.predictedEndTranslation.height > 160 {
                    dismiss()
                } else {
                    withAnimation(.appFast) { dragOffset = 0 }
                }
            }
    }

    private func dismiss() {
        withAnimation(.appQuick) { visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            onDismiss()
        }
    }
}

/// 抽屉菜单行按压样式：浅蓝高亮（与单元格按压视觉一致）
private struct DrawerRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? AppColors.primary.opacity(0.10) : Color.clear)
    }
}

// MARK: - 触发组件

/// 「…」触发按钮：记录自身全局位置并弹出圆角菜单；symbol 可定制（默认「…」）
struct PopupMenuButton: View {
    let items: [PopupMenuItem]
    var symbol: String = "ellipsis"

    @EnvironmentObject private var presenter: PopupMenuPresenter
    @State private var anchor: CGRect = .zero

    var body: some View {
        Button {
            presenter.show(items: items, anchor: anchor)
        } label: {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressScale)
        .background(AnchorReader(anchor: $anchor))
    }
}

/// 读取视图全局坐标
private struct AnchorReader: View {
    @Binding var anchor: CGRect

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { anchor = geo.frame(in: .global) }
                .onChange(of: geo.frame(in: .global)) { anchor = $0 }
        }
    }
}

private struct PopupContextMenuModifier: ViewModifier {
    let items: [PopupMenuItem]

    @EnvironmentObject private var presenter: PopupMenuPresenter
    @State private var anchor: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .background(AnchorReader(anchor: $anchor))
            .onLongPressGesture(minimumDuration: 0.5) {
                presenter.show(items: items, anchor: anchor, style: .drawer)
            }
            .background(SecondaryClickBridge {
                presenter.show(items: items, anchor: anchor)
            })
    }
}

extension View {
    /// 长按（iOS，底部抽屉）/ 指针右键（iPad·Mac，锚点卡片）弹出操作菜单
    func popupContextMenu(_ items: [PopupMenuItem]) -> some View {
        modifier(PopupContextMenuModifier(items: items))
    }

    /// 仅指针右键（iPad·Mac）弹出锚点圆角菜单；iOS 长按请用 popupContextMenu（底部抽屉）
    func popupSecondaryMenu(_ items: [PopupMenuItem]) -> some View {
        modifier(PopupSecondaryMenuModifier(items: items))
    }
}

private struct PopupSecondaryMenuModifier: ViewModifier {
    let items: [PopupMenuItem]

    @EnvironmentObject private var presenter: PopupMenuPresenter
    @State private var anchor: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .background(AnchorReader(anchor: $anchor))
            .background(SecondaryClickBridge {
                presenter.show(items: items, anchor: anchor)
            })
    }
}

// MARK: - 单元格按压交互

/// 单元格按压交互（替代 Button：Button 内部手势会吞掉长按，导致长按菜单无法触发）：
/// - 点击 → onTap；长按 → 底部抽屉菜单（互斥：长按识别后松开不再触发点击）；
/// - 按压中内容缩放 0.97（保留按压反馈），高亮基于原始 frame 铺满整行/卡片，
///   缩放时不漏出直角空隙，与 hover/选中高亮保持一致；
/// - iPad/Mac 指针右键弹锚点圆角菜单（与长按同一组菜单项）。
private struct CellPressModifier: ViewModifier {
    var cornerRadius: CGFloat = 12
    let items: [PopupMenuItem]
    let onTap: () -> Void

    @EnvironmentObject private var presenter: PopupMenuPresenter
    @State private var isPressing = false
    @State private var anchor: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .background(AnchorReader(anchor: $anchor))
            // 先缩放内容（保留 0.97 按压反馈），高亮 overlay 叠加在其后：
            // 高亮基于原始 frame 铺满整行，内容缩放时不会漏出四周直角空隙
            .scaleEffect(isPressing ? 0.97 : 1)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isPressing ? AppColors.primary.opacity(0.12) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(PressBridge(
                onTap: onTap,
                onPressing: { pressing in
                    if pressing {
                        // 按下：瞬时切换（无动画），保证跟手；不用 easeOut 渐变，避免按下瞬间延迟
                        var transaction = Transaction()
                        transaction.animation = nil
                        withTransaction(transaction) { isPressing = true }
                    } else {
                        // 松开：动画平滑恢复
                        withAnimation(.appFast) { isPressing = false }
                    }
                },
                onLongPress: {
                    // 长按触发轻微震动（prepare 预唤醒触觉引擎，确保即时可靠触发）
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.prepare()
                    generator.impactOccurred()
                    presenter.show(items: items, anchor: anchor, style: .drawer)
                }
            ))
            .accessibilityAddTraits(.isButton)
            .background(SecondaryClickBridge {
                presenter.show(items: items, anchor: anchor)
            })
    }
}

extension View {
    /// 单元格交互：点击 + 长按弹底部抽屉菜单 + 指针右键弹锚点菜单（修复 Button 吞长按）
    func cellPressableMenu(
        cornerRadius: CGFloat = 12,
        items: [PopupMenuItem],
        onTap: @escaping () -> Void
    ) -> some View {
        modifier(CellPressModifier(
            cornerRadius: cornerRadius,
            items: items,
            onTap: onTap
        ))
    }
}

// MARK: - 按压桥接（点击 + 长按）

/// UIKit 桥接的「点击 + 长按」手势，替代 SwiftUI 的 `onTapGesture` + `LongPressGesture`。
///
/// SwiftUI 的 `LongPressGesture` 底层 `UILongPressGestureRecognizer` 默认
/// `delaysTouchesBegan = true`，在 ScrollView 内会延迟触摸事件传递，导致 iPhone
/// 真机手指滑动失效（滚动无法及时接管）；而 Mac 的 iPhone 镜像里触摸板滑动走的是
/// 滚轮/间接滚动事件、不经过触摸手势，所以能正常滚动——这正是「真机手指滑不动、
/// 镜像触摸板能滑」的根因。这里显式关闭 `delaysTouchesBegan` 与 `cancelsTouchesInView`，
/// 让长按不再干扰滚动。
private struct PressBridge: UIViewRepresentable {
    let onTap: () -> Void
    let onPressing: (Bool) -> Void
    let onLongPress: () -> Void

    func makeUIView(context: Context) -> PressBridgeView {
        PressBridgeView(onTap: onTap, onPressing: onPressing, onLongPress: onLongPress)
    }

    // 让桥接视图填满 cell（overlay 内容默认按自身理想大小居中，需显式铺满）
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PressBridgeView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

    func updateUIView(_ uiView: PressBridgeView, context: Context) {
        uiView.onTap = onTap
        uiView.onPressing = onPressing
        uiView.onLongPress = onLongPress
    }
}

private final class PressBridgeView: UIView {
    var onTap: () -> Void
    var onPressing: (Bool) -> Void
    var onLongPress: () -> Void

    private let longPress = UILongPressGestureRecognizer()

    init(onTap: @escaping () -> Void,
         onPressing: @escaping (Bool) -> Void,
         onLongPress: @escaping () -> Void) {
        self.onTap = onTap
        self.onPressing = onPressing
        self.onLongPress = onLongPress
        super.init(frame: .zero)
        isUserInteractionEnabled = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        longPress.minimumPressDuration = 0.5
        longPress.delaysTouchesBegan = false       // 关键：不延迟触摸传递，保证滚动流畅
        longPress.cancelsTouchesInView = false
        longPress.allowableMovement = 10
        longPress.addTarget(self, action: #selector(handleLongPress))
        tap.require(toFail: longPress)             // 长按成功则抑制点击，二者互斥
        addGestureRecognizer(tap)
        addGestureRecognizer(longPress)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        if recognizer.state == .ended { onTap() }
    }

    // 手指按下立即进入按压态（高亮 + 缩放跟手），不等长按阈值；
    // 抬起 / 取消（滚动接管）时复位。长按菜单仍由 longPress 的 .began（0.5s）触发，职责分离。
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        onPressing(true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        onPressing(false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        onPressing(false)
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            onLongPress()          // 达到长按阈值触发菜单，不等松手
        case .ended, .cancelled, .failed:
            onPressing(false)      // 兜底复位：长按后松手 / 移动超限 / 被取消
        default:
            break
        }
    }
}

// MARK: - 右键桥接

/// 窗口级 `.secondary`（右键）手势桥接：不拦截普通触摸，命中本视图区域时回调。
/// 供 iPad / Mac Catalyst 指针右键触发与长按一致的自定义菜单。
///
/// 实现为「每个 window 一个共享 recognizer」（见 SecondaryClickCoordinator），
/// 而不是每个单元格各挂一个 recognizer 到 window——后者在大目录下会随单元格
/// 出现/消失高频 add/remove，导致 window 上累积大量手势识别器、拖垮手势系统，
/// 表现为滚动滑动卡死（文件越少越正常）。
private struct SecondaryClickBridge: UIViewRepresentable {
    let onSecondaryClick: () -> Void

    func makeUIView(context: Context) -> SecondaryClickBridgeView {
        SecondaryClickBridgeView(onSecondaryClick: onSecondaryClick)
    }

    func updateUIView(_ uiView: SecondaryClickBridgeView, context: Context) {
        uiView.onSecondaryClick = onSecondaryClick
    }
}

private final class SecondaryClickBridgeView: UIView {
    var onSecondaryClick: () -> Void
    private weak var registeredWindow: UIWindow?

    init(onSecondaryClick: @escaping () -> Void) {
        self.onSecondaryClick = onSecondaryClick
        super.init(frame: .zero)
        isUserInteractionEnabled = false   // 不参与命中测试，右键命中由共享 recognizer 派发
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let registeredWindow {
            SecondaryClickCoordinator.shared.unregister(self, from: registeredWindow)
            self.registeredWindow = nil
        }
        guard let window, Self.supportsPointer else { return }
        SecondaryClickCoordinator.shared.register(self, in: window)
        registeredWindow = window
    }

    /// 仅指针设备支持右键；iPhone 无 secondary button，跳过挂载以省去无谓开销
    private static var supportsPointer: Bool {
        UIDevice.current.userInterfaceIdiom == .pad || ProcessInfo.processInfo.isiOSAppOnMac
    }
}

/// 每个 window 只挂一个右键 recognizer，弱引用所有桥接视图，命中后按坐标派发。
private final class SecondaryClickCoordinator: NSObject {
    static let shared = SecondaryClickCoordinator()

    private var recognizerByWindow: [ObjectIdentifier: UITapGestureRecognizer] = [:]
    private var targetsByWindow: [ObjectIdentifier: NSHashTable<SecondaryClickBridgeView>] = [:]

    func register(_ view: SecondaryClickBridgeView, in window: UIWindow) {
        let key = ObjectIdentifier(window)

        if targetsByWindow[key] == nil {
            targetsByWindow[key] = NSHashTable<SecondaryClickBridgeView>.weakObjects()
        }
        targetsByWindow[key]?.add(view)

        if recognizerByWindow[key] == nil {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleSecondary(_:)))
            recognizer.buttonMaskRequired = .secondary
            recognizer.cancelsTouchesInView = false
            window.addGestureRecognizer(recognizer)
            recognizerByWindow[key] = recognizer
        }
    }

    func unregister(_ view: SecondaryClickBridgeView, from window: UIWindow) {
        targetsByWindow[ObjectIdentifier(window)]?.remove(view)
    }

    @objc private func handleSecondary(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let window = recognizer.view as? UIWindow else { return }
        let location = recognizer.location(in: nil)
        let targets = targetsByWindow[ObjectIdentifier(window)]?.allObjects ?? []
        for case let view as SecondaryClickBridgeView in targets {
            let point = view.convert(location, from: window)
            if view.bounds.contains(point) {
                view.onSecondaryClick()
                break
            }
        }
    }
}
