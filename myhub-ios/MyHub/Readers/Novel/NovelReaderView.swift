import SwiftUI

/// 小说阅读器主界面（TODO §5）：
/// - 翻页模式（行边界分页，点击左右分区 / 滑动翻页）与滚动模式（连续滚动页块）；
/// - 点击中央呼出控制层：顶栏（关闭 / 书名）、底栏（进度 / 上下章 / 目录 / 设置）；
/// - 目录抽屉（当前章高亮跳转）+ 阅读设置面板（字号 / 行距 / 主题 / 翻页模式 / 亮度 / 字体）；
/// - epub 图集型提示转漫画阅读器；沉浸式背景随阅读主题（夜间纯黑）。
struct NovelReaderView: View {
    let context: NovelOpenContext

    @StateObject private var viewModel: NovelReaderViewModel
    @EnvironmentObject private var presenter: NovelReaderPresenter
    @State private var controlsVisible = true
    @State private var showCatalog = false
    @State private var showSettings = false

    init(context: NovelOpenContext) {
        self.context = context
        _viewModel = StateObject(
            wrappedValue: NovelReaderViewModel(connection: context.connection, entry: context.entry)
        )
    }

    var body: some View {
        ZStack {
            viewModel.themeSpec.background.ignoresSafeArea()
            content
            if viewModel.state == .ready {
                touchZones
            }
            if controlsVisible, viewModel.state == .ready {
                controls
                    .transition(.opacity)
            }
        }
        .statusBar(hidden: !controlsVisible)
        .animation(.appQuick, value: controlsVisible)
        .onAppear { viewModel.load() }
        .onDisappear { viewModel.teardown() }
        .sheet(isPresented: $showCatalog) {
            catalogDrawer
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsPanel(viewModel: viewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert("这是图集型 EPUB", isPresented: $viewModel.comicLikePrompt) {
            Button("以漫画阅读器打开") {
                if let handler = presenter.onOpenComic {
                    handler(context)
                    presenter.close()
                } else {
                    viewModel.toast = "漫画阅读器将在后续版本接入（TODO §6）"
                }
            }
            Button("继续以文本阅读", role: .cancel) {}
        } message: {
            Text("该 EPUB 以插图为主，建议使用漫画阅读器获得更佳体验。")
        }
        .overlay(alignment: .bottom) {
            if let toast = viewModel.toast {
                Text(toast)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.75))
                    .clipShape(Capsule())
                    .padding(.bottom, 120)
                    .transition(.opacity)
            }
        }
        .animation(.appQuick, value: viewModel.toast)
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .indexing(let fraction):
            VStack(spacing: 14) {
                ProgressView(value: fraction)
                    .tint(AppColors.primary)
                    .frame(width: 180)
                Text("正在建立章节索引 \(Int(fraction * 100))%")
                    .font(.subheadline)
                    .foregroundStyle(viewModel.themeSpec.secondaryText)
            }
        case .loading:
            VStack(spacing: 14) {
                ProgressView()
                Text("正在加载…")
                    .font(.subheadline)
                    .foregroundStyle(viewModel.themeSpec.secondaryText)
            }
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(viewModel.themeSpec.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("关闭") { presenter.close() }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.primary)
            }
        case .ready:
            GeometryReader { proxy in
                let size = CGSize(
                    width: proxy.size.width - 32,
                    height: proxy.size.height - 16
                )
                ZStack {
                    Color.clear
                        .onAppear { viewModel.paginateIfNeeded(size: size) }
                        .onChange(of: proxy.size) { _ in viewModel.paginateIfNeeded(size: size) }
                    readerContent
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var readerContent: some View {
        if viewModel.chapterLoading || viewModel.pagination == nil {
            VStack(spacing: 10) {
                ProgressView()
                Text("章节加载中…")
                    .font(.caption)
                    .foregroundStyle(viewModel.themeSpec.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.appearance.pageMode == .paging {
            pagingContent
        } else {
            scrollingContent
        }
    }

    /// 翻页模式：TabView 页块（系统滑动翻页），点击分区见 touchZones
    private var pagingContent: some View {
        TabView(selection: Binding(
            get: { viewModel.page },
            set: { viewModel.goToPage($0) }
        )) {
            ForEach(0..<max(viewModel.pageCount, 1), id: \.self) { index in
                Text(viewModel.pageAttributedContent(index))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    /// 滚动模式：连续滚动的页块（同一份分页结果，版式一致；程序滚动经 scrollIntent 联动）
    private var scrollingContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 28) {
                    ForEach(0..<max(viewModel.pageCount, 1), id: \.self) { index in
                        Text(viewModel.pageAttributedContent(index))
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .id(index)
                            .onAppear { viewModel.scrollVisiblePage(index) }
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.scrollIntent) { target in
                guard let target else { return }
                withAnimation(.appQuick) {
                    proxy.scrollTo(target, anchor: .top)
                }
            }
            .onAppear {
                // 首次构建 / 重排后恢复页码定位（scrollIntent 可能先于视图出现被赋值）
                if let target = viewModel.scrollIntent {
                    proxy.scrollTo(target, anchor: .top)
                }
            }
        }
    }

    // MARK: - 点击分区（左翻 / 菜单 / 右翻）

    private var touchZones: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { previousPage() }
                    .frame(width: proxy.size.width * 0.25)
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.appQuick) { controlsVisible.toggle() } }
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { nextPage() }
                    .frame(width: proxy.size.width * 0.25)
            }
        }
    }

    private func previousPage() {
        if viewModel.appearance.pageMode == .paging {
            viewModel.goToPage(viewModel.page - 1)
        } else {
            viewModel.requestScroll(to: viewModel.page - 1)
        }
    }

    private func nextPage() {
        if viewModel.appearance.pageMode == .paging {
            viewModel.goToPage(viewModel.page + 1)
        } else {
            viewModel.requestScroll(to: viewModel.page + 1)
        }
    }

    // MARK: - 控制层

    private var controls: some View {
        VStack {
            topBar
            Spacer()
            bottomBar
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { presenter.close() } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.bookTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(viewModel.currentChapterTitle)
                    .font(.caption)
                    .foregroundStyle(viewModel.themeSpec.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
        }
        .foregroundStyle(viewModel.themeSpec.text)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(viewModel.themeSpec.controlBackground.opacity(0.96))
        .overlay(alignment: .bottom) {
            Rectangle().fill(viewModel.themeSpec.secondaryText.opacity(0.2)).frame(height: 0.5)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            // 进度：章内页码 + 全书百分比
            HStack(spacing: 10) {
                Text("\(viewModel.page + 1)/\(max(viewModel.pageCount, 1))")
                    .font(.caption2)
                    .foregroundStyle(viewModel.themeSpec.secondaryText)
                    .frame(width: 52, alignment: .leading)
                ProgressView(value: chapterProgress)
                    .tint(AppColors.primary)
                Text(percentText)
                    .font(.caption2)
                    .foregroundStyle(viewModel.themeSpec.secondaryText)
                    .frame(width: 44, alignment: .trailing)
            }

            HStack(spacing: 0) {
                bottomButton("上一章", symbol: "chevron.left", enabled: viewModel.chapter > 0) {
                    viewModel.goToChapter(viewModel.chapter - 1)
                }
                bottomButton("目录", symbol: "list.bullet") {
                    showCatalog = true
                }
                bottomButton("设置", symbol: "textformat.size") {
                    showSettings = true
                }
                bottomButton("下一章", symbol: "chevron.right", enabled: viewModel.chapter + 1 < viewModel.toc.count) {
                    viewModel.goToChapter(viewModel.chapter + 1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(viewModel.themeSpec.controlBackground.opacity(0.96))
        .overlay(alignment: .top) {
            Rectangle().fill(viewModel.themeSpec.secondaryText.opacity(0.2)).frame(height: 0.5)
        }
    }

    private var chapterProgress: Double {
        guard viewModel.pageCount > 1 else { return 0 }
        return Double(viewModel.page) / Double(viewModel.pageCount - 1)
    }

    private var percentText: String {
        guard viewModel.pageCount > 0 else { return "0%" }
        let inChapter = Double(viewModel.page) / Double(viewModel.pageCount)
        let total = (Double(viewModel.chapter) + inChapter) / Double(max(viewModel.toc.count, 1))
        return "\(Int((total * 100).rounded()))%"
    }

    private func bottomButton(
        _ title: String, symbol: String, enabled: Bool = true, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.body)
                Text(title)
                    .font(.caption2)
            }
            .foregroundStyle(enabled ? viewModel.themeSpec.text : viewModel.themeSpec.secondaryText.opacity(0.4))
            .frame(maxWidth: .infinity)
        }
        .disabled(!enabled)
    }

    // MARK: - 目录抽屉（当前章高亮跳转）

    private var catalogDrawer: some View {
        NavigationStack {
            List(viewModel.toc) { item in
                Button {
                    showCatalog = false
                    viewModel.goToChapter(item.id)
                } label: {
                    HStack {
                        Text(item.title)
                            .font(.subheadline)
                            .foregroundStyle(item.id == viewModel.chapter
                                             ? AppColors.primary : AppColors.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        if item.id == viewModel.chapter {
                            Image(systemName: "checkmark")
                                .font(.caption)
                                .foregroundStyle(AppColors.primary)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { showCatalog = false }
                }
            }
        }
    }
}

// MARK: - 阅读设置面板（IOS-502）

struct ReaderSettingsPanel: View {
    @ObservedObject var viewModel: NovelReaderViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // 字号
                settingRow(title: "字号", value: "\(Int(viewModel.appearance.fontSize))") {
                    Slider(value: fontSizeBinding, in: 12...32, step: 1)
                }
                // 行距
                settingRow(title: "行距", value: String(format: "%.1f", viewModel.appearance.lineSpacing)) {
                    Slider(value: lineSpacingBinding, in: 1.2...2.4, step: 0.1)
                }
                // 主题
                settingRow(title: "主题") {
                    Picker("主题", selection: themeBinding) {
                        Text("日间").tag(ReaderTheme.day)
                        Text("护眼").tag(ReaderTheme.eyeCare)
                        Text("夜间").tag(ReaderTheme.night)
                    }
                    .pickerStyle(.segmented)
                }
                // 翻页模式
                settingRow(title: "翻页模式") {
                    Picker("翻页模式", selection: pageModeBinding) {
                        Text("翻页").tag(ReaderPageMode.paging)
                        Text("滚动").tag(ReaderPageMode.scrolling)
                    }
                    .pickerStyle(.segmented)
                }
                // 亮度
                settingRow(title: "亮度", value: brightnessText) {
                    Slider(value: brightnessBinding, in: 0...1)
                }
                // 思源宋体
                Toggle(isOn: serifBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("正文宋体（思源宋体）")
                            .font(.subheadline)
                        Text("未打包字体资源时回退系统宋体")
                            .font(.caption2)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
                .tint(AppColors.primary)

                Spacer()
            }
            .padding(20)
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func settingRow<Content: View>(
        title: String, value: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                if let value {
                    Text(value)
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
            content()
                .tint(AppColors.primary)
        }
    }

    // MARK: - Bindings

    private var fontSizeBinding: Binding<Double> {
        Binding(
            get: { viewModel.appearance.fontSize },
            set: { viewModel.appearance.fontSize = $0 }
        )
    }

    private var lineSpacingBinding: Binding<Double> {
        Binding(
            get: { viewModel.appearance.lineSpacing },
            set: { viewModel.appearance.lineSpacing = $0 }
        )
    }

    private var themeBinding: Binding<ReaderTheme> {
        Binding(
            get: { viewModel.appearance.theme },
            set: { viewModel.appearance.theme = $0 }
        )
    }

    private var pageModeBinding: Binding<ReaderPageMode> {
        Binding(
            get: { viewModel.appearance.pageMode },
            set: { viewModel.appearance.pageMode = $0 }
        )
    }

    private var serifBinding: Binding<Bool> {
        Binding(
            get: { viewModel.appearance.useSerifFont },
            set: { viewModel.appearance.useSerifFont = $0 }
        )
    }

    private var brightnessBinding: Binding<Double> {
        Binding(
            get: {
                let stored = AppSettings.Reader.brightness
                return stored >= 0 ? stored : Double(UIScreen.main.brightness)
            },
            set: { viewModel.setBrightness($0) }
        )
    }

    private var brightnessText: String {
        AppSettings.Reader.brightness >= 0
            ? "\(Int(AppSettings.Reader.brightness * 100))%"
            : "跟随系统"
    }
}
