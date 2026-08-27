import SwiftUI

/// 内置浏览器主页（TODO §8.1/§8.2，IOS-401）：
/// 标签内容保活区 + 底部操作栏（含居中地址栏，滚动收起为小胶囊/下滑或点击展开，Safari 风格）。
/// Safari 风格卡片网格标签管理（新建/关闭/切换 + 无痕开关）。
struct BrowserHomeView: View {
    @EnvironmentObject private var session: BrowserSessionStore
    @EnvironmentObject private var dataStore: BrowserDataStore

    @State private var showingTabs = false
    @State private var showingBookmarks = false
    @State private var showingHistory = false
    @State private var showingSettings = false
    /// 操作栏是否收起为底部小胶囊（而非完全隐藏，始终可见可点击）
    @State private var toolbarMini = false

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
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // 收起态：底部中央小胶囊（Safari 风格），点击展开完整操作栏
            if toolbarMini, let tab = session.activeTab, !tab.isShowingStartPage {
                miniCapsule(tab)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .padding(.bottom, 10)
            }
        }
        .background(AppColors.pageBackground)
        .animation(.appFast, value: toolbarMini)
        .onChange(of: session.activeTabID) { _ in
            toolbarMini = false
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
                BrowserView(
                    tab: tab,
                    onEdgeSwipeBack: { closeTab(tab) },
                    onTap: { expandToolbar() }
                )
                .opacity(tab.id == session.activeTabID ? 1 : 0)
                .allowsHitTesting(tab.id == session.activeTabID)
                .accessibilityHidden(tab.id != session.activeTabID)
                .onChange(of: tab.isScrollingUp) { scrollingUp in
                    guard tab.id == session.activeTabID else { return }
                    // 起始页（新标签页）不收起；其余上滑收起、下滑展开
                    toolbarMini = scrollingUp && !tab.isShowingStartPage
                }
            }
        }
    }

    // MARK: - 行为

    /// 历史栈空时侧滑返回 → 退出页签
    private func closeTab(_ tab: BrowserTab) {
        session.closeTab(tab.id)
    }

    private func expandToolbar() {
        guard toolbarMini else { return }
        toolbarMini = false
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
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
            )
            .overlay(Capsule().stroke(AppColors.separator, lineWidth: 0.5))
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

/// Safari 风格标签卡片网格（新建/关闭/切换 + 无痕开关，IOS-401）
private struct TabGridView: View {
    @EnvironmentObject private var session: BrowserSessionStore
    @Environment(\.dismiss) private var dismiss

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
