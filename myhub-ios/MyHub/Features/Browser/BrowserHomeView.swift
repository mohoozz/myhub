import SwiftUI
import UniformTypeIdentifiers

/// 内置浏览器主页（TODO §8.1/§8.2，IOS-401）：
/// 标签内容保活区 + 底部操作栏（含居中地址栏，滚动收起为小胶囊/下滑或点击展开，Safari 风格）。
/// Safari 风格卡片网格标签管理（新建/关闭/切换 + 无痕开关）。
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
    /// 地址栏是否处于编辑态（TODO 407）：由本视图持有——操作栏据此整体变为输入条，
    /// 网页上的可点遮罩与左下角退出钮的显隐也都要读这个状态，故不能封在 `AddressBar` 内部。
    @State private var addressEditing = false

    /// 底部浮层「小胶囊 ⇄ 操作栏」形变的共享命名空间（F1 + A1）：
    /// 两种形态的胶囊底共用同一 `matchedGeometryEffect` 身份，切换时是一块底在长大 / 缩回，
    /// 而不是两条视图交叉淡入淡出（旧实现中间帧会同时出现一大一小两条，读成闪跳）。
    @Namespace private var chromeMorphNS

    /// 底部浮层形态切换曲线（A1）：单容器形变的轻弹簧。
    /// 旧实现用的 `.appFast`（150ms 缓出）只适合按压反馈，做形态变化太短、收尾生硬；
    /// 这里 340ms + 高阻尼，落位时「弹一下坐住」，且不回弹过头。
    private static let chromeMorph = Animation.spring(response: 0.34, dampingFraction: 0.86)

    /// 操作栏 / 收起态小胶囊与底部页签栏之间的视觉间距（左右内缩 12pt 形成上下「双胶囊」节奏）
    private let tabBarGap: CGFloat = 12

    /// 沉浸态下浮层底边到「屏幕物理底边」的距离（F1）：21pt = Home 指示条可见横条上沿（约 13pt）+ 8pt。
    ///
    /// 旧实现是相对「系统底部安全区」留 8pt，而安全区本身就占 34pt（为指示条与系统手势预留），
    /// 两者叠加后胶囊底边离屏幕底边有 42pt ≈ 8mm，看起来正是「浮在半空、离底部还差一小截」。
    /// 现在浮层在沉浸态下自己忽略底部安全区（见 `bottomChrome` 的 `ignoresSafeArea`），
    /// 这个值直接从屏幕物理底边量起，才是真的「贴底」。
    private let immersiveBarGap: CGFloat = 21

    /// 沉浸态（原型 `prototype/browser-exit-handle-collapse-options.html` 策略 S1）：
    /// iPhone 上停留在「浏览器」页签期间隐藏全局页签栏与 mini 播放器，把约 128pt 竖向空间还给网页；
    /// 退出由左下角 `BrowserExitHandle` 触发——回到进入浏览器前的页签，底部装饰随之恢复。
    /// iPad 走侧边栏导航、本就无底部页签栏，不进入沉浸态。
    private var isImmersive: Bool {
        horizontalSizeClass == .compact && router.selectedTab == .browser
    }

    /// 汇报浏览器页的真实可见性（页签为浏览器且无全屏播放器遮挡）：
    /// 会话恢复的标签只有在这一刻才加载网页；不可见时暂停所有页面媒体（TODO 418）
    private func syncBrowserVisibility() {
        session.setBrowserVisible(router.selectedTab == .browser && !player.isFullscreen)
    }

    /// 底部预留间距：与页签栏留一段距离；
    /// 有 mini 播放器时再叠加上封面向上溢出量（`MiniPlayer.coverOverflow` 是 `.offset` 视觉位移、
    /// 不参与布局测量，页面底边实际落在 mini 卡片上边界，不补偿就会与突出的封面贴太紧）。
    /// 沉浸态下底部装饰已整体隐藏（`RootView.phoneBottomChrome` 高度归零），浮层直接贴着系统底部安全区，
    /// 间距即「距 Home 指示条 8pt」；非沉浸态仍按页签栏口径留 12pt（+ mini 播放器封面溢出补偿）。
    private var bottomBarGap: CGFloat {
        if isImmersive { return immersiveBarGap }
        return player.isMini ? tabBarGap + MiniPlayer.coverOverflow : tabBarGap
    }

    /// 网页层是否铺满整屏（F1）：仅沉浸态 + 已打开真实网页时生效。
    /// 起始页是我们自绘的搜索页，搜索框不该钻到刘海下面，故仍按安全区排布；
    /// 这个开关只影响网页层，底部浮层始终相对安全区底部定位，因此页面加载时浮层不会跳动。
    private var contentIgnoresSafeArea: Bool {
        guard isImmersive, let tab = session.activeTab else { return false }
        return !tab.isShowingStartPage
    }

    /// 网页层要压满的安全区边缘（F1）：全屏时上下一起压到屏幕边，其余情况维持安全区排布
    private var fullBleedEdges: Edge.Set {
        contentIgnoresSafeArea ? [.top, .bottom] : []
    }

    /// 左下角退出钮的垂直落点：底部操作栏胶囊之上 10pt。
    /// 固定取展开态操作栏高度，使其在操作栏收为小胶囊时位置不跳动。
    private var exitHandleBottomInset: CGFloat {
        bottomBarGap + BrowserToolbar.barHeight + 10
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // 网页层（F1）：沉浸态下铺满整屏——顶部压到状态栏、底部压到 Home 指示条，上下不再留白。
            // 起始页（自绘 UI，搜索框不该钻刘海）仍按安全区排布，见 `contentIgnoresSafeArea`。
            contentArea
                .ignoresSafeArea(.container, edges: fullBleedEdges)

            // 编辑态遮罩（Safari 风格）：压暗网页并吃掉点击，点任意处即取消编辑。
            // 与网页层同为「压满全屏」的兄弟层，但不盖底部浮层，避免挡住输入框与「取消」。
            if addressEditing {
                Color.black.opacity(0.10)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { addressEditing = false }
                    .transition(.opacity)
            }

            // 底部浮层（F1 + A1）：操作栏 / 小胶囊浮在网页之上，不再与网页上下分栏——
            // 展开收起时网页高度不再变化（旧动画卡顿的主因：WKWebView 每帧都要重排重绘）。
            // 沉浸态下自己忽略底部安全区：`bottomBarGap` 从屏幕物理底边量起，
            // 否则 34pt 安全区会与间距叠加，胶囊看起来离底部还差一小截（用户反馈的"浮在半空"）。
            bottomChrome
                .ignoresSafeArea(.container, edges: isImmersive ? .bottom : [])

            // 沉浸态左下角退出钮（+ 有播放会话时的播放微件）：
            // 收缩态与操作栏的 `toolbarMini` 同源联动（T1），贴边半隐仅露 14pt。
            // 编辑态整体隐藏：该钮按展开态条高定位，键盘弹起后操作栏已被系统抬走，
            // 它会悬在半空并与输入框抢视线（TODO 407）。
            if isImmersive, !addressEditing {
                HStack(spacing: 0) {
                    BrowserExitHandle(collapsed: toolbarMini, onExit: exitImmersive)
                        .padding(.bottom, exitHandleBottomInset)
                        .transition(.opacity)
                    Spacer(minLength: 0)
                }
                // 与底部浮层同一套基准：退出钮按展开态条高定位，浮层下沉多少它也要下沉多少，
                // 否则会与操作栏之间凭空多出 34pt 安全区的空档
                .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        .background(AppColors.pageBackground)
        .animation(Self.chromeMorph, value: toolbarMini)
        .animation(.appFast, value: addressEditing)
        .onChange(of: session.activeTabID) { _ in
            // 打开/切换到网页标签 → 收为胶囊；起始页（需输入网址）→ 展开地址栏
            toolbarMini = !(session.activeTab?.isShowingStartPage ?? true)
            // 切标签时地址栏内容已换页，留在编辑态会继续编辑上一个页面的 URL
            addressEditing = false
        }
        // 沉浸态开关同步（S1）：`RootView` 以 ZStack 保活各页签（切页签不触发 onDisappear），
        // 故必须由 `router.selectedTab` 驱动，不能依赖本视图的进出场
        .onChange(of: router.selectedTab) { tab in
            bottomTabBarHidden.wrappedValue = (horizontalSizeClass == .compact && tab == .browser)
            // 网页加载时机同步（TODO 418）：本视图启动即构建，但只有真正显示时才应加载网页
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
                // 会话恢复但尚未显示的标签不挂载视图：不创建 WKWebView、不渲染（TODO 418）。
                // 激活标签例外——它马上会在 `syncActiveTab()` 中补加载，随即进入已加载态。
                if !tab.isPendingRestore || tab.id == session.activeTabID {
                    // 标签状态变化（滚动 / 刷新 / 导航）必须由持有 `@ObservedObject` 的子视图接收，
                    // 否则 onChange 不会被及时求值（见 `BrowserTabContent` 注释，TODO 399）
                    BrowserTabContent(
                        tab: tab,
                        isActive: tab.id == session.activeTabID,
                        onCollapseToolbar: collapseToolbar,
                        onURLChange: { url in
                            // 打开新界面（导航到网页）→ 胶囊；回退到起始页 → 展开地址栏
                            toolbarMini = (url != nil)
                            // 地址已随页面变化，编辑态若残留会继续编辑上一页 URL（如提交后又被重定向，TODO 407）
                            addressEditing = false
                        }
                    )
                }
            }
        }
    }

    // MARK: - 底部浮层（展开态操作栏 / 收起态小胶囊）

    /// 底部浮层的唯一出口：同一位置上二选一，二者共用 `chromeMorphNS` 的胶囊底（F1 + A1）。
    /// 内容只做透明度交叉（无位移、无缩放），几何变化全部交给那块共享的胶囊底去形变，
    /// 因此切换过程中屏上始终只有「一块底」，不会再出现旧实现那种一大一小两条同屏的重叠。
    @ViewBuilder
    private var bottomChrome: some View {
        if let tab = session.activeTab {
            if toolbarMini, !tab.isShowingStartPage {
                // 加上热区补的 8pt：让「视觉胶囊」而不是热区落到与操作栏同一水平线上
                miniCapsule(tab)
                    .padding(.bottom, bottomBarGap + Self.capsuleHitInset)
                    // 只做透明度交叉：位移/缩放交给共享胶囊底的形变，
                    // 也不要给 transition 单独挂动画——那会把同一事务里的形态形变一起改成短时长
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
    /// 页签切换由 `onChange(of: router.selectedTab)` 统一回写隐藏开关，此处不重复置位。
    private func exitImmersive() {
        router.backToPreviousTab()
    }

    private func expandToolbar() {
        guard toolbarMini else { return }
        // 显式包一层弹簧（A1）：点击展开的落位动画由形变的同一曲线驱动，收尾「弹一下坐住」
        withAnimation(Self.chromeMorph) { toolbarMini = false }
    }

    /// 收起为底部小胶囊（滑动页面 / 刷新页面触发）。
    /// 编辑态下不收起：操作栏正在充当输入框，此时收成小胶囊会让键盘悬在空处（TODO 407）。
    private func collapseToolbar() {
        guard !toolbarMini, !addressEditing else { return }
        toolbarMini = true
    }

    // MARK: - 收起态小胶囊（Safari 风格）

    /// 收起态小胶囊的视觉高度（S1 → H2）：32pt 是在 28pt「细线感」与 44pt「胖药丸」之间的取值，
    /// 只多 4pt 视觉高度就能让域名上下留白变匀、圆角（16pt）与页签栏胶囊语言更接近（见原型 H0–H4）。
    private static let capsuleHeight: CGFloat = 32
    /// 视觉胶囊外再补的透明内边距（上下各 6pt）：32 + 6×2 = 44pt，命中区仍满足 iOS 下限（TODO 406）
    private static let capsuleHitInset: CGFloat = 6

    /// 收起态胶囊里显示的域名（W1）：按内容贴合，超长才中段省略。
    ///
    /// 不用 `.frame(maxWidth:)` 收口：胶囊外层用了 `fixedSize(horizontal:)`（不这么写就会被
    /// ZStack 的整宽提案拉成 227pt 的长条），此时 `maxWidth` 拿不到确定宽度、截断不出省略号、
    /// 只剩硬裁切。改为「字符预算 + 手写省略号」，宽度确定、也不会出现半截字形。
    /// 18 字符 ≈ 12pt 字下 130pt，正好卡在 W1 的 132pt 上限内。
    private func capsuleHost(_ tab: BrowserTab) -> String {
        let host = tab.currentURL?.host ?? "网页"
        guard host.count > 18 else { return host }
        // 保留头 9 + 尾 6：既认得出站点，也留得住 .com / .cn 这类后缀
        return "\(host.prefix(9))…\(host.suffix(6))"
    }

    /// 操作栏收起后缩为底部中央的小胶囊：只显示域名，点击展开完整操作栏。
    ///
    /// 尺寸对齐 Safari（S1 + H2 + W5，见 `prototype/browser-fullscreen-options.html`）：
    /// 视觉 32pt 高 / 12pt 字 / 左右 11pt，外面再套 6pt 透明内边距把点击热区补到 44pt —— 视觉小、命中不变。
    /// 不再画 HTTPS 锁图标（W5）：常态只留域名，胶囊宽度直接少 21pt；证书状态仍由展开态地址栏承担。
    /// 宽度按内容贴合而不是 `maxWidth: 190`（W1）——旧写法把短语域名也撑到 190pt，胶囊就变成长条。
    /// 胶囊底交给 `ChromeCapsule` 并与操作栏共享形变身份（A1），展开时是同一块底长大成整条操作栏。
    private func miniCapsule(_ tab: BrowserTab) -> some View {
        Button {
            expandToolbar()
        } label: {
            Text(capsuleHost(tab))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(1)
                // 按内容贴合（W1）：不加 fixedSize，胶囊会被外层整宽提案撑成 227pt 的横条
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

/// 单个标签的内容容器（TODO 399）：以 `@ObservedObject` 持有标签，使标签的状态变化
/// （`scrollTick` / `reloadTick` / `currentURL`）能驱动本视图 body 重算，从而让 `onChange` 即时触发。
///
/// 此前这几个 `onChange` 挂在 `BrowserHomeView` 的 body 里，而父视图并未观察 `BrowserTab`
/// （`tab` 只是 `ForEach` 的循环变量），`onChange` 比较的旧值只在父 body 重算时才刷新，导致：
/// ①展开操作栏后滑动 / 刷新页面不会收起（父 body 不重算，差异永远比较不出来）；
/// ②点击胶囊展开时父 body 重算，此刻才「迟到」地比较出之前滚动产生的差异，操作栏刚展开又被改回收起态
/// （表现为第一次点击有按压动画但没展开，需要点第二次）。
private struct BrowserTabContent: View {
    @ObservedObject var tab: BrowserTab
    let isActive: Bool
    /// 收起操作栏为胶囊（滑动页面 / 刷新页面）
    let onCollapseToolbar: () -> Void
    /// 当前页面地址变化（nil 表示回到起始页）
    let onURLChange: (URL?) -> Void

    var body: some View {
        BrowserView(tab: tab)
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
            // 滑动页面即收为胶囊（任意方向；起始页除外，只有点击胶囊才恢复地址栏）
            .onChange(of: tab.scrollTick) { _ in collapseIfNeeded() }
            // 刷新页面（工具栏刷新键 / 下拉刷新 / 错误页重试）同样收为胶囊
            .onChange(of: tab.reloadTick) { _ in collapseIfNeeded() }
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

/// 标签网格滚动偏移上报（TODO 409）：minY >= 0 表示已回到顶部。
/// 用于限定「下滑关闭」只在列表顶部触发——否则在长列表中间下滑时，
/// 本该是「向上滚动列表」的操作会被误判为关闭手势。
/// 与 `BrowseScrollOffsetKey`（TODO 336）同一套做法：零高探测器 + preference 上报。
private struct TabGridScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Safari 风格标签卡片网格（新建/关闭/切换 + 无痕开关，IOS-401）
private struct TabGridView: View {
    @EnvironmentObject private var session: BrowserSessionStore
    @Environment(\.dismiss) private var dismiss

    /// 当前被长按拖动的标签（用于实时重排 + 拖动态视觉反馈）
    @State private var draggingTab: BrowserTab?

    /// 下滑关闭的跟手位移（TODO 409）
    @State private var dragOffset: CGFloat = 0
    /// 列表是否处于顶部：仅顶部允许下滑关闭，避免与「向上滚动列表」争抢
    @State private var atTop = true

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    /// 关闭阈值：位移超过 110pt，或按松手速度外推的终点超过 220pt（轻扫即关）。
    /// 与 mini 播放器下滑收起（`MiniPlayer`）取同一量级，手感统一。
    private let dismissDistance: CGFloat = 110
    private let dismissFlickDistance: CGFloat = 220

    var body: some View {
        NavigationStack {
            ScrollView {
                // 顶部零高探测器：滚动偏移经 preference 上报，限定下滑关闭只在顶部生效
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: TabGridScrollOffsetKey.self,
                        value: proxy.frame(in: .named("tabGridScroll")).minY
                    )
                }
                .frame(height: 0)

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(session.visibleTabs) { tab in
                        tabCard(tab)
                    }
                }
                .padding(16)
            }
            .coordinateSpace(name: "tabGridScroll")
            .onPreferenceChange(TabGridScrollOffsetKey.self) { value in
                // 留 1pt 容差：顶部回弹时 minY 会在 0 附近抖动
                atTop = value >= -1
            }
            // 下滑关闭（TODO 409）：与滚动同时识别，故用 `simultaneousGesture`——
            // 非顶部时降级为 `.subviews`，把手势完全让给 ScrollView 的滚动与卡片自身交互。
            .simultaneousGesture(dismissDrag, including: atTop ? .all : .subviews)
            .background(AppColors.pageBackground)
            .navigationTitle(session.isIncognito ? "无痕浏览" : "标签页")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        session.toggleIncognito()
                    } label: {
                        Image(systemName: session.isIncognito ? "eye.slash.fill" : "eye")
                            .foregroundStyle(session.isIncognito ? AppColors.primary : AppColors.textSecondary)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                bottomBar
            }
        }
        // 整体跟手下移（含导航栏与底部栏），松手未过阈值则弹回
        .offset(y: dragOffset)
    }

    // MARK: - 下滑关闭手势

    /// 从空白区域（或列表顶部）下滑关闭标签页（TODO 409）。
    ///
    /// 坐标空间取 `.global`：本视图会随 `dragOffset` 整体下移，若用默认 `.local`，
    /// 视图自身位移会反过来改变 translation 的换算基准，形成正反馈 → 拖动抖动、跟随距离减半
    /// （与 `MiniPlayer` / 播放页 `GestureHandler` 同一处坑）。
    ///
    /// 卡片拖拽排序期间（`draggingTab != nil`）直接早退：`simultaneousGesture` 会与卡片的
    /// `onDrag` 同时识别，不排除的话长按拖动卡片时整个网格会跟着下移。
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .global)
            .onChanged { value in
                guard draggingTab == nil else { return }
                // 仅向下、且以纵向位移为主（横向滑动交给其它交互）
                guard value.translation.height > 0,
                      value.translation.height > abs(value.translation.width)
                else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                guard draggingTab == nil else {
                    withAnimation(.appFast) { dragOffset = 0 }
                    return
                }
                let reachedByDistance = value.translation.height > dismissDistance
                let reachedByFlick = value.predictedEndTranslation.height > dismissFlickDistance
                guard reachedByDistance || reachedByFlick else {
                    withAnimation(.appFast) { dragOffset = 0 }
                    return
                }
                dismiss()
            }
    }

    // MARK: - 标签卡片

    private func tabCard(_ tab: BrowserTab) -> some View {
        let isActive = tab.id == session.activeTabID
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                favicon(tab)
                Spacer()
                if tab.isLoading {
                    ProgressView().controlSize(.mini)
                }
            }
            Spacer(minLength: 0)
            Text(tab.title.isEmpty ? "新标签页" : tab.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(tab.currentURL?.host ?? "")
                .font(.caption)
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(height: 140)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isActive ? AppColors.highlightBackground : AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isActive ? AppColors.primary : AppColors.separator, lineWidth: isActive ? 1.5 : 0.5)
        )
        .overlay(alignment: .topTrailing) {
            Button {
                session.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppColors.textSecondary)
                    .padding(6)
                    .background(Circle().fill(AppColors.highlightBackground))
                    .padding(4)
            }
            .buttonStyle(.plain)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        .onTapGesture {
            session.switchTab(tab.id)
            dismiss()
        }
    }

    @ViewBuilder
    private func favicon(_ tab: BrowserTab) -> some View {
        if let url = tab.faviconURL {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFit()
                } else {
                    fallbackFavicon
                }
            }
            .frame(width: 20, height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            fallbackFavicon
        }
    }

    private var fallbackFavicon: some View {
        Image(systemName: "globe")
            .font(.caption)
            .foregroundStyle(AppColors.textSecondary)
            .frame(width: 20, height: 20)
    }

    // MARK: - 底部操作

    private var bottomBar: some View {
        HStack {
            Button {
                session.newTab()
            } label: {
                Label("新建标签", systemImage: "plus")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColors.primary)

            Spacer()

            Toggle(isOn: Binding(
                get: { session.isIncognito },
                set: { _ in session.toggleIncognito() }
            )) {
                Text("无痕")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textPrimary)
            }
            .toggleStyle(.switch)
            .tint(AppColors.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AppColors.cardBackground.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Divider().overlay(AppColors.separator) }
    }
}

/// 标签卡片拖拽排序代理（IOS-401）：拖入目标卡片时实时交换顺序，落下时清除拖动态
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
