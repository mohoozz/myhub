import SwiftUI

/// 内置浏览器主页（TODO §8.1/§8.2，IOS-401）：
/// 顶部地址栏 + 标签内容保活区 + 底部操作栏（滚动收起/点击展开）。
/// Safari 风格卡片网格标签管理（新建/关闭/切换 + 无痕开关）。
struct BrowserHomeView: View {
    @EnvironmentObject private var session: BrowserSessionStore
    @EnvironmentObject private var dataStore: BrowserDataStore

    @State private var showingTabs = false
    @State private var showingBookmarks = false
    @State private var showingHistory = false
    @State private var showingSettings = false
    @State private var toolbarCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            contentArea
            if !toolbarCollapsed, let tab = session.activeTab {
                BrowserToolbar(
                    tab: tab,
                    tabCount: session.visibleTabs.count,
                    menuItems: menuItems,
                    onTabs: { showingTabs = true }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(AppColors.pageBackground)
        .animation(.appFast, value: toolbarCollapsed)
        .onChange(of: session.activeTabID) { _ in
            toolbarCollapsed = false
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

    // MARK: - 顶部栏（仅地址栏）

    private var topBar: some View {
        HStack(spacing: 8) {
            if let tab = session.activeTab {
                AddressBar(tab: tab) { url in
                    session.open(url)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
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
                    toolbarCollapsed = scrollingUp
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
        guard toolbarCollapsed else { return }
        toolbarCollapsed = false
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
