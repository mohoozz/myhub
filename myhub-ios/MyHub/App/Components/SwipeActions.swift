import SwiftUI
import UIKit

// MARK: - 左滑操作定义

/// 列表行左滑露出的操作按钮（TODO 408）。
///
/// 图标与文案须与该项在长按抽屉菜单（`PopupMenuItem`）里的同名操作**完全一致**
/// ——同一操作同一 SF Symbol、同一语义色、同一文案，保证两条交互路径的视觉词汇统一。
struct SwipeAction: Identifiable {
    /// 稳定身份：**不能用 `UUID()`**——调用方每次 body 求值都会重建 `SwipeAction`，
    /// 随机 id 会让 `ForEach` 判定为新元素并重建 Button，若正好在手指按下与抬起之间
    /// 重建就会丢掉这次点击（表现为「点了删除没反应」）。同一行内 title 天然唯一。
    var id: String { title }
    let title: String
    let systemImage: String
    /// 语义色：破坏性操作用系统红，次级操作用灰
    let tint: Color
    /// 主线程执行（UI 状态变更 / Store 访问均为 MainActor 隔离）
    let action: @MainActor () -> Void

    init(
        title: String,
        systemImage: String,
        tint: Color = AppColors.destructive,
        action: @escaping @MainActor () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.action = action
    }
}

// MARK: - 手势阶段

/// 左滑拖动阶段（由 cell 手势层的 UIKit pan 驱动，见 `PressBridge`）
enum SwipeDragPhase {
    case began
    /// 累计横向位移（向左为负）
    case changed(CGFloat)
    case ended(translation: CGFloat, velocity: CGFloat)
    case cancelled
}

// MARK: - 注入 cell 手势层的桥接

/// 左滑行为桥接：由 `swipeActions` 注入环境，cell 的手势层（`CellPressModifier` → `PressBridge`）读取。
///
/// 之所以不在外层叠 SwiftUI `DragGesture`：cell 的点击/长按由铺满整个 cell 的 UIKit
/// `PressBridgeView` 接管（它会抢走 touch），外层 SwiftUI 手势不可靠。把横向 pan 放进
/// 同一个 UIKit 视图里，才能复用它已有的手势仲裁（见 `PressBridgeView` 的 delegate）。
///
/// **必须是引用类型**：拖动时 `offset` 每帧变化会让修饰器 body 重算，若桥接是含闭包的
/// struct（SwiftUI 无法判等），`.environment` 便逐帧视为新值，把整行子树
/// （`RemoteCoverImage`、`AnchorReader` 的 GeometryReader、`PressBridge.updateUIView`…）
/// 全部重新求值——正是本工程反复踩过的「大目录滑动卡顿」同一类开销。
/// 引用类型身份稳定，environment 不再逐帧变化；闭包本体可安全替换（取的是最新 @State）。
/// 不声明任何 `@Published`——它只做回调转发，不应触发视图刷新。
@MainActor
final class SwipeRowBridge: ObservableObject {
    var drag: (SwipeDragPhase) -> Void = { _ in }
    /// 行处于展开态时消费点击 / 长按（仅收起该行，不触发打开或弹菜单）；返回 true 表示已消费
    var consumeGesture: () -> Bool = { false }
}

private struct SwipeRowBridgeKey: EnvironmentKey {
    static let defaultValue: SwipeRowBridge? = nil
}

extension EnvironmentValues {
    var swipeRowBridge: SwipeRowBridge? {
        get { self[SwipeRowBridgeKey.self] }
        set { self[SwipeRowBridgeKey.self] = newValue }
    }
}

// MARK: - 单行展开协调器

/// 保证「同一时刻只有一行展开」：新行展开时直接回调上一行的收起闭包。
///
/// 故意**不做** `ObservableObject`：若用 `@Published` 广播，大目录下每次滑动都会
/// 触发全部行重建（LazyVStack 里数百行），这里只需点对点通知上一行收起。
@MainActor
final class SwipeRowCoordinator {
    static let shared = SwipeRowCoordinator()

    private var closeHandlers: [UUID: () -> Void] = [:]
    private var openID: UUID?

    private init() {}

    /// 当前是否有行处于展开态
    var hasOpenRow: Bool { openID != nil }

    func register(_ id: UUID, close: @escaping () -> Void) {
        // 防御：`onDisappear` 在极端时序（快速切后台 / 容器被整体替换）下可能被跳过，
        // 残留闭包会一直持有该行的 @State 存储盒，且本类是跨页面共享的单例、累积是全生命周期的。
        // 展开态最多只有 1 行，留一屏余量足够；超量整体清空（各行下次 onAppear 会重新注册）。
        if closeHandlers.count > 200 {
            closeHandlers.removeAll()
            openID = nil
        }
        closeHandlers[id] = close
    }

    func unregister(_ id: UUID) {
        closeHandlers[id] = nil
        if openID == id { openID = nil }
    }

    /// 某行展开：收起此前展开的那一行
    func didOpen(_ id: UUID) {
        if let openID, openID != id {
            closeHandlers[openID]?()
        }
        openID = id
    }

    func didClose(_ id: UUID) {
        if openID == id { openID = nil }
    }

    /// 收起当前展开行；返回是否确实收起了某一行
    @discardableResult
    func closeOpenRow() -> Bool {
        guard let openID else { return false }
        closeHandlers[openID]?()
        self.openID = nil
        return true
    }
}

// MARK: - 左滑操作修饰器

/// 列表行左滑操作（TODO 408 方案 A）：
/// - 左滑**只负责露出按钮**，必须点按按钮才执行——不做「一滑到底自动删除」，避免误删；
/// - 露出宽度停在按钮总宽，继续拖有橡皮筋阻尼；松手按位移/速度判定展开或收起；
/// - 同一时刻只允许一行展开（`SwipeRowCoordinator`）；
/// - 展开态点击行主体仅收起该行，不会打开文件；
/// - 多选态传 `enabled: false` 禁用（避免与勾选冲突），并立即收起。
private struct SwipeActionsModifier: ViewModifier {
    let actions: [SwipeAction]
    let enabled: Bool
    /// 滑动层的不透明底色（露出按钮的前提：内容必须挡住底层按钮）。nil = 调用方已自带底色
    let rowBackground: Color?

    @State private var rowID = UUID()
    @State private var offset: CGFloat = 0
    /// 本次拖动开始时的位移（支持从展开态继续拖）
    @State private var dragStart: CGFloat = 0
    /// 注入 cell 手势层的桥接（引用类型，身份稳定——详见 `SwipeRowBridge` 注释）
    @StateObject private var bridge = SwipeRowBridge()

    /// 单个按钮宽度（图标 + 文案，与系统左滑按钮观感一致）
    private let buttonWidth: CGFloat = 78

    private var totalWidth: CGFloat { CGFloat(actions.count) * buttonWidth }
    private var isOpen: Bool { offset < -1 }

    func body(content: Content) -> some View {
        // 每次求值把最新闭包装进稳定的桥接对象（赋值到非 @Published 属性，不触发刷新）
        bridge.drag = { phase in handle(phase) }
        bridge.consumeGesture = {
            // 本行展开 → 收起本行；别的行展开 → 只收起那一行（点击不应打开本行，防误触）
            guard isOpen else { return SwipeRowCoordinator.shared.closeOpenRow() }
            close()
            return true
        }
        return content
            .background { if let rowBackground { rowBackground } }
            .offset(x: offset)
            // 按钮层挂在 .offset 外侧的 background：
            // - `.offset` 只改渲染不改布局，故本层不随行内容左移（按钮留在右侧原地）；
            // - 作为 background 它拿到的是**整行已确定的高度**提案，内部 `maxHeight: .infinity`
            //   才能撑满行高。若改用 ZStack 层叠，竖向提案为 nil（LazyVStack 内），
            //   按钮会退化成图标自身高度（≈34pt）并垂直居中，露出一小块红方块而非满行红条。
            .background(alignment: .trailing) { actionsLayer }
            .environment(\.swipeRowBridge, enabled && !actions.isEmpty ? bridge : nil)
            .onAppear {
                SwipeRowCoordinator.shared.register(rowID) { close() }
            }
            .onDisappear {
                SwipeRowCoordinator.shared.unregister(rowID)
                offset = 0   // 关键：状态被保留时也归零，避免「按钮还露着但协调器已注销」
            }
            // 进入多选态立即收起（左滑与多选互斥）
            .onChange(of: enabled) { if !$0 { close() } }
    }

    // MARK: 按钮层

    /// 按钮区：宽度跟随露出量增长，内部按钮保持自然尺寸并裁切，
    /// 得到与系统一致的「行滑开多少、按钮露出多少」观感（而非整体缩放）。
    private var actionsLayer: some View {
        HStack(spacing: 0) {
            ForEach(actions) { action in
                Button {
                    // 先收起再执行：避免按钮还在屏上时就触发删除动画 / 弹窗
                    close()
                    action.action()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: action.systemImage)
                            .font(.body)
                        Text(action.title)
                            .font(.caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(.white)
                    .frame(width: buttonWidth)
                    .frame(maxHeight: .infinity)
                    .background(action.tint)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: totalWidth, alignment: .trailing)
        .frame(width: max(0, -offset), alignment: .trailing)
        .clipped()
    }

    // MARK: 手势

    private func handle(_ phase: SwipeDragPhase) {
        switch phase {
        case .began:
            // 开始滑另一行时先收起已展开的那一行（本行已展开则是继续拖，不能收）
            if !isOpen { SwipeRowCoordinator.shared.closeOpenRow() }
            dragStart = offset
        case .changed(let dx):
            var next = dragStart + dx
            // 右滑超过原位、左滑超过按钮总宽：橡皮筋阻尼
            if next > 0 { next *= 0.2 }
            if next < -totalWidth { next = -totalWidth + (next + totalWidth) * 0.25 }
            offset = next
        case .ended(let translation, let velocity):
            let projected = offset + velocity * 0.06   // 惯性预测落点
            let shouldOpen = projected < -totalWidth * 0.45
                || (velocity < -600 && translation < 0)
            shouldOpen ? open() : close()
        case .cancelled:
            // 取消按已有位移就近归位，避免手势被打断时卡在中间态
            offset < -totalWidth * 0.5 ? open() : close()
        }
    }

    private func open() {
        guard offset != -totalWidth else { return }
        SwipeRowCoordinator.shared.didOpen(rowID)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
        withAnimation(.appFast) { offset = -totalWidth }
    }

    private func close() {
        SwipeRowCoordinator.shared.didClose(rowID)
        guard offset != 0 else { return }
        withAnimation(.appFast) { offset = 0 }
    }
}

extension View {
    /// 列表行左滑操作（点按按钮才执行，不支持一滑到底；多选态请传 `enabled: false`）
    /// - Parameter rowBackground: 滑动层底色；通栏列表行需传入页面卡色，否则会透出底层按钮
    func swipeActions(
        enabled: Bool = true,
        rowBackground: Color? = nil,
        _ actions: [SwipeAction]
    ) -> some View {
        modifier(SwipeActionsModifier(actions: actions, enabled: enabled, rowBackground: rowBackground))
    }
}
