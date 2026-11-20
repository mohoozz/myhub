import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 内置浏览器主页
/// 标签内容保活区 + 底部操作栏（含居中地址栏，滚动收起为小胶囊/下滑或点击展开，Safari 风格）。
struct BrowserHomeView: View {
    @EnvironmentObject private var session: BrowserSessionStore
    @EnvironmentObject private var dataStore: BrowserDataStore
    @EnvironmentObject private var player: PlayerPresenter
    @EnvironmentObject private var router: AppRouter

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// 沉浸态回写全局底部装饰（页签栏 + mini 播放器）的隐藏开关
    @Environment(\.bottomTabBarHidden) private var bottomTabBarHidden

    @State private var showingTabs = false
    @State private var showingBookmarks = false
    @State private var showingHistory = false
    @State private var showingSettings = false
    /// 操作栏是否收起为底部小胶囊（而非完全隐藏，始终可见可点击）
    @State private var toolbarMini = false
    /// 地址栏是否处于编辑态：由本视图持有——操作栏据此整体变为输入条
    @State private var addressEditing = false

    /// 底部浮层「小胶囊 ⇄ 操作栏」形变的共享命名空间
    @Namespace private var chromeMorphNS

    /// 底部浮层形态切换曲线：单容器形变的轻弹簧。
    private static let chromeMorph = Animation.spring(response: 0.34, dampingFraction: 0.86)

    /// 操作栏 / 收起态小胶囊与底部页签栏之间的视觉间距（左右内缩 12pt 形成上下「双胶囊」节奏）
    private let tabBarGap: CGFloat = 12

    /// 沉浸态下浮层底边到「屏幕物理底边」的距离：21pt = Home 指示条可见横条上沿（约 13pt）+ 8pt。
    private let immersiveBarGap: CGFloat = 21

    /// 沉浸态
    /// iPhone 上停留在「浏览器」页签期间隐藏全局页签栏与 mini 播放器，把约 128pt 竖向空间还给网页
    private var isImmersive: Bool {
        horizontalSizeClass == .compact && router.selectedTab == .browser
    }

    /// 汇报浏览器页的真实可见性（页签为浏览器且无全屏播放器遮挡）
    private func syncBrowserVisibility() {
        session.setBrowserVisible(router.selectedTab == .browser && !player.isFullscreen)
    }

    /// 底部预留间距：与页签栏留一段距离
    private var bottomBarGap: CGFloat {
        if isImmersive { return immersiveBarGap }
        return player.isMini ? tabBarGap + MiniPlayer.coverOverflow : tabBarGap
    }

    /// 网页层是否铺满整屏：仅沉浸态 + 已打开真实网页时生效。
    private var contentIgnoresSafeArea: Bool {
        guard isImmersive, let tab = session.activeTab else { return false }
        return !tab.isShowingStartPage
    }

    /// 网页层要压满的安全区边缘：全屏时上下一起压到屏幕边，其余情况维持安全区排布
    private var fullBleedEdges: Edge.Set {
        contentIgnoresSafeArea ? [.top, .bottom] : []
    }

    /// 左下角退出钮的垂直落点：底部操作栏胶囊之上 10pt。
    private var exitHandleBottomInset: CGFloat {
        bottomBarGap + BrowserToolbar.barHeight + 10
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // 网页层：沉浸态下铺满整屏——顶部压到状态栏、底部压到 Home 指示条，上下不再留白。
            contentArea
                .ignoresSafeArea(.container, edges: fullBleedEdges)

            // 编辑态遮罩（Safari 风格）：压暗网页并吃掉点击，点任意处即取消编辑。
            if addressEditing {
                Color.black.opacity(0.10)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { addressEditing = false }
                    .transition(.opacity)
            }

            // 底部浮层：操作栏 / 小胶囊浮在网页之上，不再与网页上下分栏
            bottomChrome

            // 沉浸态左下角退出钮（+ 有播放会话时的播放微件）
            if isImmersive, !addressEditing {
                HStack(spacing: 0) {
                    BrowserExitHandle(collapsed: toolbarMini, onExit: exitImmersive)
                        .padding(.bottom, exitHandleBottomInset)
                        .transition(.opacity)
                    Spacer(minLength: 0)
                }
            }
        }
        // 沉浸态 + 真实网页：把整个浮层坐标系压到**屏幕物理底边**，而不是系统底部安全区底边。
        .ignoresSafeArea(.container, edges: contentIgnoresSafeArea ? .bottom : [])
        .background(AppColors.pageBackground)
        .animation(Self.chromeMorph, value: toolbarMini)
        .animation(.appFast, value: addressEditing)
        .onChange(of: session.activeTabID) { _ in
            // 切换标签**不再**自动收起为胶囊
            addressEditing = false
        }
        // 沉浸态开关同步：`RootView` 以 ZStack 保活各页签（切页签不触发 onDisappear）
        .onChange(of: router.selectedTab) { tab in
            bottomTabBarHidden.wrappedValue = (horizontalSizeClass == .compact && tab == .browser)
            // 网页加载时机同步：本视图启动即构建，但只有真正显示时才应加载网页
            syncBrowserVisibility()
        }
        // 全屏播放器盖在本页之上时同样视为不可见：避免网页音频与视频声音叠加
        .onChange(of: player.isFullscreen) { _ in syncBrowserVisibility() }
        // iPad 分屏 / 多任务导致 sizeClass 变化时同步校正（regular 下不隐藏底部装饰）
        .onChange(of: horizontalSizeClass) { sizeClass in
            bottomTabBarHidden.wrappedValue = (sizeClass == .compact && router.selectedTab == .browser)
        }
        // 启动时各保活页签均会触发 onAppear，故按当前页签校正；退场兜底复位，避免底栏永久消失
        .onAppear {
            bottomTabBarHidden.wrappedValue = isImmersive
            syncBrowserVisibility()
        }
        .onDisappear {
            bottomTabBarHidden.wrappedValue = false
            session.setBrowserVisible(false)
        }
        .fullScreenCover(isPresented: $showingTabs) {
            TabGridView()
        }
        .sheet(isPresented: $showingBookmarks) {
            BookmarkView { url in session.open(url) }
        }
        .sheet(isPresented: $showingHistory) {
            HistoryView { url in session.open(url) }
        }
        .sheet(isPresented: $showingSettings) {
            BrowserSettingsView()
        }
    }

 // MARK: - 标签内容区（ZStack 保活，切换不销毁，保持导航历史栈）

    private var contentArea: some View {
        ZStack {
            ForEach(session.visibleTabs) { tab in
                // 会话恢复但尚未显示的标签不挂载视图：不创建 WKWebView、不渲染。
                if !tab.isPendingRestore || tab.id == session.activeTabID {
                    // 标签状态变化（滚动 / 刷新 / 导航）必须由持有 `@ObservedObject` 的子视图接收
                    BrowserTabContent(
                        tab: tab,
                        isActive: tab.id == session.activeTabID,
                        onCollapseToolbar: collapseToolbar,
                        onURLChange: { url in
                            // 只有「回到起始页」需要展开成地址栏
                            if url == nil { toolbarMini = false }
                            // 地址已随页面变化，编辑态若残留会继续编辑上一页 URL（如提交后又被重定向）
                            addressEditing = false
                        }
                    )
                }
            }
        }
    }

 // MARK: - 底部浮层（展开态操作栏 / 收起态小胶囊）

    /// 底部浮层的唯一出口：同一位置上二选一，二者共用 `chromeMorphNS` 的胶囊底。
    @ViewBuilder
    private var bottomChrome: some View {
        if let tab = session.activeTab {
            if toolbarMini, !tab.isShowingStartPage {
                // 加上热区补的 8pt：让「视觉胶囊」而不是热区落到与操作栏同一水平线上
                miniCapsule(tab)
                    .padding(.bottom, bottomBarGap + Self.capsuleHitInset)
                    // 只做透明度交叉：位移/缩放交给共享胶囊底的形变
                    .transition(.opacity)
            } else {
                BrowserToolbar(
                    tab: tab,
                    tabCount: session.visibleTabs.count,
                    menuItems: menuItems,
                    morphNamespace: chromeMorphNS,
                    onTabs: {
                        // 打开标签网格前先退出编辑：否则键盘会留在全屏页签网格下方
                        addressEditing = false
                        showingTabs = true
                    },
                    isEditingAddress: $addressEditing,
                    onSubmitAddress: { url in session.open(url) }
                )
                // 与底部页签栏留出一段距离（有 mini 播放器时补偿封面向上溢出的 8pt）
                .padding(.bottom, bottomBarGap)
                .transition(.opacity)
            }
        }
    }

 // MARK: - 行为

    /// 退出沉浸态：回到进入浏览器前的页签，页签栏与 mini 播放器随 `bottomTabBarHidden` 复位滑回。
    private func exitImmersive() {
        router.backToPreviousTab()
    }

    private func expandToolbar() {
        guard toolbarMini else { return }
        // 页面正在滑动时点击胶囊：这一轮滚动手势还没结束，紧随其后的 `scrollTick`
        session.activeTab?.suppressScrollCollapseForCurrentGesture()
        // 显式包一层弹簧：点击展开的落位动画由形变的同一曲线驱动，收尾「弹一下坐住」
        withAnimation(Self.chromeMorph) { toolbarMini = false }
    }

    /// 收起为底部小胶囊（**仅**滑动页面触发）。
    private func collapseToolbar() {
        guard !toolbarMini, !addressEditing else { return }
        toolbarMini = true
    }

 // MARK: - 收起态小胶囊（Safari 风格）

    /// 收起态小胶囊的视觉高度（S1 → H2）：32pt 是在 28pt「细线感」与 44pt「胖药丸」之间的取值
    private static let capsuleHeight: CGFloat = 32
    /// 视觉胶囊外再补的透明内边距（上下各 6pt）：32 + 6×2 = 44pt，命中区仍满足 iOS 下限
    private static let capsuleHitInset: CGFloat = 6

    /// 收起态胶囊里显示的域名：按内容贴合，超长才中段省略。
    private func capsuleHost(_ tab: BrowserTab) -> String {
        let host = tab.currentURL?.host ?? "网页"
        guard host.count > 18 else { return host }
        // 保留头 9 + 尾 6：既认得出站点，也留得住 .com / .cn 这类后缀
        return "\(host.prefix(9))…\(host.suffix(6))"
    }

    /// 操作栏收起后缩为底部中央的小胶囊：只显示域名，点击展开完整操作栏。
    private func miniCapsule(_ tab: BrowserTab) -> some View {
        Button {
            expandToolbar()
        } label: {
            Text(capsuleHost(tab))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(1)
                // 按内容贴合：不加 fixedSize，胶囊会被外层整宽提案撑成 227pt 的横条
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 11)
                .frame(height: Self.capsuleHeight)
                .background { ChromeCapsule(morphNamespace: chromeMorphNS) }
                .padding(.vertical, Self.capsuleHitInset)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("展开浏览器操作栏")
        // 锁图标去掉后，证书状态改为语音提示，VoiceOver 仍能听出是否 HTTPS
        .accessibilityHint(tab.hasOnlySecureContent ? "当前网页为安全连接" : "当前网页连接不安全")
    }

 // MARK: - 菜单

    private var menuItems: [PopupMenuItem] {
        var items: [PopupMenuItem] = []

        items.append(PopupMenuItem(title: "新建标签", systemImage: "plus") {
            session.newTab()
        })

        if let tab = session.activeTab, let url = tab.currentURL {
            let title = tab.title.isEmpty ? (url.host ?? url.absoluteString) : tab.title
            let bookmarked = dataStore.isBookmarked(url.absoluteString)
            items.append(PopupMenuItem(
                title: bookmarked ? "移除书签" : "添加到书签",
                systemImage: bookmarked ? "star.slash" : "star"
            ) {
                dataStore.toggleBookmark(
                    title: title,
                    url: url.absoluteString,
                    favicon: tab.faviconURL?.absoluteString
                )
            })
        }

        items.append(PopupMenuItem(title: "书签", systemImage: "bookmark") { showingBookmarks = true })
        items.append(PopupMenuItem(title: "历史记录", systemImage: "clock") { showingHistory = true })
        items.append(PopupMenuItem(title: "浏览器设置", systemImage: "gearshape") { showingSettings = true })

        return items
    }
}

/// 单个标签的内容容器：以 `@ObservedObject` 持有标签，使标签的状态变化
private struct BrowserTabContent: View {
    @ObservedObject var tab: BrowserTab
    let isActive: Bool
    /// 收起操作栏为胶囊（仅滑动页面触发；刷新 / 回退 / 前进等操作栏操作不触发）
    let onCollapseToolbar: () -> Void
    /// 当前页面地址变化（nil 表示回到起始页）
    let onURLChange: (URL?) -> Void

    var body: some View {
        BrowserView(tab: tab)
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
            // **唯一**的收起入口：滑动页面（任意方向；起始页除外，只有点击胶囊才恢复地址栏）。
            .onChange(of: tab.scrollTick) { _ in collapseIfNeeded() }
            .onChange(of: tab.currentURL) { url in
                guard isActive else { return }
                onURLChange(url)
            }
    }

    private func collapseIfNeeded() {
        guard isActive, !tab.isShowingStartPage else { return }
        onCollapseToolbar()
    }
}

/// 标签网格滚动偏移上报：minY >= 0 表示已回到顶部。
private struct TabGridScrollOffsetKey: PreferenceKey {
    /// 「没有任何视图上报」时的哨兵值——**刻意不用 0**。
    static var defaultValue: CGFloat = -.infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Safari 风格标签卡片网格（新建/关闭/切换 + 无痕开关）
private struct TabGridView: View {
    @EnvironmentObject private var session: BrowserSessionStore
    @Environment(\.dismiss) private var dismiss

    /// 当前被长按拖动的标签（用于实时重排 + 拖动态视觉反馈）
    @State private var draggingTab: BrowserTab?

    /// 下滑关闭的跟手位移
    @State private var dragOffset: CGFloat = 0
    /// 列表当前滚动偏移（0 为顶部，负值为已向下滚动）：由顶部零高探测器经 preference 上报
    @State private var scrollOffset: CGFloat = 0
    /// 本次下滑关闭的基准位移：**列表到达最上方那一刻**的手势纵向位移。
    @State private var dragAnchor: CGFloat?
    /// 上一次手势回调的时间：用于识别「上一段拖动被系统打断、没有回调 `onEnded`」后残留的状态。
    @State private var lastDragTime = Date.distantPast
    /// 已触发关闭（或正在退场）：此后手势与偏移回写都不再改 `dragOffset`
    @State private var isDismissing = false

    /// 固定两列（方案 A）：卡片宽度按屏宽均分，缩略图比例稳定
    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    /// 打开网格时单次补抓的缩略图上限：标签多时避免一次拉起十几个快照
    private static let maxThumbnailCaptures = 12

    /// 关闭阈值：位移超过 110pt，或按松手速度外推的终点超过 220pt（轻扫即关）。
    private let dismissDistance: CGFloat = 110
    private let dismissFlickDistance: CGFloat = 220

    var body: some View {
        // 自动定位到当前标签：定位要用 `ScrollViewReader` 给的 proxy
        ScrollViewReader { positionProxy in
            VStack(spacing: 0) {
                header
                tabGrid
            }
            // 画布色铺满全屏（含状态栏区域），与原型一致：浅灰底托住白卡
            .background(AppColors.gridCanvas.ignoresSafeArea())
            // 整体跟手下移（含标题栏与底部栏），松手未过阈值则弹回
            .offset(y: dragOffset)
            .safeAreaInset(edge: .bottom) { bottomBar }
            // 打开即对齐到当前标签并补齐缩略图
            .onAppear {
                scrollToActiveTab(positionProxy)
                primeThumbnails()
            }
        }
    }

 // MARK: - 顶部标题栏

    /// 顶部只保留「大标题 + 数量 chip」（方案 A）：完成 / 无痕全部下放到底栏
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(session.isIncognito ? "无痕浏览" : "标签页")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(AppColors.textPrimary)

            Text("\(session.visibleTabs.count)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColors.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(AppColors.fieldFill))
                // 与标题基线对齐：chip 比 28pt 标题矮很多，交给 firstTextBaseline 会偏上
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

 // MARK: - 网格

    private var tabGrid: some View {
        ScrollView {
            // 顶部零高探测器：滚动偏移经 preference 上报，限定下滑关闭只在顶部生效
            GeometryReader { geometry in
                Color.clear.preference(
                    key: TabGridScrollOffsetKey.self,
                    value: geometry.frame(in: .named("tabGridScroll")).minY
                )
            }
            .frame(height: 0)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(session.visibleTabs) { tab in
                    // 带上 id，供 `ScrollViewReader` 把当前标签滚进视口
                    tabCard(tab).id(tab.id)
                }
            }
            .padding(16)
        }
        .coordinateSpace(name: "tabGridScroll")
        .onPreferenceChange(TabGridScrollOffsetKey.self) { value in
            scrollOffset = value
            // 列表一旦离开最上方，任何已产生的跟手位移立刻作废
            if !isDismissing, value.isFinite, value < -1, dragOffset != 0 {
                cancelDismissDrag()
            }
        }
        // 下滑关闭：与滚动同时识别，故用 `simultaneousGesture`。
        .simultaneousGesture(dismissDrag)
    }

    /// 打开网格时补抓缩略图：当前标签优先，单次最多 12 张。
    private func primeThumbnails() {
        let tabs = session.visibleTabs
        let active = tabs.filter { $0.id == session.activeTabID }
        let others = tabs.filter { $0.id != session.activeTabID }
        for tab in (active + others).prefix(Self.maxThumbnailCaptures) {
            tab.captureThumbnailIfNeeded()
        }
    }

 // MARK: - 下滑关闭手势

    /// 从空白区域（或列表最上方）下滑关闭标签页。
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .global)
            .onChanged { value in
                guard !isDismissing, draggingTab == nil else { return }

                // 上一段拖动被系统打断（切后台 / 被其它识别器抢占）时不会回调 `onEnded`
                if value.time.timeIntervalSince(lastDragTime) > 0.2,
                   abs(value.translation.height) <= 24,
                   abs(value.translation.width) <= 24 {
                    dragAnchor = nil
                    if dragOffset != 0 { dragOffset = 0 }
                }
                lastDragTime = value.time

                // 列表还没滚到最上方 / 手指在往上：整段手势让给列表滚动，并立刻作废跟手位移。
                guard scrollOffset >= -1, value.translation.height > 0 else {
                    cancelDismissDrag()
                    return
                }

                // 列表刚到达最上方：此刻的手势位移已全部被列表滚动消耗掉，作为基准扣掉
                if dragAnchor == nil { dragAnchor = value.translation.height }
                guard let anchor = dragAnchor else { return }

                // 仅向下、且以纵向位移为主（横向滑动交给其它交互）
                guard value.translation.height > abs(value.translation.width) else { return }
                dragOffset = max(0, value.translation.height - anchor)
            }
            .onEnded { value in
                let anchor = dragAnchor
                // 用「实际跟手出去的距离」判定距离阈值，与用户看到的位移严格一致
                let travelled = dragOffset
                dragAnchor = nil
                lastDragTime = .distantPast
                guard !isDismissing, draggingTab == nil, anchor != nil, travelled > 0 else {
                    // 整段手势都被判定为「滚动列表」：不关闭，也不要有残留位移
                    cancelDismissDrag()
                    return
                }
                let reachedByDistance = travelled > dismissDistance
                let reachedByFlick = value.predictedEndTranslation.height - (anchor ?? 0) > dismissFlickDistance
                guard reachedByDistance || reachedByFlick else {
                    cancelDismissDrag()
                    return
                }
                isDismissing = true
                dismiss()
            }
    }

    /// 作废本次下滑关闭：清掉基准并把跟手位移弹回 0，不关闭。
    private func cancelDismissDrag() {
        if dragAnchor != nil { dragAnchor = nil }
        guard dragOffset != 0 else { return }
        withAnimation(.appFast) { dragOffset = 0 }
    }

 // MARK: - 自动定位到当前标签

    /// 打开标签网格时把当前标签滚进视口。
    private func scrollToActiveTab(_ positionProxy: ScrollViewProxy) {
        guard let activeID = session.activeTabID,
              session.visibleTabs.contains(where: { $0.id == activeID })
        else { return }
        positionProxy.scrollTo(activeID, anchor: .center)
        Task { @MainActor in
            // 网格入场时首帧布局与页面切换交错，隔一帧再对齐一次兜底
            try? await Task.sleep(nanoseconds: 80_000_000)
            positionProxy.scrollTo(activeID, anchor: .center)
        }
    }

 // MARK: - 标签卡片

    private func tabCard(_ tab: BrowserTab) -> some View {
        let isActive = tab.id == session.activeTabID
        return TabThumbnailCard(
            tab: tab,
            isActive: isActive,
            onSelect: {
                session.switchTab(tab.id)
                dismiss()
            },
            onClose: { session.closeTab(tab.id) }
        )
        // 长按拖动排序：拖起时记录来源，拖入其它卡片时实时重排
        .onDrag {
            draggingTab = tab
            return NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .onDrop(
            of: [.plainText],
            delegate: TabDropDelegate(item: tab, dragging: $draggingTab, session: session)
        )
        .opacity(draggingTab?.id == tab.id ? 0.35 : 1)
    }

 // MARK: - 底部操作

    /// 通栏胶囊（与主界面 Tab 栏同宽同高）：左「圆形 ＋」、右「无痕 ｜ 完成」。
    private var bottomBar: some View {
        HStack(spacing: 0) {
            // 新建：只留圆形 ＋，不写「新建标签」文字，语义由加号承担
            Button(action: newTabAndEnter) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(AppColors.primary)
                            .shadow(color: AppColors.primary.opacity(0.35), radius: 4, y: 2)
                    )
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(CirclePressButtonStyle())

            Spacer(minLength: 8)

            incognitoSwitch

            Rectangle()
                .fill(AppColors.separator)
                .frame(width: 1, height: 22)
                .padding(.horizontal, 12)

            doneButton
        }
        .padding(.horizontal, 10)
        .frame(height: 56)
        .background(ChromeCapsule())
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
        // 底栏挂在 `safeAreaInset` 上：画布色要自己衔接到屏幕底边
        .background(AppColors.gridCanvas.ignoresSafeArea(edges: .bottom))
    }

    /// 无痕：眼睛图腾 + 文字 + 开关。状态由开关本身呈现，不需要再靠图标点亮来暗示。
    private var incognitoSwitch: some View {
        HStack(spacing: 6) {
            Image(systemName: session.isIncognito ? "eye.slash.fill" : "eye")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(session.isIncognito ? AppColors.primary : AppColors.textSecondary)

            Text("无痕")
                .font(.system(size: 12.5))
                .foregroundStyle(AppColors.textPrimary)

            Toggle(isOn: Binding(
                get: { session.isIncognito },
                set: { _ in session.toggleIncognito() }
            )) {
                Text("无痕")
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(AppColors.primary)
            // 系统开关视觉偏大（51×31），压到 0.82 与左侧文字、右侧胶囊同重
            .scaleEffect(0.82)
        }
        .accessibilityElement(children: .combine)
    }

    /// 完成：淡蓝胶囊（暗色为深蓝底 + 浅蓝字），替代原来的导航栏左按钮
    private var doneButton: some View {
        Button {
            dismiss()
        } label: {
            Text("完成")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppColors.primary)
                .padding(.horizontal, 15)
                .frame(height: 34)
                .background(Capsule().fill(AppColors.gridDoneFill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

 // MARK: - 行为

    /// 新建标签并**自动进入**：先给按钮一次完整的按压回弹，再收起网格
    private func newTabAndEnter() {
        // 与其它自绘控件一致：按压即给一次轻触觉，确认这一下被吃到了
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()

        // 新标签成为激活标签（`activeTabID` 变化会带动底部浮层收展动画，见 `BrowserHomeView`）
        session.newTab()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            dismiss()
        }
    }
}

/// 底栏圆形「＋」的按压样式：按钮自带主色圆底
private struct CirclePressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(configuration.isPressed ? nil : .appFast, value: configuration.isPressed)
    }
}

/// 标签卡片拖拽排序代理：拖入目标卡片时实时交换顺序，落下时清除拖动态
private struct TabDropDelegate: DropDelegate {
    let item: BrowserTab
    @Binding var dragging: BrowserTab?
    let session: BrowserSessionStore

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging.id != item.id else { return }
        withAnimation(.appFast) {
            session.moveTab(fromID: dragging.id, toID: item.id)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

// MARK: - 标签卡片

/// 一张标签卡：上半部网页缩略图（未就绪 / 无痕时走品牌色占位），下半部 38pt 图标 + 标题条。
private struct TabThumbnailCard: View {
    @ObservedObject var tab: BrowserTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    private let corner: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            preview
                .frame(height: 112)
                .frame(maxWidth: .infinity)
                .clipped()

            caption
        }
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        // 于是「关掉当前页」只能先切到别的标签再关，多一步且不直观。
        .overlay(alignment: .topTrailing) {
            closeButton.padding(6)
        }
        .overlay(alignment: .topLeading) {
            if isActive { currentBadge.padding(6) }
        }
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(
                    isActive ? AppColors.primary : AppColors.cardBorder,
                    lineWidth: isActive ? 2 : 0.8
                )
        )
        // 投影挂在底板形状上（而不是整卡）：避免 `clipped()` 把描边和阴影一起裁掉
        .background(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(AppColors.cardBackground)
                .shadow(
                    color: isActive ? AppColors.primary.opacity(0.28) : Color.black.opacity(0.06),
                    radius: isActive ? 10 : 6,
                    y: isActive ? 4 : 2
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var accessibilityTitle: String {
        let name = tab.title.isEmpty ? "新标签页" : tab.title
        return isActive ? "\(name)，当前标签页" : name
    }

    @ViewBuilder
    private var preview: some View {
        if let image = tab.thumbnail {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            ThumbnailPlaceholder(url: tab.currentURL, isIncognito: tab.isIncognito)
        }
    }

    private var caption: some View {
        HStack(spacing: 6) {
            favicon

            Text(tab.title.isEmpty ? "新标签页" : tab.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if tab.isLoading {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 38)
        .frame(maxWidth: .infinity)
    }

    private var favicon: some View {
        Group {
            if let url = tab.faviconURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit()
                    } else {
                        globeIcon
                    }
                }
            } else {
                globeIcon
            }
        }
        .frame(width: 14, height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    private var globeIcon: some View {
        Image(systemName: "globe")
            .font(.system(size: 10))
            .foregroundStyle(AppColors.textSecondary)
    }

    /// 关闭键：收进缩略图右上角（半透明白底小圆）。当前标签同样显示——关掉它
    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.92)))
                .shadow(color: Color.black.opacity(0.14), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭标签页")
    }

    private var currentBadge: some View {
        Text("当前")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(AppColors.primary))
    }
}

/// 缩略图占位（也是无痕标签的固定形态）
private struct ThumbnailPlaceholder: View {
    let url: URL?
    let isIncognito: Bool

    var body: some View {
        let brand = isIncognito ? AppColors.textSecondary : SiteBrandColor.color(for: url)
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [brand.opacity(0.16), brand.opacity(0.05)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(AppColors.textPrimary.opacity(0.16))
                            .frame(width: 4, height: 4)
                    }
                    Capsule()
                        .fill(AppColors.textPrimary.opacity(0.12))
                        .frame(height: 5)
                        .padding(.leading, 2)
                }
                Capsule().fill(AppColors.textPrimary.opacity(0.13)).frame(width: 96, height: 5)
                Capsule().fill(AppColors.textPrimary.opacity(0.11)).frame(width: 62, height: 5)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(brand.opacity(0.22))
                    .frame(height: 46)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 9)

            Image(systemName: isIncognito ? "eye.slash" : "globe")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(brand.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .center)
                .offset(y: 56)
        }
    }
}

/// 站点品牌色：按主域稳定散列到一组品牌色，同一站点永远是同一色（纯本地计算，零网络成本）。
enum SiteBrandColor {
    private static let palette: [Color] = [
        Color(hex: 0x2563EB),
        Color(hex: 0x24292F),
        Color(hex: 0xFB7299),
        Color(hex: 0xD71A1B),
        Color(hex: 0x111111),
        Color(hex: 0x0066FF),
        Color(hex: 0x1F2937),
        Color(hex: 0x7C3AED)
    ]

    static func color(for url: URL?) -> Color {
        guard let host = url?.host?.lowercased(), !host.isEmpty else {
            return AppColors.textSecondary
        }
        // 只取主域：docs.example.com 与 www.example.com 同色
        let parts = host.split(separator: ".")
        let key = parts.count >= 2 ? parts.suffix(2).joined(separator: ".") : host

        var hash: UInt64 = 5381
        for scalar in key.unicodeScalars {
            hash = (hash &* 33) &+ UInt64(scalar.value)
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}
