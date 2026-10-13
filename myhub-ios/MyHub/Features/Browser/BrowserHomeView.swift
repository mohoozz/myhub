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

    /// 操作栏 / 收起态小胶囊与底部页签栏之间的视觉间距（左右内缩 12pt 形成上下「双胶囊」节奏）
    private let tabBarGap: CGFloat = 12

    /// 沉浸态（原型 `prototype/browser-exit-handle-collapse-options.html` 策略 S1）：
    /// iPhone 上停留在「浏览器」页签期间隐藏全局页签栏与 mini 播放器，把约 128pt 竖向空间还给网页；
    /// 退出由左下角 `BrowserExitHandle` 触发——回到进入浏览器前的页签，底部装饰随之恢复。
    /// iPad 走侧边栏导航、本就无底部页签栏，不进入沉浸态。
    private var isImmersive: Bool {
        horizontalSizeClass == .compact && router.selectedTab == .browser
    }

    /// 底部预留间距：与页签栏留一段距离；
    /// 有 mini 播放器时再叠加上封面向上溢出量（`MiniPlayer.coverOverflow` 是 `.offset` 视觉位移、
    /// 不参与布局测量，页面底边实际落在 mini 卡片上边界，不补偿就会与突出的封面贴太紧）。
    /// 沉浸态下底部装饰已整体隐藏（仅剩 `RootView.phoneBottomChrome` 的 8pt 外边距），
    /// 此时沿用 12pt 会把操作栏推离屏底过远，故收窄为 4pt。
    private var bottomBarGap: CGFloat {
        if isImmersive { return 4 }
        return player.isMini ? tabBarGap + MiniPlayer.coverOverflow : tabBarGap
    }

    /// 左下角退出钮的垂直落点：底部操作栏胶囊之上 10pt。
    /// 固定取展开态操作栏高度，使其在操作栏收为小胶囊时位置不跳动。
    private var exitHandleBottomInset: CGFloat {
        bottomBarGap + BrowserToolbar.barHeight + 10
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                contentArea
                // 展开态：完整操作栏占位底部
                if !toolbarMini, let tab = session.activeTab {
                    BrowserToolbar(
                        tab: tab,
                        tabCount: session.visibleTabs.count,
                        menuItems: menuItems,
                        onTabs: { showingTabs = true },
                        onSubmitAddress: { url in session.open(url) }
                    )
                    // 与底部页签栏留出一段距离（有 mini 播放器时补偿封面向上溢出的 8pt）
                    .padding(.bottom, bottomBarGap)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // 收起态：底部中央小胶囊（Safari 风格），点击展开完整操作栏
            if toolbarMini, let tab = session.activeTab, !tab.isShowingStartPage {
                miniCapsule(tab)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    // 与展开态操作栏底部对齐：同样避开页签栏 / mini 播放器封面溢出部分
                    .padding(.bottom, bottomBarGap)
            }
        }
        .background(AppColors.pageBackground)
        // 沉浸态左下角退出钮（+ 有播放会话时的播放微件）：
        // 收缩态与操作栏的 `toolbarMini` 同源联动（T1），贴边半隐仅露 14pt
        .overlay(alignment: .bottomLeading) {
            if isImmersive {
                BrowserExitHandle(collapsed: toolbarMini, onExit: exitImmersive)
                    .padding(.bottom, exitHandleBottomInset)
                    .transition(.opacity)
            }
        }
        .animation(.appFast, value: toolbarMini)
        .onChange(of: session.activeTabID) { _ in
            // 打开/切换到网页标签 → 收为胶囊；起始页（需输入网址）→ 展开地址栏
            toolbarMini = !(session.activeTab?.isShowingStartPage ?? true)
        }
        // 沉浸态开关同步（S1）：`RootView` 以 ZStack 保活各页签（切页签不触发 onDisappear），
        // 故必须由 `router.selectedTab` 驱动，不能依赖本视图的进出场
        .onChange(of: router.selectedTab) { tab in
            bottomTabBarHidden.wrappedValue = (horizontalSizeClass == .compact && tab == .browser)
        }
        // iPad 分屏 / 多任务导致 sizeClass 变化时同步校正（regular 下不隐藏底部装饰）
        .onChange(of: horizontalSizeClass) { sizeClass in
            bottomTabBarHidden.wrappedValue = (sizeClass == .compact && router.selectedTab == .browser)
        }
        // 启动时各保活页签均会触发 onAppear，故按当前页签校正；退场兜底复位，避免底栏永久消失
        .onAppear { bottomTabBarHidden.wrappedValue = isImmersive }
        .onDisappear { bottomTabBarHidden.wrappedValue = false }
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
                // 标签状态变化（滚动 / 刷新 / 导航）必须由持有 `@ObservedObject` 的子视图接收，
                // 否则 onChange 不会被及时求值（见 `BrowserTabContent` 注释，TODO 399）
                BrowserTabContent(
                    tab: tab,
                    isActive: tab.id == session.activeTabID,
                    onCollapseToolbar: collapseToolbar,
                    onURLChange: { url in
                        // 打开新界面（导航到网页）→ 胶囊；回退到起始页 → 展开地址栏
                        toolbarMini = (url != nil)
                    }
                )
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
        toolbarMini = false
    }

    /// 收起为底部小胶囊（滑动页面 / 刷新页面触发）
    private func collapseToolbar() {
        guard !toolbarMini else { return }
        toolbarMini = true
    }

    // MARK: - 收起态小胶囊（Safari 风格）

    /// 操作栏收起后缩为底部中央的小胶囊：锁图标 + 域名，点击展开完整操作栏
    private func miniCapsule(_ tab: BrowserTab) -> some View {
        Button {
            expandToolbar()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.hasOnlySecureContent ? "lock.fill" : "lock.open")
                    .font(.caption2)
                    .foregroundStyle(AppColors.textSecondary)
                Text(tab.currentURL?.host ?? "网页")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(
                Capsule()
                    .fill(AppColors.cardBackground)
                    .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
            )
            // 描边与全局悬浮页签栏 / mini 播放器 / 操作栏胶囊统一为 cardBorder（TODO 377 方案 A）
            .overlay(Capsule().stroke(AppColors.cardBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("展开浏览器操作栏")
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

/// Safari 风格标签卡片网格（新建/关闭/切换 + 无痕开关，IOS-401）
private struct TabGridView: View {
    @EnvironmentObject private var session: BrowserSessionStore
    @Environment(\.dismiss) private var dismiss

    /// 当前被长按拖动的标签（用于实时重排 + 拖动态视觉反馈）
    @State private var draggingTab: BrowserTab?

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(session.visibleTabs) { tab in
                        tabCard(tab)
                    }
                }
                .padding(16)
            }
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
