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
/// - 按压中浅蓝高亮 + 缩放 0.97（与原 SelectableCellStyle 视觉一致）；
/// - iPad/Mac 指针右键弹锚点圆角菜单（与长按同一组菜单项）。
private struct CellPressModifier: ViewModifier {
    var cornerRadius: CGFloat = 12
    let items: [PopupMenuItem]
    let onTap: () -> Void

    @EnvironmentObject private var presenter: PopupMenuPresenter
    @GestureState private var isPressing = false
    @State private var anchor: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .background(AnchorReader(anchor: $anchor))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isPressing ? AppColors.primary.opacity(0.12) : Color.clear)
            )
            .scaleEffect(isPressing ? 0.97 : 1)
            .animation(.appFast, value: isPressing)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onTapGesture { onTap() }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5)
                    .updating($isPressing) { value, state, _ in state = value }
                    .onEnded { _ in
                        presenter.show(items: items, anchor: anchor, style: .drawer)
                    }
            )
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

// MARK: - 右键桥接

/// 窗口级 `.secondary`（右键）手势桥接：不拦截普通触摸，命中本视图区域时回调。
/// 供 iPad / Mac Catalyst 指针右键触发与长按一致的自定义菜单。
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
    private weak var recognizer: UITapGestureRecognizer?

    init(onSecondaryClick: @escaping () -> Void) {
        self.onSecondaryClick = onSecondaryClick
        super.init(frame: .zero)
        isUserInteractionEnabled = false   // 不参与命中测试，手势挂在 window 上
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let recognizer {
            recognizer.view?.removeGestureRecognizer(recognizer)
            self.recognizer = nil
        }
        guard let window else { return }
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleSecondary(_:)))
        recognizer.buttonMaskRequired = .secondary
        recognizer.cancelsTouchesInView = false
        window.addGestureRecognizer(recognizer)
        self.recognizer = recognizer
    }

    @objc private func handleSecondary(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let location = recognizer.location(in: self)
        if bounds.contains(location) {
            onSecondaryClick()
        }
    }
}
