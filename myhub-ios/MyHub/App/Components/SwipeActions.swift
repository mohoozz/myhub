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

    /// 被接管的「侧滑返回」识别器（TODO 412）与其禁用记账
    private final class PopGestureHandle {
        /// 识别器由导航栈强持有，这里只弱引用，避免协调器（跨页面单例）延长其生命周期
        weak var gesture: UIGestureRecognizer?
        /// 记录「这次禁用是本协调器做的」，只恢复自己禁用过的那次，
        /// 避免与系统自身的状态（栈底无返回项 / 转场进行中）打架
        private(set) var didDisable = false

        init(_ gesture: UIGestureRecognizer) { self.gesture = gesture }

        /// 识别器短标识（同一运行期内稳定）：把「禁用」与「恢复」串成时间线，
        /// 用来确认禁用是否落到了**当前生效**的那一个上——每次 push 都可能换实例（TODO 412）
        var tag: String {
            guard let gesture else { return "已释放" }
            let pointer = UInt(bitPattern: Unmanaged.passUnretained(gesture).toOpaque())
            return String(String(pointer, radix: 16).suffix(5))
        }

        /// 返回本次是否真的改动了开关（用于诊断「禁用到底有没有落到生效的那个识别器上」）
        @discardableResult
        func setEnabled(_ enabled: Bool, reason: String) -> Bool {
            guard let gesture else { return false }
            if enabled {
                guard didDisable else { return false }
                gesture.isEnabled = true
                didDisable = false
                AppLogger.shared.log("侧滑返回 #\(tag) 恢复 ← \(reason)", level: .debug, module: "swipe")
                return true
            }
            // 系统本来就没开（栈底 / 转场中）时不接管，避免把系统的开关状态改坏
            guard gesture.isEnabled else { return false }
            gesture.isEnabled = false
            didDisable = true
            AppLogger.shared.log("侧滑返回 #\(tag) 禁用 ← \(reason)（\(type(of: gesture))）", level: .debug, module: "swipe")
            return true
        }
    }

    /// 行展开后文件名恰好落在屏幕左缘，用户「右滑收起删除按钮」的起手位置就压在系统
    /// 侧滑返回的识别区内，系统会先抢走这次手势：按钮没收起，反而返回了上一级目录。
    /// 故行展开期间临时禁用这些识别器——右滑只负责收起行；收起后立刻恢复，边缘滑动依然返回上一级。
    ///
    /// 存**多个**：响应链上可能有多层导航栈（嵌套 `NavigationStack` / Tab 容器），
    /// 只要漏掉一层，那一层的侧滑返回就照样会把手势抢走（这正是「改了还是返回上一级」的原因）。
    private var popGestures: [PopGestureHandle] = []
    /// 待执行的「恢复侧滑返回」（见 `restorePopGestures`）
    private var pendingPopGestureRestore: DispatchWorkItem?

    private init() {}

    /// 当前是否有行处于展开态
    var hasOpenRow: Bool { openID != nil }

    /// cell 手势层上屏时注册所在导航栈的侧滑返回识别器（由其转交，见 `PressBridgeView`）
    func attachPopGestures(_ gestures: [UIGestureRecognizer]) {
        let existing = popGestures.compactMap(\.gesture)
        // 同一批识别器（同一个导航栈）重复注册时直接返回，避免每次 cell 上屏都重建句柄
        if existing.count == gestures.count, !gestures.isEmpty,
           zip(existing, gestures).allSatisfy({ $0 === $1 }) {
            if hasOpenRow { setPopGesturesEnabled(false, reason: "重复注册兜底") }   // 兜底：展开态下仍保持禁用
            return
        }
        setPopGesturesEnabled(true, reason: "换导航栈")   // 换了导航栈（切 Tab）：先把上一个栈恢复回来
        popGestures = gestures.map(PopGestureHandle.init)
        if hasOpenRow { setPopGesturesEnabled(false, reason: "新栈注册时展开态") }
    }

    private func setPopGesturesEnabled(_ enabled: Bool, reason: String) {
        if !enabled { cancelPendingPopGestureRestore() }
        for handle in popGestures { handle.setEnabled(enabled, reason: reason) }
    }

    /// 恢复侧滑返回，但**推迟到当前触摸序列必然结束之后**（TODO 412）。
    ///
    /// 收起行的同一次手势里若立刻恢复系统侧滑返回，系统识别器可能原地接管这次**仍在进行**的拖动
    /// （行已收起、手指还在滑），表现出来就是「右滑收起按钮后还继续返回了上一级」。
    /// 故恢复统一走这里排队；200ms 内若有新的禁用（再次展开 / pan 接管）则自动作废。
    private func restorePopGestures(reason: String, delay: TimeInterval = 0.2) {
        cancelPendingPopGestureRestore()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPopGestureRestore = nil
            self.setPopGesturesEnabled(true, reason: reason)
        }
        pendingPopGestureRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelPendingPopGestureRestore() {
        pendingPopGestureRestore?.cancel()
        pendingPopGestureRestore = nil
    }

    /// 行展开期间再禁用一遍侧滑返回。
    ///
    /// 用于在**触摸落下 / 行内 pan 即将识别**的那一刻补一刀：SwiftUI 与 UIKit 在部分更新后
    /// 会重置 `interactivePopGestureRecognizer.isEnabled`（这一层不受我们控制），此刻重新禁用
    /// 不仅能补上被重置的状态，若系统手势已在识别中还会被强制取消——
    /// 用户「右滑收起按钮」不会再被拐去返回上一级（TODO 412）。
    func reassertPopGesturesDisabled(reason: String) {
        guard hasOpenRow else { return }
        setPopGesturesEnabled(false, reason: reason)
    }

    /// 诊断用：侧滑返回识别器的接管清单（数量 / 每个是否被本协调器禁用）
    var popGestureState: String {
        "侧滑返回 \(popGestures.count) 个[\(popGestures.map { "#\($0.tag)\($0.didDisable ? "禁" : "启")" }.joined(separator: " "))]"
    }

    func register(_ id: UUID, close: @escaping () -> Void) {
        // 防御：`onDisappear` 在极端时序（快速切后台 / 容器被整体替换）下可能被跳过，
        // 残留闭包会一直持有该行的 @State 存储盒，且本类是跨页面共享的单例、累积是全生命周期的。
        // 展开态最多只有 1 行，留一屏余量足够；超量整体清空（各行下次 onAppear 会重新注册）。
        if closeHandlers.count > 200 {
            closeHandlers.removeAll()
            openID = nil
            restorePopGestures(reason: "清空过期闭包")   // 展开行已一并注销，侧滑返回别被留在禁用态
        }
        closeHandlers[id] = close
    }

    func unregister(_ id: UUID) {
        closeHandlers[id] = nil
        if openID == id {
            openID = nil
            restorePopGestures(reason: "行注销")
        }
    }

    /// 某行展开：收起此前展开的那一行
    func didOpen(_ id: UUID) {
        if let openID, openID != id {
            closeHandlers[openID]?()
        }
        openID = id
        setPopGesturesEnabled(false, reason: "行展开")
        // 诊断（TODO 412）：真机复现「右滑仍返回上一级」时先看这行——
        // «0 个»＝没找到导航栈的识别器（注册路径没走到）；«禁/总数不等»＝漏掉了正在生效的那一层。
        AppLogger.shared.log("行展开：接管 \(popGestureState)", level: .debug, module: "swipe")
    }

    func didClose(_ id: UUID) {
        if openID == id {
            openID = nil
            restorePopGestures(reason: "行收起")
        }
    }

    /// 收起当前展开行；返回是否确实收起了某一行
    @discardableResult
    func closeOpenRow() -> Bool {
        guard let openID else { return false }
        closeHandlers[openID]?()
        self.openID = nil
        restorePopGestures(reason: "点按收起")
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

    /// 诊断（TODO 417）：行标识短串（仅用于把上/下屏日志配对）
    fileprivate static func short(_ id: UUID) -> String {
        String(id.uuidString.prefix(4))
    }
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
                // 诊断（TODO 417）：行身份是否被保留——反复上屏出现**同一个** #id 说明
                // SwiftUI 在重复插拔同一行的宿主层；不断出现新 #id 则说明整行被重建
                AppLogger.shared.log("左滑行上屏 #\(Self.short(rowID))", level: .debug, module: "srow")
            }
            .onDisappear {
                SwipeRowCoordinator.shared.unregister(rowID)
                offset = 0   // 关键：状态被保留时也归零，避免「按钮还露着但协调器已注销」
                AppLogger.shared.log("左滑行下屏 #\(Self.short(rowID))", level: .debug, module: "srow")
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
            // 诊断（TODO 412）：记下「这次拖动开始时行与侧滑返回各是什么状态」——
            // 真机复现时把这条与后面的「pan 结束」、[swipe] 侧滑返回开关日志对时间线即可定位
            AppLogger.shared.log(
                "pan 开始：本行展开=\(isOpen)，\(SwipeRowCoordinator.shared.popGestureState)",
                level: .debug,
                module: "swipe"
            )
        case .changed(let dx):
            var next = dragStart + dx
            // 右滑超过原位、左滑超过按钮总宽：橡皮筋阻尼
            if next > 0 { next *= 0.2 }
            if next < -totalWidth { next = -totalWidth + (next + totalWidth) * 0.25 }
            offset = next
        case .ended(let translation, let velocity):
            let projected = offset + velocity * 0.06   // 惯性预测落点
            // 已展开态下的「右滑收起」要同样跟手（TODO 412）：右滑回撤超过半程、
            // 或是一次明确的右滑快甩，都直接收起——否则松手又弹回展开态，
            // 用户会以为「右滑没反应」。橡皮筋回弹（右滑越过原位）也走这条归零。
            let isRetracting = velocity > 600
                || (translation > 0 && projected > -totalWidth * 0.55)
            let shouldOpen = !isRetracting
                && (projected < -totalWidth * 0.45 || (velocity < -600 && translation < 0))
            AppLogger.shared.log(
                "pan 结束：位移 \(Int(translation)) 速度 \(Int(velocity)) → \(shouldOpen ? "展开" : "收起")",
                level: .debug,
                module: "swipe"
            )
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

    /// 点击列表**空白区域**收起左滑展开行（TODO 411）
    ///
    /// 挂在滚动容器**内部**的内容上（识别器需要挂到所在 `UIScrollView`，见 `SwipeRowBlankTapCatcher`）。
    /// 落在 cell 手势层（`PressBridgedView`）上的点击交回 cell 自己处理——展开态点击只收起不打开，
    /// 语义已在 `SwipeRowBridge.consumeGesture` 中定好，这里只补「点在空白处」这一条路径。
    func dismissSwipeRowOnBlankTap() -> some View {
        background { SwipeRowBlankTapCatcher() }
    }
}

// MARK: - 点击空白区域收起

/// 空白区域点击识别器的宿主：自身不参与命中测试，只借层级找到所在滚动容器并把识别器挂上去。
struct SwipeRowBlankTapCatcher: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { BlankTapCatcherView() }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

private final class BlankTapCatcherView: UIView, UIGestureRecognizerDelegate {
    private let tap = UITapGestureRecognizer()
    private weak var installedScrollView: UIScrollView?

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        tap.delegate = self
        // 不吞触摸：cell 的点击 / 长按 / 左滑 pan 照常识别，二者互不干扰
        tap.cancelsTouchesInView = false
        tap.addTarget(self, action: #selector(handleTap))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            installedScrollView?.removeGestureRecognizer(tap)
            installedScrollView = nil
            return
        }
        installIfNeeded()
    }

    /// 识别器必须挂在 `UIScrollView` 上而不是自身上：空白区域的命中视图是滚动容器本身，
    /// 挂在本视图（`isUserInteractionEnabled = false`，位于内容层）上永远收不到那些点击。
    private func installIfNeeded() {
        guard let scrollView = enclosingScrollView(), scrollView !== installedScrollView else { return }
        installedScrollView?.removeGestureRecognizer(tap)
        scrollView.addGestureRecognizer(tap)
        installedScrollView = scrollView
    }

    private func enclosingScrollView() -> UIScrollView? {
        var current: UIView? = superview
        while let candidate = current {
            if let scrollView = candidate as? UIScrollView { return scrollView }
            current = candidate.superview
        }
        return nil
    }

    @objc private func handleTap() {
        SwipeRowCoordinator.shared.closeOpenRow()
    }

    /// 只接「落空」的点击：点在 cell 手势层上的交给 cell（展开态点击只收起、不打开文件）
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view is PressBridgedView)
    }
}
