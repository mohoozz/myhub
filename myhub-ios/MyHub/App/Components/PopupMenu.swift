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

/// 统一弹出菜单入口：… 菜单 / 长按菜单 / 右键菜单（iPad·Mac 指针）
final class PopupMenuPresenter: ObservableObject {
    /// 菜单呈现样式
    enum Style {
        case popover   // 锚点圆角卡片：仅 iPad·Mac 指针右键
        case drawer    // 底部抽屉：iOS 长按 / 右上角 + 与 …（参照 Flutter showModalBottomSheet）
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
                    dismiss(item.action)
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
                    .foregroundStyle(item.destructive ? AppColors.destructive : AppColors.textPrimary)
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

    /// 关闭菜单：先播退出动画，动画结束后移除悬浮层并执行可选动作。
    private func dismiss(_ action: (() -> Void)? = nil) {
        withAnimation(.appQuick) { visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            onDismiss()
            action?()
        }
    }
}

// MARK: - 底部抽屉菜单

/// 底部滑出抽屉式菜单（参照 Flutter showModalBottomSheet，iOS 长按统一入口）
struct BottomMenuDrawer: View {
    let items: [PopupMenuItem]
    let onDismiss: () -> Void

    @State private var visible = false
    @State private var dragOffset: CGFloat = 0

    private let rowHeight: CGFloat = 50
    private let handleHeight: CGFloat = 26   // 把手区（5 + 上 8 + 下 13）
    private let bottomPadding: CGFloat = 12
    private let maxHeightRatio: CGFloat = 0.75
    private let cornerRadius: CGFloat = 16
    private let maxWidth: CGFloat = 520      // iPad 限宽居中

    /// 底部安全区高度（Home 指示条）
    private var bottomInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .windows.first(where: { $0.isKeyWindow })?
            .safeAreaInsets.bottom ?? 0
    }

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
                                    dismiss(item.action)
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
                                    .foregroundStyle(item.destructive ? AppColors.destructive : AppColors.textPrimary)
                                    .padding(.horizontal, 20)
                                    .frame(height: rowHeight)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(DrawerRowStyle())
                            }
                        }
                    }

                    Color.clear.frame(height: bottomPadding + bottomInset)
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
        let content = handleHeight + CGFloat(items.count) * rowHeight + bottomPadding + bottomInset
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

    /// 关闭菜单：先播退出动画，动画结束后移除悬浮层并执行可选动作。
    private func dismiss(_ action: (() -> Void)? = nil) {
        withAnimation(.appQuick) { visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            onDismiss()
            action?()
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

/// 「…」触发按钮：记录自身全局位置并弹出底部抽屉菜单（与长按文件菜单一致）
struct PopupMenuButton: View {
    let items: [PopupMenuItem]
    var symbol: String = "ellipsis"
    var style: PopupMenuPresenter.Style = .drawer
    /// 触控格尺寸：默认 32pt（导航栏内沿用原尺寸）
    var size: CGSize = CGSize(width: 32, height: 32)

    @EnvironmentObject private var presenter: PopupMenuPresenter
    @StateObject private var press = PressStateHolder()
    @State private var anchorBox = AnchorBox()

    var body: some View {
        Image(systemName: symbol)
            .font(.body.weight(.medium))
            .foregroundStyle(.tint)
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .scaleEffect(press.isPressing ? 0.92 : 1)
            // 缩放只认 `press.isPressing` 这一个动画来源
            .animation(press.isPressing ? nil : Animation.appFast, value: press.isPressing)
            .background(AnchorReader(box: anchorBox))
            .overlay(PressBridge(
                onTap: { presenter.show(items: items, anchor: anchorBox.rect, style: style) },
                onPress: { press.handle($0) },
                onLongPress: {}
            ))
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(symbol == "plus" ? "添加" : "更多操作")
            // 避免 push/pop 时被当成插入/移除而「弹一下」
            .transition(.identity)
            .transaction { transaction in transaction.animation = nil }
    }
}

/// 放**导航栏 toolbar** 里的菜单触发按钮：**标准 `Button`**，不套 `PressBridge`。
struct ToolbarMenuButton: View {
    let items: [PopupMenuItem]
    var symbol: String = "ellipsis"
    var style: PopupMenuPresenter.Style = .drawer

    @EnvironmentObject private var presenter: PopupMenuPresenter
    /// 弹出锚点（全局坐标）：真 Button 拿不到 `PressBridge` 的触摸回调，改由背景读数
    @State private var anchorBox = AnchorBox()

    var body: some View {
        Button {
            presenter.show(items: items, anchor: anchorBox.rect, style: style)
        } label: {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
        }
        .background(AnchorReader(box: anchorBox))
        .accessibilityLabel(symbol == "plus" ? "添加" : "更多操作")
    }
}

// MARK: - 导航栏右上角按钮（UIKit 承载）

/// 右上角按钮改由 **UIKit** 装到页面的 `UINavigationItem` 上，与左上角系统返回按钮同一套机制。
struct NavigationBarTrailingButtons: UIViewControllerRepresentable {
    /// 一颗按钮：SF Symbol + 点按回调
    struct Item {
        let symbol: String
        let accessibilityLabel: String
        /// 点按回调；参数是按钮在**窗口**中的位置，供自绘菜单定位
        let action: (CGRect) -> Void

        init(symbol: String, accessibilityLabel: String, action: @escaping (CGRect) -> Void) {
            self.symbol = symbol
            self.accessibilityLabel = accessibilityLabel
            self.action = action
        }
    }

    let items: [Item]

    // 顺序：`items` 按**书写顺序**给（自左至右），栏内右起排列由 `Coordinator.apply` 负责倒排。

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> MountController {
        let controller = MountController()
        let coordinator = context.coordinator
        controller.install = { [weak controller] in
            guard let controller else { return }
            coordinator.apply(from: controller)
        }
        return controller
    }

    func updateUIViewController(_ controller: MountController, context: Context) {
        // 每次求值都刷新回调：菜单项内容随状态变化（排序 ✓ 标记、视图切换标题等）
        context.coordinator.items = items
        controller.install?()
    }

    /// 零交互挂载点：本身不显示任何东西，只为拿到「当前页面」的 `UINavigationItem`
    final class MountController: UIViewController {
        var install: (() -> Void)?

        override func loadView() {
            let view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            self.view = view
        }

        /// 转场动画开始前就把 item 装好——这正是与 `.toolbar` 的关键差别
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            install?()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            install?()
        }

        /// SwiftUI / 系统改写导航栏后自愈；`apply` 幂等，已在位时什么都不做
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            install?()
        }
    }

    final class Coordinator: NSObject {
        var items: [Item] = []

        private var installedSignature: String?
        private var installedBarItems: [UIBarButtonItem] = []
        /// 与 `installedBarItems` **同序**（右起），点按回调按它取
        private var installedItems: [Item] = []
        /// 认领 item 实体视图（菜单锚点）用；页面变化时随之刷新
        private weak var navigationBar: UINavigationBar?

        /// 幂等安装：内容不变且 item 在位时什么都不做
        func apply(from host: UIViewController) {
            guard let page = Self.pageController(from: host) else {
                AppLogger.shared.log("右上角按钮：找不到页面导航项（挂载点还没接上）", level: .debug, module: "navbar")
                return
            }
            let navigationItem = page.navigationItem
            navigationBar = page.navigationController?.navigationBar

            let current = navigationItem.rightBarButtonItems ?? []
            let oursInPlace = !installedBarItems.isEmpty
                && current.count == installedBarItems.count
                && zip(current, installedBarItems).allSatisfy { $0.0 === $0.1 }
            let signature = items.map(\.symbol).joined(separator: "|")

            if oursInPlace, signature == installedSignature { return }

            // 记录重装原因（重装即等同一次插入，是排查重点）
            let reason: String
            if installedBarItems.isEmpty {
                reason = "首次安装"
            } else if !oursInPlace {
                reason = "item 被清掉（当前 \(current.count) 项）后重装"
            } else {
                reason = "内容变化（\(installedSignature ?? "-") → \(signature)）"
            }

            let ordered = Array(items.reversed())
            let barItems = ordered.map(makeBarItem)
            installedSignature = signature
            installedItems = ordered
            installedBarItems = barItems

            AppLogger.shared.log(
                "右上角按钮：\(reason)；\(Self.state(of: host))",
                level: .debug,
                module: "navbar"
            )

            // 关闭隐式动画，避免重装演成「插入」
            UIView.performWithoutAnimation {
                navigationItem.setRightBarButtonItems(barItems.isEmpty ? nil : barItems, animated: false)
            }
        }

        /// 诊断用：安装发生在转场的哪个阶段（是否已在转场中 / 视图是否已上屏）
        private static func state(of host: UIViewController) -> String {
            let inTransition = {
                var controller: UIViewController? = host
                while let current = controller {
                    if let navigation = current.navigationController,
                       navigation.transitionCoordinator != nil {
                        return true
                    }
                    if current.transitionCoordinator != nil { return true }
                    controller = current.parent
                }
                return false
            }()
            return "转场中=\(inTransition) 已上屏=\(host.viewIfLoaded?.window != nil) 已出现=\(host.isViewLoaded)"
        }

        /// 标准 item：图标、尺寸、玻璃胶囊全交给 `UIBarButtonItem` 自己——与返回按钮同一套东西
        private func makeBarItem(_ item: Item) -> UIBarButtonItem {
            // 图自带颜色，不继承导航栏 tint
            let image = UIImage(
                systemName: item.symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
            )?.withTintColor(AppColors.primaryUIColor, renderingMode: .alwaysOriginal)

            let barItem = UIBarButtonItem(
                image: image,
                style: .plain,
                target: self,
                action: #selector(handleTap(_:))
            )
            barItem.accessibilityLabel = item.accessibilityLabel
            return barItem
        }

        @objc private func handleTap(_ sender: UIBarButtonItem) {
            guard let index = installedBarItems.firstIndex(where: { $0 === sender }),
                  installedItems.indices.contains(index) else { return }
            let item = installedItems[index]
            item.action(anchorRect(of: sender, label: item.accessibilityLabel))
        }

        /// 自绘菜单的锚点：`UIBarButtonItem` 不暴露它的 view，只能按无障碍标签在导航栏子树里认领
        private func anchorRect(of barItem: UIBarButtonItem, label: String) -> CGRect {
            if let navigationBar {
                var queue: [UIView] = [navigationBar]
                while let view = queue.popLast() {
                    if let control = view as? UIControl,
                       control.accessibilityLabel == label,
                       control.window != nil {
                        return control.convert(control.bounds, to: nil)
                    }
                    queue.append(contentsOf: view.subviews)
                }
                AppLogger.shared.log("菜单锚点：认不到「\(label)」的实体视图，退回导航栏右侧", level: .debug, module: "navbar")
                return navigationBar.convert(navigationBar.bounds, to: nil)
            }
            return .zero
        }

        /// 「当前页面」：从挂载点向上找第一个直接受导航控制器管理的控制器
        private static func pageController(from host: UIViewController) -> UIViewController? {
            var current: UIViewController? = host
            while let controller = current {
                if let navigation = controller.navigationController,
                   navigation.viewControllers.contains(controller) {
                    return controller
                }
                current = controller.parent
            }
            return nil
        }
    }
}

/// 弹出锚点：只在「按下 / 长按 / 右键的那一刻」读一次的值，**故意不是 SwiftUI 状态**。
final class AnchorBox {
    var rect: CGRect = .zero
}

/// 读取视图全局坐标写入 `box`（写入不是状态变更，见 `AnchorBox`）
private struct AnchorReader: View {
    let box: AnchorBox

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { box.rect = geo.frame(in: .global) }
                .onChange(of: geo.frame(in: .global)) { box.rect = $0 }
        }
        // 纯测量层，不参与命中
        .allowsHitTesting(false)
    }
}

private struct PopupContextMenuModifier: ViewModifier {
    let items: [PopupMenuItem]

    @EnvironmentObject private var presenter: PopupMenuPresenter
    @State private var anchorBox = AnchorBox()

    func body(content: Content) -> some View {
        content
            .background(AnchorReader(box: anchorBox))
            .onLongPressGesture(minimumDuration: 0.5) {
                presenter.show(items: items, anchor: anchorBox.rect, style: .drawer)
            }
            .background(SecondaryClickBridge {
                presenter.show(items: items, anchor: anchorBox.rect)
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
    @State private var anchorBox = AnchorBox()

    func body(content: Content) -> some View {
        content
            .background(AnchorReader(box: anchorBox))
            .background(SecondaryClickBridge {
                presenter.show(items: items, anchor: anchorBox.rect)
            })
    }
}

// MARK: - 单元格按压交互

/// 单元格按压高亮形状
enum CellPressHighlightShape {
    /// 圆角矩形（默认，铺满整行/卡片）
    case roundedRect
    /// 圆形（取卡片短边为直径，居中显示）
    case circle
}

/// 单元格按压/选中交互（替代 Button：Button 内部手势会吞掉长按，导致长按菜单无法触发）
private struct CellPressModifier: ViewModifier {
    var cornerRadius: CGFloat = 12
    let highlightShape: CellPressHighlightShape
    /// 高亮块相对 cell 边缘的内缩（卡片 1pt 贴边；通栏列表行 4/6 收边成悬浮片）
    var highlightInset: EdgeInsets = EdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1)
    /// 选中浮起幅度（列表行 / 卡片各自微调）
    var selectedScale: CGFloat = 1.02
    /// 选中细描边色（深色封面卡可传更高对比度）
    var selectedStroke: Color = AppColors.primary.opacity(0.35)
    /// 多选选中态（由调用方下发）
    var isSelected: Bool = false
    let items: [PopupMenuItem]
    let onTap: () -> Void

    @EnvironmentObject private var presenter: PopupMenuPresenter
    /// 按压视觉状态：按下瞬时点亮，抬起补足最短可见时长再回弹（快速单点也能看到动画）
    @StateObject private var press = PressStateHolder()
    @State private var isHovering = false
    @State private var anchorBox = AnchorBox()
    /// 左滑操作桥接（由 `swipeActions` 注入；nil = 本行不支持左滑）
    @Environment(\.swipeRowBridge) private var swipeBridge

    private var isPressing: Bool { press.isPressing }

    /// 高亮块圆角：通栏列表行 cell 无圆角（0）时单独收一个具名圆角
    private var highlightRadius: CGFloat { cornerRadius > 0 ? cornerRadius : 11 }

    /// 缩放：按压回缩（跟手），选中浮起（持久）
    private var scale: CGFloat {
        if isPressing { return 0.975 }
        if isSelected { return selectedScale }
        return 1
    }

    /// 高亮填充：选中 4% < hover 6% < 按压 8%（都比旧的 12% 铺满色块轻得多）
    private var highlightFill: Color {
        if isSelected { return AppColors.primary.opacity(0.04) }
        if isPressing { return AppColors.primary.opacity(0.08) }
        if isHovering { return AppColors.primary.opacity(0.06) }
        return .clear
    }

    private var hasHighlight: Bool { isSelected || isPressing || isHovering }

    /// 高亮层（内缩圆角）：hover / 按压 / 选中共用底色
    @ViewBuilder
    private var highlightLayer: some View {
        switch highlightShape {
        case .roundedRect:
            RoundedRectangle(cornerRadius: highlightRadius, style: .continuous)
                .fill(highlightFill)
                .overlay(
                    RoundedRectangle(cornerRadius: highlightRadius, style: .continuous)
                        .stroke(isSelected ? selectedStroke : Color.clear, lineWidth: 1)
                )
                .shadow(color: isSelected ? AppColors.primary.opacity(0.20) : Color.clear,
                        radius: 5, y: 5)
                .padding(highlightInset)
                .opacity(hasHighlight ? 1 : 0)
        case .circle:
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                Circle()
                    .fill(highlightFill)
                    .frame(width: side, height: side)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .shadow(color: isSelected ? AppColors.primary.opacity(0.20) : Color.clear,
                            radius: 5, y: 5)
                    .opacity(hasHighlight ? 1 : 0)
            }
        }
    }

    func body(content: Content) -> some View {
        content
            .background(AnchorReader(box: anchorBox))
            // 选中浮起 / 按压回缩；动画只挂在 isSelected 上（按压由 PressStateHolder 的事务控制，保持瞬时跟手）
            .scaleEffect(scale)
            .overlay(highlightLayer)
            .animation(.appFast, value: isSelected)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(PressBridge(
                onTap: {
                    // 左滑展开态：点击仅收起该行，不触发打开（防误触）
                    guard swipeBridge?.consumeGesture() != true else { return }
                    onTap()
                },
                onPress: { press.handle($0) },
                onLongPress: {
                    // 左滑展开态：长按同样先收起，不弹菜单
                    guard swipeBridge?.consumeGesture() != true else { return }
                    // 长按触发轻微震动（prepare 预唤醒触觉引擎，确保即时可靠触发）
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.prepare()
                    generator.impactOccurred()
                    presenter.show(items: items, anchor: anchorBox.rect, style: .drawer)
                },
                onSwipe: swipeBridge?.drag
            ))
            .onHover { isHovering = $0 }
            .accessibilityAddTraits(.isButton)
            .background(SecondaryClickBridge {
                presenter.show(items: items, anchor: anchorBox.rect)
            })
            // 选中项浮起，需盖住相邻 cell 的描边与阴影
            .zIndex(isSelected ? 1 : 0)
    }
}

extension View {
    /// 单元格交互：点击 + 长按弹底部抽屉菜单 + 指针右键弹锚点菜单（修复 Button 吞长按）
    func cellPressableMenu(
        cornerRadius: CGFloat = 12,
        highlightShape: CellPressHighlightShape = .roundedRect,
        highlightInset: EdgeInsets = EdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1),
        selectedScale: CGFloat = 1.02,
        selectedStroke: Color = AppColors.primary.opacity(0.35),
        isSelected: Bool = false,
        items: [PopupMenuItem],
        onTap: @escaping () -> Void
    ) -> some View {
        modifier(CellPressModifier(
            cornerRadius: cornerRadius,
            highlightShape: highlightShape,
            highlightInset: highlightInset,
            selectedScale: selectedScale,
            selectedStroke: selectedStroke,
            isSelected: isSelected,
            items: items,
            onTap: onTap
        ))
    }
}

// MARK: - 按压桥接（点击 + 长按）

/// UIKit 桥接的「点击 + 长按」手势，替代 SwiftUI 的 `onTapGesture` + `LongPressGesture`。
private struct PressBridge: UIViewRepresentable {
    let onTap: () -> Void
    let onPress: (PressPhase) -> Void
    let onLongPress: () -> Void
    /// 横向左滑回调（nil = 本行不支持左滑，pan 识别器直接禁用）
    var onSwipe: (@MainActor (SwipeDragPhase) -> Void)?

    func makeUIView(context: Context) -> PressBridgeView {
        let view = PressBridgeView(onTap: onTap, onPress: onPress, onLongPress: onLongPress)
        view.onSwipe = onSwipe
        return view
    }

    // 让桥接视图填满 cell（overlay 内容默认按自身理想大小居中，需显式铺满）
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PressBridgeView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

    func updateUIView(_ uiView: PressBridgeView, context: Context) {
        uiView.onTap = onTap
        uiView.onPress = onPress
        uiView.onLongPress = onLongPress
        uiView.onSwipe = onSwipe
    }
}

/// 标记协议：接管了 cell 点击 / 长按 / 左滑的 UIKit 手势层（`PressBridgeView`）。
protocol PressBridgedView {}

private final class PressBridgeView: UIView, UIGestureRecognizerDelegate, PressBridgedView {
    var onTap: () -> Void
    var onPress: (PressPhase) -> Void
    var onLongPress: () -> Void

    /// 左滑回调；赋值即开关 pan 识别器（避免给不支持左滑的 cell 挂无用手势）
    var onSwipe: (@MainActor (SwipeDragPhase) -> Void)? {
        didSet {
            let shouldEnable = onSwipe != nil
            // 正在识别时改 isEnabled 会强制取消手势，故仅在状态真正变化时写入
            if pan.isEnabled != shouldEnable {
                pan.isEnabled = shouldEnable
                // 首次开启（左滑行上屏）时注册侧滑返回识别器，交给协调器按展开态开关
                if shouldEnable { registerEnclosingPopGesture() }
            }
        }
    }

    private let longPress = UILongPressGestureRecognizer()
    private let pan = UIPanGestureRecognizer()
    /// 长按是否已进入（仅已进入的长按才在结束时复位按压态，避免误清掉点击的回弹动画）
    private var isLongPressing = false
    /// 横向拖动是否已进入（期间抑制点击，避免滑完手指抬起又触发打开）
    private var isPanning = false
    /// 本视图上屏时刻（`CACurrentMediaTime`，与 `UITouch.timestamp` 同一时基）
    private var appearedAt: TimeInterval = 0
    /// 本次按压是否由本视图自己上报过 `.began`：保证 began / ended 成
    private var isPressReported = false
    /// 本次按压的起始时刻（`CACurrentMediaTime`）：按压时间线日志用
    private var pressStartedAt: TimeInterval = 0

    /// 最近一次离开窗口的时刻（用于区分真上屏 / 宿主层级重排）
    private var detachedAt: TimeInterval = 0

    init(onTap: @escaping () -> Void,
         onPress: @escaping (PressPhase) -> Void,
         onLongPress: @escaping () -> Void) {
        self.onTap = onTap
        self.onPress = onPress
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

        // 左滑：与点击/长按同属本视图，复用同一套仲裁。
        pan.delegate = self
        pan.cancelsTouchesInView = false
        pan.isEnabled = false                      // 默认关闭，由 onSwipe 赋值时开启
        pan.addTarget(self, action: #selector(handlePan))
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 挂到窗口上时关闭所在滚动容器的触摸延迟
    override func willMove(toWindow newWindow: UIWindow?) {
        // 高频重绘会把同一层「移出再移入」窗口：记录离开时刻，用来区分
        if newWindow == nil { detachedAt = CACurrentMediaTime() }
        super.willMove(toWindow: newWindow)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        let now = CACurrentMediaTime()
        // 只有「首次上屏」或「确实离开过一段时间后的上屏」才刷新 `appearedAt`。
        let refreshAppearedAt = appearedAt == 0 || now - detachedAt > 0.2
        if refreshAppearedAt { appearedAt = now }
        disableTouchDelayInEnclosingScrollView(of: self)
        registerEnclosingPopGesture()
    }

 // MARK: - 侧滑返回识别器

    /// 已记录过「缺失侧滑返回」日志的导航栈：滚动复用会让 `didMoveToWindow` 每帧重入，
    /// 该条件与具体行无关，按栈去重后只留一条面包屑
    private static var warnedMissingPopScopes = Set<ObjectIdentifier>()
    /// 已记录过「已接管侧滑返回」诊断日志的导航栈（同上，避免 debug 日志刷屏）
    private static var loggedAttachedPopScopes = Set<ObjectIdentifier>()
    /// 没有导航栈时的固定去重键（此时所有行共享同一结论）
    private static let fallbackPopScope = NSObject()

    /// 注册所在导航栈的「侧滑返回」识别器，交给 `SwipeRowCoordinator` 按行的展开态开关。
    private func registerEnclosingPopGesture() {
        guard onSwipe != nil else { return }
        let scope = enclosingNavigationControllers().first.map(ObjectIdentifier.init)
            ?? ObjectIdentifier(Self.fallbackPopScope)
        let gestures = enclosingPopGestures()
        guard !gestures.isEmpty else {
            guard Self.warnedMissingPopScopes.insert(scope).inserted else { return }
            AppLogger.shared.log("左滑行未找到侧滑返回识别器：右滑收起只能靠行内 pan 与系统抢手势", level: .warn, module: "swipe")
            return
        }
        // 诊断：打印实际接管到的识别器，用于确认「右滑仍返回上一级」时禁用是否真的落到了
        if Self.loggedAttachedPopScopes.insert(scope).inserted {
            AppLogger.shared.log(
                "左滑行接管侧滑返回 \(gestures.count) 个：" + gestures.map { "\(type(of: $0))#enabled=\($0.isEnabled)" }.joined(separator: ", "),
                level: .debug,
                module: "swipe"
            )
        }
        SwipeRowCoordinator.shared.attachPopGestures(gestures)
    }

    /// 采集所在导航栈的「侧滑返回」识别器。
    private func enclosingPopGestures() -> [UIGestureRecognizer] {
        var result: [UIGestureRecognizer] = []
        var seen = Set<ObjectIdentifier>()
        func append(_ gesture: UIGestureRecognizer?) {
            guard let gesture, seen.insert(ObjectIdentifier(gesture)).inserted else { return }
            result.append(gesture)
        }
        for controller in enclosingNavigationControllers() {
            append(controller.interactivePopGestureRecognizer)
            // 导航栈自身的包装视图层级（系统返回手势通常就挂在这一层）+ 导航栏
            for gesture in Self.popLikeRecognizers(in: controller.view, depth: 2) { append(gesture) }
            for gesture in Self.popLikeRecognizers(in: controller.navigationBar, depth: 2) { append(gesture) }
        }
        return result
    }

    /// 在 `view` 及其至多 `depth` 层子视图里挑出「疑似系统返回手势」。
    private static func popLikeRecognizers(in view: UIView, depth: Int) -> [UIGestureRecognizer] {
        guard depth >= 0 else { return [] }
        var found = (view.gestureRecognizers ?? []).filter(isPopLike)
        for subview in view.subviews {
            found += popLikeRecognizers(in: subview, depth: depth - 1)
        }
        return found
    }

    private static func isPopLike(_ gesture: UIGestureRecognizer) -> Bool {
        let name = String(describing: type(of: gesture))
        return name.contains("Parallax") || name.contains("TransitionPan") || name.contains("EdgePan")
    }

    /// 当前视图所属（含嵌套）的导航栈控制器。
    private func enclosingNavigationControllers() -> [UINavigationController] {
        var result: [UINavigationController] = []
        var seen = Set<ObjectIdentifier>()
        func append(_ controller: UINavigationController?) {
            guard let controller, seen.insert(ObjectIdentifier(controller)).inserted else { return }
            result.append(controller)
        }
        var responder: UIResponder? = self
        while let current = responder {
            if let navigationController = current as? UINavigationController {
                append(navigationController)
            } else if let viewController = current as? UIViewController {
                append(viewController.navigationController)
            }
            responder = current.next
        }
        if let root = window?.rootViewController {
            for controller in Self.navigationControllers(containing: self, from: root) { append(controller) }
        }
        return result
    }

    /// 从根控制器递归找出「视图层级包含 `view`」的导航栈（兄弟分支会被跳过，故不会误伤其他标签页）
    private static func navigationControllers(
        containing view: UIView,
        from controller: UIViewController
    ) -> [UINavigationController] {
        var found: [UINavigationController] = []
        if let navigation = controller as? UINavigationController, view.isDescendant(of: navigation.view) {
            found.append(navigation)
        }
        for child in controller.children {
            found += navigationControllers(containing: view, from: child)
        }
        if let presented = controller.presentedViewController {
            found += navigationControllers(containing: view, from: presented)
        }
        return found
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard !isPanning else { return }   // 左滑过程中抬手不算点击
        if recognizer.state == .ended { onTap() }
    }

    // 手指按下立即进入按压态（高亮 + 缩放跟手），不等长按阈值
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        // 手指一落下就再禁用一遍侧滑返回：系统/框架在部分更新后会
        SwipeRowCoordinator.shared.reassertPopGesturesDisabled(reason: "手指落下")
        guard shouldReportPress(touches) else { return }
        isPressReported = true
        report(.began)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        guard isPressReported else { return }
        isPressReported = false
        report(.ended)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        guard isPressReported else { return }
        isPressReported = false
        report(.cancelled)
    }

    /// 上报按压相位，并把按压时间线写进日志。
    private func report(_ phase: PressPhase) {
        let now = CACurrentMediaTime()
        switch phase {
        case .began:
            pressStartedAt = now
            AppLogger.shared.log(
                "按压 began（上屏后 \(Int((now - appearedAt) * 1000))ms）",
                level: .debug,
                module: "press"
            )
        case .ended, .cancelled:
            guard pressStartedAt > 0 else { break }
            AppLogger.shared.log(
                "按压 \(phase == .ended ? "ended" : "cancelled")（持续 \(Int((now - pressStartedAt) * 1000))ms）",
                level: .debug,
                module: "press"
            )
            pressStartedAt = 0
        }
        onPress(phase)
    }

    /// 是否该把这次触摸当作「点在本视图上」。
    private func shouldReportPress(_ touches: Set<UITouch>) -> Bool {
        let belonged = touches.contains { $0.view === self }
        if !belonged, touches.contains(where: { $0.view != nil }) {
            AppLogger.shared.log(
                "按压过滤：触摸归属非本视图（\(touches.compactMap { $0.view.map { String(describing: type(of: $0)) } }.joined(separator: "/")))",
                level: .debug,
                module: "press"
            )
            return false
        }
        if enclosingNavigationControllers().contains(where: { $0.transitionCoordinator != nil }) {
            AppLogger.shared.log("按压过滤：导航转场进行中", level: .debug, module: "press")
            return false
        }
        // 留 20ms 容差：同帧内上屏与按下允许互相穿插，不影响只手速的真人操作
        let oldest = touches.map(\.timestamp).min() ?? 0
        guard oldest + 0.02 >= appearedAt else {
            AppLogger.shared.log(
                "按压过滤：在途触摸（触摸早于上屏 \(Int((appearedAt - oldest) * 1000))ms）",
                level: .debug,
                module: "press"
            )
            return false
        }
        return true
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            isLongPressing = true
            onLongPress()          // 达到长按阈值触发菜单，不等松手
        case .ended, .cancelled, .failed:
            // 兜底复位：仅针对已进入的长按（移动超限导致的 .failed 不应打断点击的回弹动画）
            guard isLongPressing else { return }
            isLongPressing = false
            report(.cancelled)
        default:
            break
        }
    }

 // MARK: - 左滑

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let onSwipe else { return }
        switch recognizer.state {
        case .began:
            isPanning = true
            report(.cancelled)     // 清掉按压高亮：此刻意图已明确是滑动而非点击
            cancelLongPress()
            onSwipe(.began)
        case .changed:
            onSwipe(.changed(recognizer.translation(in: self).x))
        case .ended:
            onSwipe(.ended(
                translation: recognizer.translation(in: self).x,
                velocity: recognizer.velocity(in: self).x
            ))
            // 延到下一轮 runloop 复位：同一次抬手里 tap / pan 回调的投递顺序 UIKit 不保证
            DispatchQueue.main.async { [weak self] in self?.isPanning = false }
        case .cancelled, .failed:
            onSwipe(.cancelled)
            DispatchQueue.main.async { [weak self] in self?.isPanning = false }
        default:
            break
        }
    }

    /// 强制取消长按（禁用再启用是 UIKit 既定做法：会把识别器打回 .possible）
    private func cancelLongPress() {
        guard longPress.isEnabled else { return }
        longPress.isEnabled = false
        longPress.isEnabled = true
        if isLongPressing { isLongPressing = false }
    }

    /// 仅当横向分量明显占优时才让 pan 开始：竖向滚动继续归 UIScrollView
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan else { return true }
        guard onSwipe != nil else { return false }
        // 行展开时的这次横向拖动意图是「收起按钮」而不是返回上一级：在识别开始前
        SwipeRowCoordinator.shared.reassertPopGesturesDisabled(reason: "pan 即将识别")
        let velocity = pan.velocity(in: self)
        // 极慢起手时首帧速度可能为 0，退化用累计位移判方向，避免这一次左滑整体失效
        if abs(velocity.x) < 1, abs(velocity.y) < 1 {
            let translation = pan.translation(in: self)
            return abs(translation.x) > abs(translation.y)
        }
        return abs(velocity.x) > abs(velocity.y) * 1.5
    }

    /// 不与滚动容器的 pan 同时识别（否则左滑时列表会一起竖向滚动）
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        !(other.view is UIScrollView)
    }
}

// MARK: - 右键桥接

/// 窗口级 `.secondary`（右键）手势桥接：不拦截普通触摸，命中本视图区域时回调。
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
