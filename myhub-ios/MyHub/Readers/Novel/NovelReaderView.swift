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
                onEnded: { translation, velocity in
                    let screenWidth = UIScreen.main.bounds.width
                    // 灵敏判定：位移过 1/4 屏宽，或向右快速轻扫即退出
                    if translation > screenWidth * 0.25 || velocity > 600 {
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
                                            value: [page: geo.frame(in: .named("novelScroll"))]
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
                .onPreferenceChange(NovelVisibleKey.self) { frames in
                    // 最接近视口中点的页视为当前页（程序滚动期间由 scrollIntent 锁定忽略回写）
                    guard viewModel.scrollIntent == nil else {
                        AppLogger.shared.log("NovelVisible 忽略 scrollIntent=\(String(describing: viewModel.scrollIntent))", module: "novel-reader")
                        return
                    }
                    guard !frames.isEmpty else {
                        AppLogger.shared.log("NovelVisible values 为空", module: "novel-reader")
                        return
                    }
                    let mid = viewport.size.height / 2
                    if let best = frames.min(by: { abs($0.value.midY - mid) < abs($1.value.midY - mid) })?.key {
                        viewModel.scrollVisiblePage(best)
                    }
                    // 视口顶部所在页：页内纵向偏移 → 连续字符位置（行映射，行级精度上报）
                    if let top = frames
                        .filter({ $0.value.maxY > 0 })
                        .min(by: { $0.value.minY < $1.value.minY }) {
                        let rect = top.value
                        viewModel.scrollVisibleTop(
                            page: top.key,
                            offsetY: max(0, -rect.minY),
                            pageHeight: max(rect.height, 1)
                        )
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

    // MARK: - 底栏（方案 B+：单行胶囊 + 下沿可拖动进度轨）

    /// 拖动中的目标区间（0...1，nil = 未拖动）。拖动期间只改本地区间值，**松手才真正跳章**。
    @State private var dragRatio: Double?
    /// 拖动中吸附到的章号（0 基）
    @State private var dragChapterIndex = 0
    /// 胶囊宽度（气泡跟随手柄用，由几何读取写入）
    @State private var barWidth: CGFloat = 0

    /// 轨道左右内缩（对应原型 8pt，这里留 10pt 与胶囊圆角贴合）
    private let railInset: CGFloat = 10
    /// 胶囊高度：按钮带 48pt（含 12pt 下沿拖动带）+ 进度轨带 12pt
    private let capsuleHeight: CGFloat = 60
    /// 下沿拖动带高度：仅此条带响应拖动，正文 / 胶囊其余区域手势不受影响
    private let railStripHeight: CGFloat = 24
    /// 轨道线中心距胶囊底边的高度
    private let railLineInset: CGFloat = 7

    private var bottomBar: some View {
        VStack(spacing: 6) {
            progressLine
            capsuleBar
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(viewModel.themeSpec.controlBackground.opacity(0.96))
        .overlay(alignment: .top) {
            Rectangle().fill(viewModel.themeSpec.secondaryText.opacity(0.2)).frame(height: 0.5)
        }
    }

    /// 胶囊上方一行细字读数；拖动中变为深色气泡（随手柄横向移动，出界自动夹紧）
    private var progressLine: some View {
        ZStack {
            if let ratio = dragRatio {
                Text("松手跳到 第 \(dragChapterIndex + 1) 章 · 全书 \(percentString(ratio))%")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color(hex: 0x111827).opacity(0.92)))
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                    .fixedSize()
                    .offset(x: bubbleOffsetX)
                    .transition(.opacity)
            } else {
                Text(progressCaption)
                    .font(.system(size: 10))
                    .foregroundStyle(viewModel.themeSpec.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .animation(.appQuick, value: dragRatio == nil)
    }

    /// 单行胶囊：左起 目录 / 上一章 / 下一章 / 设置，下沿内嵌可拖动进度轨
    private var capsuleBar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let usable = max(width - railInset * 2, 1)
            ZStack(alignment: .top) {
                HStack(spacing: 0) {
                    bottomButton("目录", symbol: "list.bullet") { showCatalog = true }
                    bottomButton("上一章", symbol: "chevron.left", enabled: viewModel.chapter > 0) {
                        viewModel.goToChapter(viewModel.chapter - 1)
                    }
                    bottomButton("下一章", symbol: "chevron.right",
                                 enabled: viewModel.chapter + 1 < viewModel.toc.count) {
                        viewModel.goToChapter(viewModel.chapter + 1)
                    }
                    bottomButton("设置", symbol: "textformat.size") { showSettings = true }
                }
                .frame(height: capsuleHeight, alignment: .top)
                .background(Capsule().fill(capsuleFill))

                progressRail(usable: usable)
                    .frame(height: railStripHeight)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .onAppear { barWidth = width }
            .onChange(of: proxy.size.width) { barWidth = $0 }
        }
        .frame(height: capsuleHeight)
    }

    /// 可拖动进度轨：3pt 轨 + 16pt 手柄（拖动中放大到 22pt 并带光圈），命中区即整条下沿带
    private func progressRail(usable: CGFloat) -> some View {
        let ratio = min(max(dragRatio ?? totalProgress, 0), 1)
        let knobX = railInset + usable * ratio
        let fillWidth = max(knobX - railInset, 0)
        let dragging = dragRatio != nil
        let lineY = railStripHeight - railLineInset
        return ZStack {
            Capsule()
                .fill(viewModel.themeSpec.secondaryText.opacity(0.22))
                .frame(width: usable, height: 3)
                .position(x: railInset + usable / 2, y: lineY)
            Capsule()
                .fill(AppColors.primary)
                .frame(width: fillWidth, height: 3)
                .position(x: railInset + fillWidth / 2, y: lineY)
            Circle()
                .fill(knobFill)
                .frame(width: dragging ? 22 : 16, height: dragging ? 22 : 16)
                .overlay(Circle().stroke(AppColors.primary, lineWidth: 2))
                .background(
                    Circle()
                        .fill(AppColors.primary.opacity(0.16))
                        .frame(width: dragging ? 36 : 0, height: dragging ? 36 : 0)
                )
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                .position(x: knobX, y: lineY)
        }
        .frame(maxWidth: .infinity)
        .frame(height: railStripHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    updateDrag(x: value.location.x, width: usable + railInset * 2)
                }
                .onEnded { _ in commitDrag() }
        )
        .animation(.easeOut(duration: 0.12), value: dragging)
        .allowsHitTesting(viewModel.toc.count > 1)
    }

    /// 拖动 → 区间值：临近章边界（±1.2%，且不超过章宽 40%）自动吸附，避免停在章中间
    private func updateDrag(x: CGFloat, width: CGFloat) {
        let usable = max(width - railInset * 2, 1)
        var ratio = min(max((x - railInset) / usable, 0), 1)
        let count = max(viewModel.toc.count, 1)
        let step = 1 / Double(count)
        let boundary = (ratio / step).rounded() * step
        let snapWindow = min(0.012, step * 0.4)
        if abs(boundary - ratio) <= snapWindow {
            ratio = min(max(boundary, 0), 1)
        }
        dragChapterIndex = min(max(Int((ratio / step).rounded(.down)), 0), count - 1)
        dragRatio = ratio
    }

    /// 松手才跳章：命中缓存直接切章不闪加载，未命中走既有 goToChapter 加载路径
    private func commitDrag() {
        guard let ratio = dragRatio else { return }
        dragRatio = nil
        guard viewModel.toc.indices.contains(dragChapterIndex) else { return }
        guard dragChapterIndex != viewModel.chapter else {
            viewModel.flashToast("已在本章 · 第 \(dragChapterIndex + 1) 章")
            return
        }
        viewModel.goToChapter(dragChapterIndex)
        viewModel.flashToast("已跳转 → 第 \(dragChapterIndex + 1) 章 · 全书 \(percentString(ratio))%")
    }

    /// 气泡横向跟随手柄（预留气泡半宽，避免越出底栏）
    private var bubbleOffsetX: CGFloat {
        guard let ratio = dragRatio, barWidth > 0 else { return 0 }
        let usable = max(barWidth - railInset * 2, 1)
        let knobX = railInset + usable * min(max(ratio, 0), 1)
        let limit = max(barWidth / 2 - 112, 0)
        return min(max(knobX - barWidth / 2, -limit), limit)
    }

    /// 全书进度（口径与 ViewModel.currentPercent 一致：章号 + 章内页占比）
    private var totalProgress: Double {
        let total = Double(max(viewModel.toc.count, 1))
        let inChapter = viewModel.pageCount > 0 ? Double(viewModel.page) / Double(viewModel.pageCount) : 0
        return min(max((Double(viewModel.chapter) + inChapter) / total, 0), 1)
    }

    private var progressCaption: String {
        let chapter = viewModel.toc.isEmpty ? 0 : viewModel.chapter + 1
        let pages = max(viewModel.pageCount, 1)
        return "第 \(chapter) 章 · \(min(viewModel.page + 1, pages))/\(pages) 页 · \(percentString(totalProgress))%"
    }

    private func percentString(_ ratio: Double) -> String {
        "\(Int((min(max(ratio, 0), 1) * 100).rounded()))"
    }

    /// 胶囊底色：浅色主题下比底栏略深一档，夜间主题下略浅一档，保证胶囊边界可见
    private var capsuleFill: Color {
        viewModel.themeSpec.secondaryText.opacity(0.12)
    }

    /// 手柄底色：夜间用近黑（原型 #1C1C1E），其余用白
    private var knobFill: Color {
        viewModel.appearance.theme == .night ? Color(hex: 0x1C1C1E) : .white
    }

    private func bottomButton(
        _ title: String, symbol: String, enabled: Bool = true, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                Text(title)
                    .font(.system(size: 10))
            }
            .foregroundStyle(enabled ? viewModel.themeSpec.text : viewModel.themeSpec.secondaryText.opacity(0.4))
            .padding(.top, 7)
            .frame(maxWidth: .infinity)
            .frame(height: capsuleHeight, alignment: .top)
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
    /// 各可见页在 "novelScroll"（视口）坐标空间中的 frame
    static var defaultValue: [ScrollPage: CGRect] = [:]
    static func reduce(value: inout [ScrollPage: CGRect], nextValue: () -> [ScrollPage: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

