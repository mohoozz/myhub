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
/// 复用同一圆角卡片与弹出动画，由 RootView 顶层悬浮层承载。
final class PopupMenuPresenter: ObservableObject {
    struct State {
        var items: [PopupMenuItem]
        var anchor: CGRect   // 触发视图的全局坐标
    }

    @Published var state: State?

    func show(items: [PopupMenuItem], anchor: CGRect) {
        state = State(items: items, anchor: anchor)
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
                presenter.show(items: items, anchor: anchor)
            }
            .background(SecondaryClickBridge {
                presenter.show(items: items, anchor: anchor)
            })
    }
}

extension View {
    /// 长按（iOS）/ 指针右键（iPad·Mac）弹出圆角菜单，与「…」按钮同一组件
    func popupContextMenu(_ items: [PopupMenuItem]) -> some View {
        modifier(PopupContextMenuModifier(items: items))
    }

    /// 仅指针右键（iPad·Mac）弹出圆角菜单；iOS 长按留给多选模式（TODO §3.2）
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
