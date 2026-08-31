import SwiftUI
import UIKit

/// 小说阅读器主界面（TODO §5）：
/// - 翻页模式（行边界分页，点击左右分区 / 滑动翻页）与滚动模式（连续滚动页块）；
/// - 点击中央呼出控制层：顶栏（关闭 / 书名）、底栏（进度 / 上下章 / 目录 / 设置）；
/// - 目录抽屉（当前章高亮跳转）+ 阅读设置面板（字号 / 行距 / 主题 / 翻页模式 / 亮度 / 字体）；
/// - epub 图集型自动转漫画阅读器；沉浸式背景随阅读主题（夜间纯黑）。
struct NovelReaderView: View {
    let context: NovelOpenContext

    @StateObject private var viewModel: NovelReaderViewModel
    @EnvironmentObject private var presenter: NovelReaderPresenter
    @State private var controlsVisible = true
    @State private var showCatalog = false
    @State private var showSettings = false
    /// 左滑退出的跟手位移（屏幕左边缘右滑时内容整体右移，松手超过阈值关闭阅读器）
    @State private var edgeDragOffset: CGFloat = 0

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
                .offset(x: edgeDragOffset)
            // 点击分区仅在翻页模式显示：滚动模式下全屏透明点击层会拦截 ScrollView 的滚动手势
            if viewModel.state == .ready, viewModel.appearance.pageMode == .paging {
                touchZones
            }
            if controlsVisible, viewModel.state == .ready {
                controls
                    .transition(.opacity)
            }
        }
        .background(
            // 左滑退出：从屏幕左边缘右滑关闭阅读器。手势实际挂在 window 上（见 EdgeSwipeBack），
            // 此处仅作为生命周期锚点，不占布局、不拦截 ScrollView 滚动 / TabView 翻页 / 按钮点击。
            EdgeSwipeBack(
                onChanged: { translation in
                    guard viewModel.state == .ready else { return }
                    edgeDragOffset = translation
                },
                onEnded: { translation in
                    let screenWidth = UIScreen.main.bounds.width
                    if translation > screenWidth * 0.32 {
                        // 超过阈值：内容滑出屏幕后关闭
                        withAnimation(.appQuick) { edgeDragOffset = screenWidth }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            presenter.close()
                        }
                    } else {
                        withAnimation(.appQuick) { edgeDragOffset = 0 }
                    }
                }
            )
        )
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
        .onChange(of: viewModel.comicLikePrompt) { isComic in
            // 图集型 epub：默认直接以漫画阅读器打开（不再弹选择框）
            guard isComic else { return }
            if let handler = presenter.onOpenComic {
                // 先关闭小说阅读器，再于下一 runloop 打开漫画阅读器：
                // 两个全屏路由若在同一更新周期内同时 present/dismiss 会触发 SwiftUI 崩溃。
                presenter.close()
                DispatchQueue.main.async { handler(context) }
            } else {
                viewModel.comicLikePrompt = false
                viewModel.toast = "漫画阅读器将在后续版本接入"
            }
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
                PagedTextLabel(attributedString: viewModel.pageContent(index))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    /// 滚动模式：连续滚动的页块（同一份分页结果，版式一致；程序滚动经 scrollIntent 联动）
    private var scrollingContent: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 28) {
                        // 顶部哨兵：检测滚动到顶，用于跨章自动续读上一章
                        Color.clear
                            .frame(height: 1)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: ScrollTopKey.self,
                                        value: geo.frame(in: .named("novelScroll")).minY
                                    )
                                }
                            )
                        ForEach(viewModel.scrollStream) { page in
                            PagedTextLabel(attributedString: viewModel.scrollPageContent(page))
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .id(page.id)
                                .background(
                                    // 可见页回写：GeometryReader 精确上报页块位置（onAppear 对 UIViewRepresentable 不可靠）
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: NovelVisibleKey.self,
                                            value: [page: geo.frame(in: .named("novelScroll")).midY]
                                        )
                                    }
                                )
                        }
                        // 底部哨兵：检测滚动到底，用于跨章自动续读下一章
                        Color.clear
                            .frame(height: 1)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: ScrollEndKey.self,
                                        value: geo.frame(in: .named("novelScroll")).maxY
                                    )
                                }
                            )
                    }
                    .padding(.vertical, 8)
                }
                .coordinateSpace(name: "novelScroll")
                .onTapGesture { withAnimation(.appQuick) { controlsVisible.toggle() } }
                .onPreferenceChange(ScrollEndKey.self) { maxY in
                    viewModel.scrollReachEnd(maxY <= viewport.size.height)
                }
                .onPreferenceChange(ScrollTopKey.self) { minY in
                    viewModel.scrollReachTop(minY >= 0)
                }
                .onPreferenceChange(NovelVisibleKey.self) { values in
                    // 最接近视口中点的页视为当前页（程序滚动期间由 scrollIntent 锁定忽略回写）
                    guard viewModel.scrollIntent == nil else {
                        AppLogger.shared.log("NovelVisible 忽略 scrollIntent=\(String(describing: viewModel.scrollIntent))", module: "novel-reader")
                        return
                    }
                    guard !values.isEmpty else {
                        AppLogger.shared.log("NovelVisible values 为空", module: "novel-reader")
                        return
                    }
                    let mid = viewport.size.height / 2
                    if let best = values.min(by: { abs($0.value - mid) < abs($1.value - mid) })?.key {
                        viewModel.scrollVisiblePage(best)
                    }
                }
                .onChange(of: viewModel.scrollIntentRevision) { _ in
                    guard viewModel.scrollIntent != nil else { return }
                    // 延迟一帧再滚动，确保 scrollStream 变更后的 LazyVStack 布局已完成，
                    // 避免向上插入章节时 scrollTo 与布局竞争造成跳动。
                    DispatchQueue.main.async {
                        guard let current = viewModel.scrollIntent else { return }
                        withAnimation(.appQuick) {
                            proxy.scrollTo(current, anchor: .top)
                        }
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

// MARK: - 分页富文本渲染（遵循 NSParagraphStyle 行距/段距）

/// SwiftUI `Text` 会忽略 `NSAttributedString` 中的 `NSParagraphStyle`
/// （`minimumLineHeight` / `maximumLineHeight` / `paragraphSpacing`），导致“行距”设置不生效。
/// 改用 `UILabel` 渲染分页文本，与 CoreText 分页使用同一套段落样式，保证视觉与分页一致。
private struct PagedTextLabel: UIViewRepresentable {
    let attributedString: NSAttributedString

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.backgroundColor = .clear
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.attributedText = attributedString
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView label: UILabel, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        label.preferredMaxLayoutWidth = width
        let size = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
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
                        Text("自动").tag(ReaderTheme.auto)
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

// MARK: - 滚动模式偏好键（可见页回写 + 滚动到底跨章）

private struct ScrollEndKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScrollTopKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct NovelVisibleKey: PreferenceKey {
    static var defaultValue: [ScrollPage: CGFloat] = [:]
    static func reduce(value: inout [ScrollPage: CGFloat], nextValue: () -> [ScrollPage: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - 左滑退出（fullScreenCover 无系统侧滑返回，补一个屏幕左边缘右滑手势）

/// 阅读器左边缘右滑退出手势桥接。
/// 阅读器经 `.fullScreenCover` 呈现（模态，非 NavigationStack push），没有系统侧滑返回手势。
/// 这里把 `UIScreenEdgePanGestureRecognizer` 挂到承载视图所在的 **window** 上：
/// - window 位于整个视图层级最外层，SwiftUI 内部（TabView 翻页 / ScrollView 滚动）的手势
///   无法将其吞掉，从根本上解决「窄条 overlay 上的边缘手势被内层滚动手势抢占而无法触发」的问题；
/// - `edges = .left` 由系统保证仅屏幕左边缘起手才识别，不影响正文任意区域的翻页/滚动/点击；
/// - 允许与其它手势同时识别（simultaneous），确保边缘右滑一定能被捕获。
private struct EdgeSwipeBack: UIViewRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void

    func makeUIView(context: Context) -> EdgeSwipeBackView {
        let view = EdgeSwipeBackView()
        view.onChanged = onChanged
        view.onEnded = onEnded
        return view
    }

    func updateUIView(_ view: EdgeSwipeBackView, context: Context) {
        view.onChanged = onChanged
        view.onEnded = onEnded
    }
}

/// 左滑退出手势宿主。自身不参与布局与命中测试（交互全部穿透），
/// 仅负责在挂载到 window 时把屏幕左边缘手势注册到 window、在移除时清理，避免泄漏到其它界面。
private final class EdgeSwipeBackView: UIView, UIGestureRecognizerDelegate {
    var onChanged: ((CGFloat) -> Void)?
    var onEnded: ((CGFloat) -> Void)?

    private weak var edgeGesture: UIScreenEdgePanGestureRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false // 自身不拦截任何触摸，交互全部穿透给正文
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window {
            guard edgeGesture == nil else { return }
            let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handle(_:)))
            edge.edges = .left
            edge.delegate = self
            window.addGestureRecognizer(edge)
            edgeGesture = edge
        } else if let edge = edgeGesture {
            // 阅读器 dismiss：从旧 window 移除手势，避免残留影响其它界面
            edge.view?.removeGestureRecognizer(edge)
            edgeGesture = nil
        }
    }

    @objc private func handle(_ g: UIScreenEdgePanGestureRecognizer) {
        let translation = g.translation(in: g.view).x
        switch g.state {
        case .began, .changed:
            onChanged?(max(0, translation))
        case .ended, .cancelled, .failed:
            onEnded?(max(0, translation))
        default:
            break
        }
    }

    // 允许与 TabView 翻页 / ScrollView 滚动等手势并存，保证边缘右滑一定能被识别
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
