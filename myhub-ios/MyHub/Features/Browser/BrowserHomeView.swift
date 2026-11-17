import SwiftUI
import UIKit
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
    /// 沉浸态下底部装饰已整体隐藏（`RootView.phoneBottomChrome` 高度归零），浮层在 ZStack 层已经
    /// 忽略底部安全区（见 `body` 末尾），这里量的是「距屏幕物理底边」——`immersiveBarGap` 21pt
    /// 即 Home 指示条上沿 13pt + 8pt。非沉浸态仍按页签栏口径留 12pt（+ mini 播放器封面溢出补偿）。
    private var bottomBarGap: CGFloat {
        if isImmersive { return immersiveBarGap }
        return player.isMini ? tabBarGap + MiniPlayer.coverOverflow : tabBarGap
    }

    /// 网页层是否铺满整屏（F1）：仅沉浸态 + 已打开真实网页时生效。
    /// 起始页是我们自绘的搜索页，搜索框不该钻到刘海下面，故仍按安全区排布。
    /// 它同时决定底部浮层的落点是否压到屏幕物理底边（见 `body` 末尾）：起始页浮层仍在安全区之上，
    /// 真实网页则与网页层一起贴底；两者切换恰好伴随「展开态 ⇄ 小胶囊」的形变，不会读成跳动。
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
            // 注意：这里**不能**挂 `ignoresSafeArea`——落点由外层 ZStack 的 `alignment: .bottom` 决定，
            // 加在子视图上改不动父级已经算好的对齐点（见 body 末尾 ZStack 上的说明）。
            bottomChrome

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
            }
        }
        // 沉浸态 + 真实网页：把整个浮层坐标系压到**屏幕物理底边**，而不是系统底部安全区底边。
        // 关键点：这一步必须加在 ZStack 上。加在 `bottomChrome` / 退出钮这类子视图上时，
        // ZStack 早已按安全区底边算好 `alignment: .bottom` 的落点，子视图的 `ignoresSafeArea`
        // 只扩大自己的可用区域、改不动父级给的位置，于是胶囊看起来永远「浮在离底一小截」
        // （用户两次反馈同一现象：只改 `immersiveBarGap` 没用）。放在容器这一层，
        // 安全区 34pt（以及隐藏后仍残留的页签栏 inset）才真的被吃掉。
        // 起始页不压满：搜索页是自绘 UI，底部内容不该钻到 Home 指示条下面。
        .ignoresSafeArea(.container, edges: contentIgnoresSafeArea ? .bottom : [])
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
        // 页面正在滑动时点击胶囊：这一轮滚动手势还没结束，紧随其后的 `scrollTick`
        // 会立刻把刚展开的操作栏收回去（表现为「有按压动画但没展开」）。
        // 让标签忽略本轮手势剩余的收起信号——手指重新按下开始新一轮拖动时自动解除，
        // 「展开后滑动页面收起操作栏」的既有行为不受影响。
        session.activeTab?.suppressScrollCollapseForCurrentGesture()
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
    /// 「没有任何视图上报」时的哨兵值——**刻意不用 0**（TODO 424）。
    ///
    /// 0 在本 key 里的语义是「列表正停在最上方」，而探测器在内容重建的某一帧里缺席时，
    /// preference 会回落到 `defaultValue`，等于向判定方谎报「已经到顶了」。
    /// 取负无穷后任何比较都落在「不在顶部」，宁可少一帧不能关闭，也不误触发关闭动画。
    static var defaultValue: CGFloat = -.infinity
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
    /// 列表当前滚动偏移（0 为顶部，负值为已向下滚动）：由顶部零高探测器经 preference 上报
    @State private var scrollOffset: CGFloat = 0
    /// 本次下滑关闭的基准位移：**列表到达最上方那一刻**的手势纵向位移（TODO 424）。
    ///
    /// 关闭位移只算「越过顶部的部分」（`translation.height - dragAnchor`）：
    /// 列表还没到顶时不管手指拖多远都只交给列表滚动，卡片一动不动；等列表滚到最上方、
    /// 手指继续往下，卡片才从 0 开始跟手。于是「页面内滚动」与「下滑关闭」严格分先后，
    /// 结构上不可能再同时发生——这正是此前两版修法的缺口（旧版按「起手瞬间是否在顶部」
    /// 一次性判定，且判定结果整段手势不再更新，一旦判定错了或偏移上报漏了一帧，
    /// 就会边滚边关）。`nil` 表示本次手势尚未接管（列表还没到顶，或手指在往上）。
    @State private var dragAnchor: CGFloat?
    /// 上一次手势回调的时间：用于识别「上一段拖动被系统打断、没有回调 `onEnded`」后残留的状态。
    /// 拖动过程中回调间隔是 8~16ms，间隔超过 0.2s 只可能是新的一段手势。
    @State private var lastDragTime = Date.distantPast
    /// 已触发关闭（或正在退场）：此后手势与偏移回写都不再改 `dragOffset`，
    /// 避免退场动画期间被「回弹归零」拽一下。
    @State private var isDismissing = false

    /// 固定两列（方案 A）：卡片宽度按屏宽均分，缩略图比例稳定；
    /// 原自适应列在 iPad 上会摊成 3~4 列，每列窄到 160pt 时截图已经认不出内容。
    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    /// 打开网格时单次补抓的缩略图上限：标签多时避免一次拉起十几个快照
    private static let maxThumbnailCaptures = 12

    /// 关闭阈值：位移超过 110pt，或按松手速度外推的终点超过 220pt（轻扫即关）。
    /// 与 mini 播放器下滑收起（`MiniPlayer`）取同一量级，手感统一。
    private let dismissDistance: CGFloat = 110
    private let dismissFlickDistance: CGFloat = 220

    var body: some View {
        // 自动定位到当前标签（TODO 422）：定位要用 `ScrollViewReader` 给的 proxy，
        // 故把整个网格包进 reader；真正的定位动作在 `.onAppear`（见 `scrollToActiveTab`）。
        ScrollViewReader { positionProxy in
            VStack(spacing: 0) {
                header
                tabGrid
            }
            // 画布色铺满全屏（含状态栏区域），与原型一致：浅灰底托住白卡
            .background(AppColors.gridCanvas.ignoresSafeArea())
            // 整体跟手下移（含标题栏与底部栏），松手未过阈值则弹回（TODO 409）
            .offset(y: dragOffset)
            .safeAreaInset(edge: .bottom) { bottomBar }
            // 打开即对齐到当前标签（TODO 422）并补齐缩略图（TODO 423）
            .onAppear {
                scrollToActiveTab(positionProxy)
                primeThumbnails()
            }
        }
    }

    // MARK: - 顶部标题栏

    /// 顶部只保留「大标题 + 数量 chip」（方案 A）：完成 / 无痕全部下放到底栏，
    /// 导航栏不再占一行，视觉重心落到卡片本身。
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
            // 列表一旦离开最上方，任何已产生的跟手位移立刻作废（TODO 424）：
            // 保证「卡片跟着手指往下走」只可能发生在列表已经滚到头之后。
            // 探测器缺席时上报的是 `-.infinity`，非有限值不参与这条判定（见 key 注释）。
            if !isDismissing, value.isFinite, value < -1, dragOffset != 0 {
                cancelDismissDrag()
            }
        }
        // 下滑关闭（TODO 409 / 419 / 424）：与滚动同时识别，故用 `simultaneousGesture`。
        // 手势常驻、不做条件挂载（旧版把「是否在顶部」写在 mask 上会让 SwiftUI 重建手势、
        // 累积位移一次性灌进 `onChanged`）。是否接管由**每帧实时判定**决定，见 `dismissDrag`。
        .simultaneousGesture(dismissDrag)
    }

    /// 打开网格时补抓缩略图（TODO 423）：当前标签优先，单次最多 12 张。
    /// 已有缓存（URL 未变）的标签在 `captureThumbnailIfNeeded()` 里直接命中，不会重复抓取。
    private func primeThumbnails() {
        let tabs = session.visibleTabs
        let active = tabs.filter { $0.id == session.activeTabID }
        let others = tabs.filter { $0.id != session.activeTabID }
        for tab in (active + others).prefix(Self.maxThumbnailCaptures) {
            tab.captureThumbnailIfNeeded()
        }
    }

    // MARK: - 下滑关闭手势

    /// 从空白区域（或列表最上方）下滑关闭标签页（TODO 409）。
    ///
    /// 坐标空间取 `.global`：本视图会随 `dragOffset` 整体下移，若用默认 `.local`，
    /// 视图自身位移会反过来改变 translation 的换算基准，形成正反馈 → 拖动抖动、跟随距离减半
    /// （与 `MiniPlayer` / 播放页 `GestureHandler` 同一处坑）。
    ///
    /// 卡片拖拽排序期间（`draggingTab != nil`）直接早退：`simultaneousGesture` 会与卡片的
    /// `onDrag` 同时识别，不排除的话长按拖动卡片时整个网格会跟着下移。
    ///
    /// 接管条件**每帧实时判定**（TODO 424），而不是像旧版那样在首个回调里一次性定死：
    /// - 列表没到最上方（`scrollOffset < -1`）或手指在往上 → 一律不接管，并且把已有位移清零；
    /// - 列表到达最上方的**那一刻**记下基准位移 `dragAnchor`，之后只把「越过顶部的部分」
    ///   算作关闭位移，所以「先滚到顶、再继续往下拖」是一条连续的、有先后的动作，
    ///   而不是「一边滚页面、一边把标签网格往下拉」。
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .global)
            .onChanged { value in
                guard !isDismissing, draggingTab == nil else { return }

                // 上一段拖动被系统打断（切后台 / 被其它识别器抢占）时不会回调 `onEnded`，
                // 用「间隔够久 + 位移还很小」识别「新的一段手势」，避免沿用上一段的基准与残留位移。
                // 加位移条件是因为手指按住在原地停顿同样会制造时间间隔，那种情况必须继续沿用基准，
                // 否则卡片会在停顿后突然弹回原位。
                if value.time.timeIntervalSince(lastDragTime) > 0.2,
                   abs(value.translation.height) <= 24,
                   abs(value.translation.width) <= 24 {
                    dragAnchor = nil
                    if dragOffset != 0 { dragOffset = 0 }
                }
                lastDragTime = value.time

                // 列表还没滚到最上方 / 手指在往上：整段手势让给列表滚动，并立刻作废跟手位移。
                // 这一条是「不同时触发」的硬保证——只要列表还能往上滚，卡片就一动不动。
                guard scrollOffset >= -1, value.translation.height > 0 else {
                    cancelDismissDrag()
                    return
                }

                // 列表刚到达最上方：此刻的手势位移已全部被列表滚动消耗掉，作为基准扣掉
                if dragAnchor == nil { dragAnchor = value.translation.height }
                guard let anchor = dragAnchor else { return }

                // 仅向下、且以纵向位移为主（横向滑动交给其它交互）；
                // 回拖到负值时位移归零，避免松手前出现「反向也跟手」
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
    /// 列表滚动期间每帧都会走到这里，必须足够廉价（无位移时直接返回，不触发额外重绘）。
    private func cancelDismissDrag() {
        if dragAnchor != nil { dragAnchor = nil }
        guard dragOffset != 0 else { return }
        withAnimation(.appFast) { dragOffset = 0 }
    }

    // MARK: - 自动定位到当前标签

    /// 打开标签网格时把当前标签滚进视口（TODO 422）。
    ///
    /// 标签一多，网格默认停在最顶部，当前标签常常在屏幕外——用户得先自己翻一遍才知道「我现在在哪一页」。
    /// 这里在出现时把当前标签滚到视口中央（Safari 的标签总览同样以当前页为中心）。
    ///
    /// 三个要点：
    /// - **无动画**：不包 `withAnimation`。定位发生在网格上滑入场的首帧，用户看到的是「一打开就停在这里」，
    ///   而不是「打开之后再挪一下」；
    /// - **锚点 `.center` 天然克制**：目标在前几行时，居中所需的偏移是负值，`ScrollView` 会夹到 0，
    ///   于是「当前标签本来就靠上」时画面纹丝不动，只有它确实在下方时才会滚动；
    /// - **补一次重试**：`LazyVGrid` 的卡片是按需实例化的，首帧可能还没算出目标位置，
    ///   首次 `scrollTo` 会落空；隔一帧再调一次——`scrollTo` 幂等，已对齐时不会有任何变化。
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
    /// 顶部导航栏不再放任何动作，全部收进这条底栏（方案 A）。
    private var bottomBar: some View {
        HStack(spacing: 0) {
            // 新建：只留圆形 ＋，不写「新建标签」文字，语义由加号承担；
            // 视觉 34pt，触控区补到 44pt。
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
        // 底栏挂在 `safeAreaInset` 上：画布色要自己衔接到屏幕底边，
        // 否则 home indicator 区域会露出 fullScreenCover 的系统底色。
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

    /// 新建标签并**自动进入**（TODO 420）：先给按钮一次完整的按压回弹，再收起网格；
    /// 网格下滑退场的同时新标签的起始页接手，地址栏也从收起态展开——一次连贯的「进入新标签页」。
    ///
    /// 0.12s 的延迟只为让按压动画播完：`dismiss()` 一旦开始全屏覆盖退场，底部栏会被一起带走，
    /// 按压回弹就看不到了（旧实现点一下毫无反馈，正是因为「无样式 + 不进入新标签」两件事）。
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

/// 底栏圆形「＋」的按压样式（TODO 420）：按钮自带主色圆底，
/// 只需缩放 + 与其它自绘控件一致的短缓出回弹。
/// 动画来源锁死为真实按压信号：按下瞬时跟手（nil），抬起才回弹——
/// 不这么写的话，外层转场事务（网格退场）会顺手驱动这里的插值（同 TODO 406 的坑）。
private struct CirclePressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(configuration.isPressed ? nil : .appFast, value: configuration.isPressed)
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

// MARK: - 标签卡片（方案 A：缩略图 + 标题条）

/// 一张标签卡：上半部网页缩略图（未就绪 / 无痕时走品牌色占位），下半部 38pt 图标 + 标题条。
///
/// 用 `@ObservedObject` 包住标签本身：缩略图是 `BrowserTab` 上的 `@Published`，
/// 抓取完成后这一张卡会自己刷新，不需要整个网格重算。
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
        .overlay(alignment: .topTrailing) {
            if !isActive { closeButton.padding(6) }
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

    /// 关闭键：收进缩略图右上角（半透明白底小圆），当前标签不显示，避免误关
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

/// 缩略图占位（也是无痕标签的固定形态）：
/// 站点品牌色淡淡铺一层 + 骨架线条，既表达「这里是一张网页」，又不冒充真实内容。
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
