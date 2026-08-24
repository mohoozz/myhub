import SwiftUI
import UIKit

/// 漫画阅读器（TODO §6 / IOS-207）：
/// - 单页 / 双页（横屏·平板自动启用，从右向左 / 从左向右可切换并持久化）/ 条漫（纵向连续滚动）；
/// - 双指缩放（UIScrollView 桥接）；点击中央呼出控制层；
/// - 页码进度直接恢复（条漫模式经 ScrollViewReader 程序滚动定位）；
/// - 翻完最后一页弹出「下一本」提示（5s 倒计时自动打开）。
struct ComicReaderView: View {
    let context: NovelOpenContext
    var onClose: () -> Void = {}
    var onOpenNext: (FileEntry) -> Void = { _ in }

    @StateObject private var viewModel: ComicReaderViewModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var controlsVisible = false
    /// 条漫模式程序滚动目标（ScrollViewReader 消费）
    @State private var scrollIntent: Int?

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

            // 翻完推荐下一本（底部提示 + 5s 倒计时）
            if let candidate = viewModel.nextCandidate {
                VStack {
                    Spacer()
                    NextMediaTip(
                        entry: candidate,
                        remaining: viewModel.nextCountdown,
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
        .animation(.appQuick, value: viewModel.nextCandidate != nil)
        .animation(.appQuick, value: viewModel.toast)
        .statusBarHidden(!controlsVisible)
        .onReceive(NotificationCenter.default.publisher(for: .comicOpenNext)) { note in
            // 倒计时结束自动打开下一本
            guard let candidate = note.userInfo?["entry"] as? FileEntry else { return }
            onOpenNext(candidate)
        }
        .onAppear { viewModel.load() }
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
                // 最接近屏幕中点的页视为当前页（程序滚动期间忽略回写）
                guard scrollIntent == nil, !values.isEmpty else { return }
                let mid = UIScreen.main.bounds.height / 2
                if let best = values.min(by: { abs($0.value - mid) < abs($1.value - mid) })?.key,
                   best != viewModel.page {
                    viewModel.goToPage(best)
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

    /// 程序滚动到当前页（首次进入恢复 / 切入条漫 / slider 跳转）
    private func scrollToCurrent(_ reader: ScrollViewProxy, animated: Bool) {
        let target = viewModel.page
        guard target > 0 else { return }
        scrollIntent = target
        DispatchQueue.main.async {
            if animated {
                withAnimation(.appQuick) { reader.scrollTo(target, anchor: .top) }
            } else {
                reader.scrollTo(target, anchor: .top)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { scrollIntent = nil }
        }
    }

    private func webtoonPage(_ index: Int) -> some View {
        ComicImagePage(index: index, images: viewModel.images, fitWidth: true)
            .id(index)
            .background(
                // 可见页回写（条漫恢复页码显示）
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: WebtoonVisibleKey.self,
                        value: [index: proxy.frame(in: .named("webtoon")).midY]
                    )
                }
            )
    }

    // MARK: - 控制层

    @ViewBuilder
    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            // 顶栏：关闭 / 书名 / 模式菜单
            HStack(spacing: 12) {
                Button { onClose() } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                Text((context.entry.name as NSString).deletingPathExtension)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Menu {
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
                } label: {
                    Image(systemName: viewModel.mode.symbol)
                        .font(.body)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.75), .clear],
                    startPoint: .top, endPoint: .bottom
                )
            )

            Spacer()

            // 底栏：页码进度 / 方向切换 / 模式切换
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Text("\(displayPage)/\(viewModel.pageCount)")
                        .font(.caption.monospacedDigit())
                    Slider(
                        value: Binding(
                            get: { Double(viewModel.page) },
                            set: { jumpToPage(Int($0.rounded())) }
                        ),
                        in: 0...Double(max(viewModel.pageCount - 1, 1)),
                        step: 1
                    )
                    .tint(.white)
                    // 双页方向（含自动）；条漫模式隐藏（纵向滚动无方向）
                    if viewModel.mode == .double {
                        Button {
                            viewModel.direction = isRightToLeft ? .leftToRight : .rightToLeft
                        } label: {
                            Image(systemName: isRightToLeft
                                  ? "arrow.left.to.line" : "arrow.right.to.line")
                                .font(.caption)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)

                HStack(spacing: 0) {
                    ForEach(ComicReadMode.allCases, id: \.self) { mode in
                        Button {
                            switchMode(mode)
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: mode.symbol)
                                    .font(.body)
                                Text(mode.displayName)
                                    .font(.caption2)
                            }
                            .foregroundStyle(viewModel.mode == mode ? .white : .white.opacity(0.45))
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            .padding(.top, 10)
            .padding(.bottom, 10)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.8)],
                    startPoint: .top, endPoint: .bottom
                )
            )
        }
        .opacity(controlsVisible ? 1 : 0)
        .allowsHitTesting(controlsVisible)
        .animation(.appQuick, value: controlsVisible)
    }

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
            .frame(height: fitWidth ? 420 : nil)
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

        // 未缩放时平移手势让位给外层翻页（TabView 滑动），放大后才接管拖动
        scrollView.panGestureRecognizer.delegate = context.coordinator

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

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        weak var hosting: UIHostingController<Content>?
        weak var zoomView: UIView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { zoomView }

        /// 1x 时平移手势不生效（翻页交给外层 TabView）；放大后才接管拖动
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let scrollView = gestureRecognizer.view as? UIScrollView,
                  gestureRecognizer == scrollView.panGestureRecognizer else { return true }
            return scrollView.zoomScale > 1.001
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
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}
