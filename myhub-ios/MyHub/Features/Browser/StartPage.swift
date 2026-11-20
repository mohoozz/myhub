import SwiftUI

/// 起始页（TODO §8.3，IOS-402）：搜索框 + 快捷入口网格。
/// 快捷入口支持增删改 + 拖拽排序（编辑模式切换为 List），首启预置在 `BrowserDataStore` 完成。
struct StartPage: View {
    @EnvironmentObject private var dataStore: BrowserDataStore
    var onNavigate: (URL) -> Void

    @State private var query = ""
    @State private var editing = false
    @State private var showingAdd = false
    @State private var editingShortcut: BrowserShortcut?
    @FocusState private var searchFocused: Bool
    /// 基准可视高度：用来算顶部留白。键盘弹起会把可视高度临时压小，
    /// 跟着它算会让搜索框在输入时往上跳，所以只记住「变大」的那次
    @State private var layoutHeight: CGFloat = 0

    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 16)]

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                ZStack(alignment: .top) {
                    // 点击空白处收键盘。这层**垫在内容之下**：输入框、快捷入口的点击仍然先命中它们自己。
                    // 旧实现是把 `contentShape(Rectangle()) + onTapGesture` 挂在内容 VStack 上，
                    // 那层手势与 `TextField` 在同一命中链上抢第一下点击，表现为「点一下只收了键盘、没进输入态」。
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { Keyboard.dismiss() }

                    VStack(spacing: 0) {
                        header
                            .frame(height: headerHeight(for: layoutHeight > 1 ? layoutHeight : proxy.size.height))
                        searchBar
                        shortcutSection
                            .padding(.top, 28)
                    }
                    .padding(.horizontal, 16)
                    // 底部让出操作栏高度：操作栏已改为浮在网页之上的浮层（F1），
                    // 起始页滑到底时最后一行快捷入口不该被它盖住
                    .padding(.bottom, BrowserToolbar.barHeight)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.immediately)
            .onAppear { layoutHeight = proxy.size.height }
            .onChange(of: proxy.size.height) { newValue in
                // 只在变大时更新：键盘弹起会让高度临时变小，跟随它算会让搜索框在输入时上下跳
                if newValue > layoutHeight { layoutHeight = newValue }
            }
        }
        .background(AppColors.pageBackground)
        .sheet(isPresented: $showingAdd) {
            ShortcutEditorView(title: "", url: "") { title, url in
                dataStore.addShortcut(title: title, url: url)
            }
        }
        .sheet(item: $editingShortcut) { shortcut in
            ShortcutEditorView(title: shortcut.title, url: shortcut.url) { title, url in
                var updated = shortcut
                updated.title = title
                updated.url = url
                dataStore.updateShortcut(updated)
            }
        }
    }

    // MARK: - 顶部留白 + 搜索框（方案 C：输入框居中偏上）

    /// 顶部留白高度：把输入框压到屏幕约 30% 处（拇指自然抬起就能碰到），
    /// 上方空出来的区域承载站点标识，避免整块空白。
    private func headerHeight(for available: CGFloat) -> CGFloat {
        guard available > 1 else { return 56 }
        return min(max(available * 0.26, 56), 220)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(AppColors.separator)
            Text("新标签页")
                .font(.footnote)
                .foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(AppColors.textSecondary)
                // 点图标也能进输入态（图标不参与 TextField 的命中区域）；
                // 不在整个 HStack 上挂 tap —— 那层手势会把 TextField 的第一下点击抢走，键盘反而不弹
                .onTapGesture { searchFocused = true }
            TextField("搜索或输入网址", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .keyboardType(.webSearch)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($searchFocused)
                .onSubmit(submit)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppColors.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        // 高度约 52pt（17pt 正文 + 上下 16pt）：比旧版 46pt 更好按，
        // 圆角同步放大到 16，与「大搜索框」的视觉一致
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppColors.separator, lineWidth: 0.5)
        )
    }

    private func submit() {
        guard let url = BrowserAddress.resolve(query) else { return }
        query = ""
        Keyboard.dismiss()
        onNavigate(url)
    }

    // MARK: - 快捷入口

    private var shortcutSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("快捷入口")
                    .font(.headline)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
                if !dataStore.shortcuts.isEmpty {
                    Button(editing ? "完成" : "编辑") {
                        withAnimation(.appFast) { editing.toggle() }
                    }
                    .font(.subheadline)
                    .foregroundStyle(AppColors.primary)
                }
            }

            if editing {
                shortcutList
            } else {
                shortcutGrid
            }
        }
    }

    private var shortcutGrid: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(dataStore.shortcuts) { shortcut in
                shortcutCell(shortcut)
            }
            addCell
        }
    }

    private func shortcutCell(_ shortcut: BrowserShortcut) -> some View {
        VStack(spacing: 6) {
            shortcutIcon(shortcut)
                .frame(width: 44, height: 44)
            Text(shortcut.title)
                .font(.caption)
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            Keyboard.dismiss()
            if let url = URL(string: shortcut.url) { onNavigate(url) }
        }
    }

    private var addCell: some View {
        VStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.body.weight(.medium))
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(AppColors.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(AppColors.separator, style: StrokeStyle(lineWidth: 0.5, dash: [4]))
                        )
                )
            Text("添加")
                .font(.caption)
                .foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            Keyboard.dismiss()
            showingAdd = true
        }
    }

    private var shortcutList: some View {
        VStack(spacing: 0) {
            ForEach(dataStore.shortcuts) { shortcut in
                HStack(spacing: 12) {
                    shortcutIcon(shortcut).frame(width: 28, height: 28)
                    Text(shortcut.title)
                        .foregroundStyle(AppColors.textPrimary)
                    Spacer()
                    Button {
                        editingShortcut = shortcut
                    } label: {
                        Image(systemName: "pencil")
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .onTapGesture {
                    Keyboard.dismiss()
                    if let url = URL(string: shortcut.url) { onNavigate(url) }
                }
                Divider().overlay(AppColors.separator)
            }
            .onMove { source, destination in
                dataStore.moveShortcuts(from: source, to: destination)
            }
            .onDelete { offsets in
                for index in offsets { dataStore.removeShortcut(dataStore.shortcuts[index]) }
            }
        }
        .padding(.horizontal, 12)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppColors.cardBorder, lineWidth: 1)   // 白底主界面下卡片描边界定（TODO 376）
        )
    }

    // MARK: - 图标

    @ViewBuilder
    private func shortcutIcon(_ shortcut: BrowserShortcut) -> some View {
        if let host = URL(string: shortcut.url)?.host,
           let favicon = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64") {
            AsyncImage(url: favicon) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFit()
                } else {
                    letterIcon(shortcut.title)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            letterIcon(shortcut.title)
        }
    }

    private func letterIcon(_ title: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppColors.highlightBackground)
            Text(String(title.prefix(1)))
                .font(.headline)
                .foregroundStyle(AppColors.primary)
        }
    }
}

/// 快捷入口添加 / 编辑表单（TODO §8.3）
private struct ShortcutEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let url: String
    let onSave: (String, String) -> Void

    @State private var titleText: String
    @State private var urlText: String

    init(title: String, url: String, onSave: @escaping (String, String) -> Void) {
        self.title = title
        self.url = url
        self.onSave = onSave
        _titleText = State(initialValue: title)
        _urlText = State(initialValue: url)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("标题") {
                    TextField("例如：GitHub", text: $titleText)
                }
                Section("网址") {
                    TextField("https://…", text: $urlText)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle(title.isEmpty ? "添加快捷入口" : "编辑快捷入口")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let trimmedTitle = titleText.trimmingCharacters(in: .whitespaces)
                        let trimmedURL = urlText.trimmingCharacters(in: .whitespaces)
                        guard !trimmedTitle.isEmpty, !trimmedURL.isEmpty else { return }
                        onSave(trimmedTitle, trimmedURL)
                        dismiss()
                    }
                    .disabled(titleText.trimmingCharacters(in: .whitespaces).isEmpty
                              || urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
