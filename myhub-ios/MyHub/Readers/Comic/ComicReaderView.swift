import SwiftUI
import UIKit

/// 漫画阅读器（TODO §6 / IOS-207）：
/// - 单页 / 双页（横屏·平板自动启用，从右向左 / 从左向右可切换并持久化）/ 条漫（纵向连续滚动）；
/// - 双指缩放（UIScrollView 桥接）；点击中央呼出控制层；
/// - 页码进度直接恢复（条漫模式经 ScrollViewReader 程序滚动定位）；
/// - 翻完最后一页弹出「下一本」提示，点击提示条才打开（不自动打开）。
struct ComicReaderView: View {
    let context: NovelOpenContext
    var onClose: () -> Void = {}
    var onOpenNext: (FileEntry) -> Void = { _ in }

    @StateObject private var viewModel: ComicReaderViewModel
    @State private var controlsVisible = false
    /// 条漫模式程序滚动目标（ScrollViewReader 消费）
    @State private var scrollIntent: Int?
    /// 左滑退出的跟手位移（屏幕左边缘右滑时内容整体右移，松手超过阈值关闭阅读器）
    @State private var edgeDragOffset: CGFloat = 0

    // MARK: 方案 A 控制层（IOS-210）
    /// 拖动中的进度区间（0...1，nil = 未拖动）；拖动期间只改本地值，**松手才跳页**
    @State private var dragRatio: Double?
    /// 拖动中吸附到的目标页（0 基）
    @State private var dragPage = 0
    /// 毛玻璃胶囊宽度 / 进度轨在胶囊内的位置（气泡跟随手柄用）
    @State private var capsuleWidth: CGFloat = 0
    @State private var railFrame: CGRect = .zero
    @State private var showThumbnails = false
    @State private var showBrightness = false

    init(
        context: NovelOpenContext,
        onClose: @escaping () -> Void = {},
        onOpenNext: @escaping (FileEntry) -> Void = { _ in }
    ) {
        self.context = context
        self.onClose = onClose
        self.onOpenNext = onOpenNext
        _viewModel = StateObject(
            wrappedValue: ComicReaderViewModel(connection: context.connection, entry: context.entry)
        )
    }

    var body: some View {
        ZStack {
            AppColors.immersiveBackground.ignoresSafeArea()

            switch viewModel.state {
            case .opening(let progress):
                loadingState(progress)
            case .failed(let message):
                failedState(message)
            case .ready:
                readerContent
            }

            if viewModel.state == .ready {
                controlsOverlay
            }

            // 轻提示
            if let toast = viewModel.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.75))
                        .clipShape(Capsule())
                        .padding(.bottom, 90)
                }
                .transition(.opacity)
            }

            // 翻完推荐下一本（底部提示，点击才打开）
            if let candidate = viewModel.nextCandidate {
                VStack {
                    Spacer()
                    NextMediaTip(
                        entry: candidate,
                        onPlay: {
                            viewModel.cancelNext()
                            onOpenNext(candidate)
                        },
                        onCancel: { viewModel.cancelNext() }
                    )
                    .padding(.bottom, 60)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .offset(x: edgeDragOffset)
        .background(
            // 左滑退出：从屏幕左边缘右滑关闭阅读器。手势实际挂在 window 上（见 EdgeSwipeBack），
            // 此处仅作为生命周期锚点，不占布局、不拦截滚动 / 翻页 / 缩放 / 按钮点击。
            EdgeSwipeBack(
                onChanged: { translation in
                    edgeDragOffset = translation
                },
                onEnded: { translation, velocity in
                    let screenWidth = UIScreen.main.bounds.width
                    // 灵敏判定：位移过 1/4 屏宽，或向右快速轻扫即退出
                    if translation > screenWidth * 0.25 || velocity > 600 {
                        // 超过阈值：内容滑出屏幕后关闭
                        withAnimation(.appQuick) { edgeDragOffset = screenWidth }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            onClose()
                        }
                    } else {
                        withAnimation(.appQuick) { edgeDragOffset = 0 }
                    }
                }
            )
        )
        .animation(.appQuick, value: viewModel.nextCandidate != nil)
        .animation(.appQuick, value: viewModel.toast)
        .statusBarHidden(!controlsVisible)
        .sheet(isPresented: $showThumbnails) {
            ComicThumbnailSheet(viewModel: viewModel) { index in
                jumpToPage(index)
            }
        }
        .sheet(isPresented: $showBrightness) {
            ComicBrightnessSheet(viewModel: viewModel)
        }
        .onAppear {
            viewModel.applyReaderBrightness()
            viewModel.load()
        }
        .onDisappear { viewModel.teardown() }
    }

    // MARK: - 加载 / 失败（弱网先展示 UI，不阻塞）

    private func loadingState(_ progress: Double?) -> some View {
        VStack(spacing: 14) {
            if let progress {
                ProgressView(value: progress)
                    .tint(.white)
                    .frame(width: 180)
                Text("正在下载归档 \(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                ProgressView()
                    .tint(.white)
                Text("正在打开漫画…")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Text(context.entry.name)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.6))
            Text("无法打开漫画")
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("关闭") { onClose() }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.primary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 阅读区

    @ViewBuilder
    private var readerContent: some View {
        switch viewModel.mode {
        case .single:
            pagedContent(pairs: false)
        case .double:
            pagedContent(pairs: true)
        case .webtoon:
            webtoonContent
        }
    }

    /// 单页 / 双页：横向翻页（双指缩放；RTL 时反转滑动方向）
    private func pagedContent(pairs: Bool) -> some View {
        let groups = pageGroups(pairs: pairs)
        let selection = Binding<Int>(
            get: { groupIndex(for: viewModel.page, in: groups) },
            set: { index in
                guard groups.indices.contains(index) else { return }
                viewModel.goToPage(groups[index].first ?? 0)
            }
        )
        let rtl = isRightToLeft
        return GeometryReader { proxy in
            TabView(selection: selection) {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    ComicPageGroup(
                        group: group, images: viewModel.images,
                        containerSize: proxy.size, rtl: rtl
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // RTL：整体水平翻转实现「向左滑翻下一页 → 向右滑」，内部再翻正内容
            .scaleEffect(x: rtl ? -1 : 1)
            .onTapGesture { toggleControls() }
        }
    }

    /// 条漫：纵向连续滚动；恢复页码 / 模式切换经 ScrollViewReader 程序滚动定位；
    /// 可见页经 PreferenceKey 回写页码（条漫模式恢复页码显示）
    private var webtoonContent: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(0..<viewModel.pageCount, id: \.self) { index in
                        webtoonPage(index)
                    }
                }
            }
            .coordinateSpace(name: "webtoon")
            .onPreferenceChange(WebtoonVisibleKey.self) { values in
                // 最接近屏幕中点的页视为当前页；恢复定位中 / 程序滚动期间不回写（防止覆盖恢复页）
                guard !viewModel.isRestoring, scrollIntent == nil, !values.isEmpty else { return }
                let mid = UIScreen.main.bounds.height / 2
                if let best = values.min(by: { abs($0.value.midY - mid) < abs($1.value.midY - mid) }) {
                    // 页内偏移：页面被屏顶切割的分数位置（恢复定位精确到页内，而非只到页顶）
                    let frame = best.value
                    let offset = frame.height > 0
                        ? Float(min(max(-frame.minY / frame.height, 0), 1)) : 0
                    viewModel.updateWebtoonVisible(page: best.key, offset: offset)
                }
            }
            .onTapGesture { toggleControls() }
            .onAppear { scrollToCurrent(reader, animated: false) }
            .onChange(of: viewModel.page) { target in
                // 底栏跳转（slider）等程序滚动：仅响应显式 intent
                guard scrollIntent == target else { return }
                withAnimation(.appQuick) { reader.scrollTo(target, anchor: .top) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { scrollIntent = nil }
            }
        }
    }

    /// 程序滚动到当前页（首次进入恢复 / 切入条漫）
    private func scrollToCurrent(_ reader: ScrollViewProxy, animated: Bool) {
        let target = viewModel.page
        let anchor = webtoonRestoreAnchor(for: target)
        scrollIntent = target
        AppLogger.shared.log(
            "条漫恢复定位: 目标第\(target + 1)页 页内偏移=\(String(format: "%.2f", viewModel.pageOffset))",
            module: "comic-reader"
        )
        // LazyVStack 懒加载、图片解码前页高未知，初始 contentSize 不足时单次 scrollTo 会失效停在顶部。
        // 随布局/解码推进分阶段重试，直至目标页进入实例化范围定位到位（恢复为无动画瞬时重试，不跳动）。
        let delays: [TimeInterval] = [0, 0.1, 0.3, 0.6, 1.0]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard scrollIntent == target else { return }
                if animated {
                    withAnimation(.appQuick) { reader.scrollTo(target, anchor: anchor) }
                } else {
                    reader.scrollTo(target, anchor: anchor)
                }
            }
        }
        // 覆盖最后一次重试后：结束程序滚动 + 结束恢复期（交还可见页回写）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if scrollIntent == target { scrollIntent = nil }
            viewModel.endWebtoonRestore()
            // 恢复结束后再确认最终停留页（验证 scrollTo 是否生效）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                AppLogger.shared.log("条漫恢复定位完成: 停留第\(viewModel.page + 1)页", module: "comic-reader")
            }
        }
    }

    /// 恢复定位 anchor：把页内偏移 f（页面被屏顶切割的分数位置）还原到屏顶。
    /// scrollTo anchor 语义：页分数位置 a 与滚动区分数位置 a 对齐，页高 h、屏高 H 时
    /// 屏顶落在页分数 f 处需 a = f·h/(h−H)（h≤H 时页可整屏显示，直接页顶）。
    private func webtoonRestoreAnchor(for target: Int) -> UnitPoint {
        let f = CGFloat(viewModel.pageOffset)
        guard f > 0.001,
              let ratio = viewModel.pageRatios[target] ?? viewModel.fallbackRatio
        else { return .top }
        let H = UIScreen.main.bounds.height
        let h = UIScreen.main.bounds.width * ratio
        guard h > H else { return .top }
        let ay = f * h / (h - H)
        return UnitPoint(x: 0, y: min(max(ay, 0), 1))
    }

    private func webtoonPage(_ index: Int) -> some View {
        ComicImagePage(
            index: index, images: viewModel.images, fitWidth: true,
            aspectRatio: viewModel.pageRatios[index] ?? viewModel.fallbackRatio
        )
            .id(index)
            .onAppear { viewModel.ensureLoaded(index) }
            .background(
                // 可见页回写（条漫恢复页码显示）
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: WebtoonVisibleKey.self,
                        value: [index: proxy.frame(in: .named("webtoon"))]
                    )
                }
            )
    }

    // MARK: - 控制层（方案 A：现状式顶栏 + 底部毛玻璃胶囊）

    @ViewBuilder
    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            bottomControls
        }
        .opacity(controlsVisible ? 1 : 0)
        .allowsHitTesting(controlsVisible)
        .animation(.appQuick, value: controlsVisible)
    }

    /// 顶栏（现状式裸显示）：✕ + 书名 + ⋯ 菜单（模式 / 双页方向 / 亮度）
    private var topBar: some View {
        HStack(spacing: 2) {
            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            Text((context.entry.name as NSString).deletingPathExtension)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Menu { topMenuItems } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.78), .clear],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    /// ⋯ 菜单：低频设置入口（模式切换 / 双页方向 / 亮度），底栏不再放设置按钮
    @ViewBuilder
    private var topMenuItems: some View {
        Section("阅读模式") {
            ForEach(ComicReadMode.allCases, id: \.self) { mode in
                Button {
                    switchMode(mode)
                } label: {
                    Label(
                        mode.displayName,
                        systemImage: viewModel.mode == mode ? "checkmark" : mode.symbol
                    )
                }
            }
        }
        // 双页方向（含自动）；条漫模式隐藏（纵向滚动无方向）
        if viewModel.mode == .double {
            Section("双页方向") {
                Button {
                    viewModel.direction = isRightToLeft ? .leftToRight : .rightToLeft
                } label: {
                    Label(
                        "切换为\(isRightToLeft ? "从左向右" : "从右向左")",
                        systemImage: "arrow.left.arrow.right"
                    )
                }
            }
        }
        Section {
            Button {
                // 菜单关闭后再弹 sheet，避免转场被打断
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { showBrightness = true }
            } label: {
                Label("亮度", systemImage: "sun.max")
            }
        }
    }

    /// 底部控制区：细字读数 + 毛玻璃主胶囊 + 快捷 chip（内缩 12pt）
    private var bottomControls: some View {
        VStack(spacing: 8) {
            progressCaption
            glassCapsule
            quickChips
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    /// 胶囊上方一行细字读数；拖动中变为深色气泡并横向跟随手柄
    private var progressCaption: some View {
        ZStack {
            if let ratio = dragRatio {
                Text("松手跳到 第 \(dragPage + 1) 页 · \(Int((ratio * 100).rounded()))%")
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color(red: 0.09, green: 0.11, blue: 0.16)))
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                    .offset(x: bubbleOffsetX)
            } else {
                Text(captionText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
            }
        }
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .animation(.appQuick, value: dragRatio == nil)
    }

    /// 「第 12 / 186 页 · 6% · 单页」：进度三种表达合并成一行细字
    private var captionText: String {
        let percent = Int((viewModel.currentPercent * 100).rounded())
        return "第 \(displayPage) / \(viewModel.pageCount) 页 · \(percent)% · \(viewModel.mode.displayName)"
    }

    /// 主胶囊：‹ ｜可拖进度轨 + 手柄｜页码｜☰｜›（高 58、圆角 29、0.5pt 描边 + 阴影保证辨识）
    private var glassCapsule: some View {
        HStack(spacing: 2) {
            glassBarButton("chevron.left") { viewModel.previousPage() }
            progressRail
                .frame(height: railStripHeight)
            Text("\(displayPage)/\(viewModel.pageCount)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize()
                .padding(.horizontal, 4)
            glassBarButton("list.bullet") { showThumbnails = true }
            glassBarButton("chevron.right") { viewModel.nextPage() }
        }
        .padding(.horizontal, 6)
        .frame(height: capsuleHeight)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.4))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.38), radius: 10, y: 6)
        .coordinateSpace(name: "capsule")
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { capsuleWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { capsuleWidth = $0 }
            }
        )
    }

    /// 胶囊内圆形图标按钮（40pt 命中区）
    private func glassBarButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 可拖动进度轨：3pt 轨 + 14pt 手柄（拖动中放大到 20pt）；拖动只改本地值，松手才跳页
    private var progressRail: some View {
        GeometryReader { proxy in
            let usable = max(proxy.size.width - railInset * 2, 1)
            let ratio = min(max(dragRatio ?? viewModel.currentPercent, 0), 1)
            let knobX = railInset + usable * ratio
            let fillWidth = max(knobX - railInset, 0)
            let lineY = proxy.size.height / 2
            let dragging = dragRatio != nil
            ZStack {
                Capsule()
                    .fill(.white.opacity(0.24))
                    .frame(width: usable, height: 3)
                    .position(x: railInset + usable / 2, y: lineY)
                Capsule()
                    .fill(.white)
                    .frame(width: fillWidth, height: 3)
                    .position(x: railInset + fillWidth / 2, y: lineY)
                Circle()
                    .fill(.white)
                    .frame(width: dragging ? 20 : 14, height: dragging ? 20 : 14)
                    .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                    .position(x: knobX, y: lineY)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        updateDrag(x: value.location.x, usable: usable)
                    }
                    .onEnded { _ in commitDrag() }
            )
            .animation(.easeOut(duration: 0.12), value: dragging)
            .onAppear { railFrame = proxy.frame(in: .named("capsule")) }
            .onChange(of: proxy.frame(in: .named("capsule"))) { railFrame = $0 }
        }
    }

    /// 快捷 chip：缩略图 / 下一本 / 亮度（方案 A 相比现状的增量入口）
    private var quickChips: some View {
        HStack(spacing: 6) {
            quickChip("square.grid.2x2", "缩略图") { showThumbnails = true }
            quickChip("arrow.down.to.line", "下一本") { viewModel.requestNextComic() }
            quickChip("sun.max", "亮度") { showBrightness = true }
        }
    }

    private func quickChip(
        _ symbol: String, _ title: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(title).font(.system(size: 10.5))
            }
            .foregroundStyle(.white.opacity(0.72))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(0.1)))
            .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    /// 拖动中写入吸附页（本地状态，不发跳页指令）
    private func updateDrag(x: CGFloat, usable: CGFloat) {
        let ratio = min(max((x - railInset) / usable, 0), 1)
        dragRatio = ratio
        let maxIndex = max(viewModel.pageCount - 1, 0)
        dragPage = min(max(Int((ratio * Double(maxIndex)).rounded()), 0), maxIndex)
    }

    /// 松手才跳页（条漫模式由 jumpToPage 走程序滚动定位）
    private func commitDrag() {
        guard dragRatio != nil else { return }
        dragRatio = nil
        jumpToPage(dragPage)
    }

    /// 气泡横向跟随手柄（夹紧在胶囊内，避免越界）
    private var bubbleOffsetX: CGFloat {
        guard let ratio = dragRatio, capsuleWidth > 0, railFrame.width > 0 else { return 0 }
        let usable = max(railFrame.width - railInset * 2, 1)
        let knobX = railFrame.minX + railInset + usable * min(max(ratio, 0), 1)
        let limit = max(capsuleWidth / 2 - 112, 0)
        return min(max(knobX - capsuleWidth / 2, -limit), limit)
    }

    /// 胶囊 / 进度轨几何常量（对齐原型 A：胶囊高 58、轨带高 30、轨左右内缩 8）
    private var capsuleHeight: CGFloat { 58 }
    private var railStripHeight: CGFloat { 30 }
    private var railInset: CGFloat { 8 }

    // MARK: - 交互与布局

    private var isRightToLeft: Bool {
        switch viewModel.direction {
        case .rightToLeft: return true
        case .leftToRight: return false
        case .auto: return true   // 日漫习惯：自动默认 RTL
        }
    }

    /// 双页模式下显示的页码（组首 +1）
    private var displayPage: Int { viewModel.page + 1 }

    private func toggleControls() {
        withAnimation(.appQuick) { controlsVisible.toggle() }
    }

    private func switchMode(_ mode: ComicReadMode) {
        guard mode != viewModel.mode else { return }
        // 切回条漫前标记恢复定位中（防止 LazyVStack 顶部布局提前回写覆盖当前页）
        if mode == .webtoon { viewModel.beginWebtoonRestore() } else { viewModel.resetPageOffset() }
        viewModel.mode = mode
        // 条漫重建后由 onAppear 恢复到当前页（scrollToCurrent）
    }

    /// 底栏 slider 跳转：条漫模式走程序滚动，翻页模式直接定位
    private func jumpToPage(_ target: Int) {
        if viewModel.mode == .webtoon {
            scrollIntent = target
        }
        viewModel.goToPage(target)
    }

    /// 双页分组（RTL 时组内页序反转，由 ComicPageGroup 处理）
    private func pageGroups(pairs: Bool) -> [[Int]] {
        guard pairs else { return (0..<viewModel.pageCount).map { [$0] } }
        var groups: [[Int]] = []
        var index = 0
        while index < viewModel.pageCount {
            let end = min(index + 2, viewModel.pageCount)
            groups.append(Array(index..<end))
            index = end
        }
        return groups
    }

    private func groupIndex(for page: Int, in groups: [[Int]]) -> Int {
        groups.firstIndex(where: { $0.contains(page) }) ?? 0
    }
}

// MARK: - 页面组件

/// 单页 / 双页组（双指缩放）
private struct ComicPageGroup: View {
    let group: [Int]
    let images: [Int: UIImage]
    let containerSize: CGSize
    let rtl: Bool

    var body: some View {
        // RTL：右页在前（日漫从右往左），外层 TabView 已整体翻转，内容翻正
        let ordered = rtl ? Array(group.reversed()) : group
        ZoomableScrollView {
            HStack(spacing: 0) {
                ForEach(ordered, id: \.self) { index in
                    ComicImagePage(index: index, images: images, fitWidth: false)
                        .frame(
                            width: group.count > 1
                                ? containerSize.width / 2 : containerSize.width,
                            height: containerSize.height
                        )
                }
            }
            .frame(width: containerSize.width, height: containerSize.height)
        }
        // RTL 整体翻转后内容需翻正
        .scaleEffect(x: rtl ? -1 : 1)
    }
}

/// 单张漫画页：已解码显示图片，未解码显示占位（预加载中）
private struct ComicImagePage: View {
    let index: Int
    let images: [Int: UIImage]
    let fitWidth: Bool   // 条漫按宽度铺满；翻页模式按比例适应
    /// 已知页宽高比（高/宽）：条漫占位用真实高度，恢复定位不被解码膨胀顶偏
    var aspectRatio: CGFloat? = nil

    var body: some View {
        if let image = images[index] {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: fitWidth ? nil : .infinity)
        } else {
            ZStack {
                Color(white: 0.08)
                VStack(spacing: 8) {
                    ProgressView()
                        .tint(.white.opacity(0.7))
                    Text("第 \(index + 1) 页")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: fitWidth && aspectRatio == nil ? 420 : nil)
            // 已知宽高比：占位高度=宽×比（≈解码后真实高度），定位精准
            .aspectRatio(fitWidth ? aspectRatio.map { 1 / $0 } : nil, contentMode: .fit)
        }
    }
}

// MARK: - 双指缩放（UIScrollView 桥接）

/// 双指缩放容器（IOS-207）：捏合 1x~4x，双击放大/还原
private struct ZoomableScrollView<Content: View>: UIViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear

        // 未缩放时禁用平移让位给外层翻页（TabView 滑动），放大后经 scrollViewDidZoom 接管拖动
        scrollView.isScrollEnabled = false

        let hosted = UIHostingController(rootView: content)
        hosted.view.backgroundColor = .clear
        hosted.view.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(hosted.view)
        NSLayoutConstraint.activate([
            hosted.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            hosted.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            hosted.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            hosted.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            hosted.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            hosted.view.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
        context.coordinator.hosting = hosted
        context.coordinator.zoomView = hosted.view

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.hosting?.rootView = content
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var hosting: UIHostingController<Content>?
        weak var zoomView: UIView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { zoomView }

        /// 1x 时禁用手动滚动（翻页交给外层 TabView）；放大后才接管拖动
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            scrollView.isScrollEnabled = scrollView.zoomScale > 1.001
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > 1.01 {
                scrollView.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: zoomView)
                let rect = CGRect(
                    x: point.x - scrollView.bounds.width / 4,
                    y: point.y - scrollView.bounds.height / 4,
                    width: scrollView.bounds.width / 2,
                    height: scrollView.bounds.height / 2
                )
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

// MARK: - 条漫可见页偏好键

private struct WebtoonVisibleKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - 缩略图面板（IOS-210 控制层重设计：☰ / 「缩略图」chip）

/// 页面缩略图网格：点击跳页；缩略图按需加载（已解码页直接缩略 / 磁盘缓存解码 / 归档解压）
private struct ComicThumbnailSheet: View {
    @ObservedObject var viewModel: ComicReaderViewModel
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(0..<viewModel.pageCount, id: \.self) { index in
                            cell(index).id(index)
                        }
                    }
                    .padding(12)
                }
                .onAppear { proxy.scrollTo(viewModel.page, anchor: .center) }
            }
            .navigationTitle("缩略图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func cell(_ index: Int) -> some View {
        Button {
            onSelect(index)
            dismiss()
        } label: {
            ZStack {
                Color(white: 0.16)
                if let image = viewModel.thumbnails[index] {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView().tint(.white.opacity(0.5))
                }
            }
            .aspectRatio(1 / cellRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Text("\(index + 1)")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.black.opacity(0.6)))
                    .padding(3)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(
                        viewModel.page == index ? AppColors.primary : Color.white.opacity(0.12),
                        lineWidth: viewModel.page == index ? 2 : 0.5
                    )
            }
        }
        .buttonStyle(.plain)
        .task {
            if viewModel.thumbnails[index] == nil {
                _ = await viewModel.thumbnail(for: index)
            }
        }
    }

    /// 格子高宽比（取第 1 页比例兜底 1.4）
    private var cellRatio: CGFloat {
        max(viewModel.pageRatios[0] ?? viewModel.fallbackRatio ?? 1.4, 0.5)
    }
}

// MARK: - 亮度面板（IOS-210 控制层重设计：⋯ 菜单 / 「亮度」chip）

/// 亮度调节：复用全局阅读亮度偏好（reader.brightness），与小说阅读器同档；-1 = 跟随系统
private struct ComicBrightnessSheet: View {
    @ObservedObject var viewModel: ComicReaderViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("亮度")
                .font(.headline)
                .foregroundStyle(AppColors.textPrimary)
            HStack(spacing: 12) {
                Image(systemName: "sun.min").font(.caption)
                Slider(
                    value: Binding(
                        get: { max(AppSettings.Reader.brightness, 0) },
                        set: { viewModel.setBrightness($0) }
                    ),
                    in: 0...1
                )
                Image(systemName: "sun.max").font(.body)
            }
            .foregroundStyle(AppColors.textSecondary)
            HStack {
                Text(AppSettings.Reader.brightness >= 0
                     ? "\(Int((AppSettings.Reader.brightness * 100).rounded()))%"
                     : "跟随系统")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(AppColors.textSecondary)
                Spacer()
                Button("跟随系统") { viewModel.setBrightness(-1) }
                    .font(.caption)
            }
        }
        .padding(20)
        .presentationDetents([.height(176)])
        .presentationDragIndicator(.visible)
    }
}
