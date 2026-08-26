import SwiftUI

/// 远程封面组件（IOS-102 / IOS-702，浏览页与「正在阅读」页共用）：
/// - 立即渲染占位（类型图标），后台异步加载封面，完成后淡入替换；
/// - 失败保持占位图标；**封面加载不阻塞点击进入播放/阅读**（加载挂在 cell 的 task 上，与点击无关）；
/// - 探测到的视频时长经 `duration` Binding 回传（时长角标）。
struct RemoteCoverImage: View {
    let entry: FileEntry
    let connection: Connection
    let adapter: StorageAdapter
    /// 当前目录兄弟条目（音频按同名/cover/folder/front 约定找封面，零额外请求）
    var siblings: [FileEntry] = []
    @Binding var duration: Double?
    /// 沉浸占位（「正在阅读」网格卡）：无封面时类型渐变底 + 白色图标
    var immersivePlaceholder = false

    @State private var result: CoverResult?

    init(
        entry: FileEntry,
        connection: Connection,
        adapter: StorageAdapter,
        siblings: [FileEntry] = [],
        duration: Binding<Double?> = .constant(nil),
        immersivePlaceholder: Bool = false
    ) {
        self.entry = entry
        self.connection = connection
        self.adapter = adapter
        self.siblings = siblings
        self._duration = duration
        self.immersivePlaceholder = immersivePlaceholder
    }

    var body: some View {
        ZStack {
            if immersivePlaceholder {
                entry.coverPlaceholderGradient
            }
            if let image = result?.image {
                // 用 Color.clear 撑满容器，图片仅作为 overlay 填充，避免图片原始分辨率
                // 作为理想尺寸泄漏到外层布局（否则漫画/竖屏视频封面的卡片会被撑高、
                // 正常视频封面会比无封面的宽，导致网格卡片大小不一）。
                Color.clear
                    .overlay {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                    .transition(.opacity)
            } else {
                placeholderIcon
            }
        }
        .clipped()
        .task(id: entry.path) {
            guard !entry.isDir else { return }   // 文件夹恒用图标
            let loaded = await CoverService.shared.cover(
                for: entry, connection: connection, adapter: adapter, siblings: siblings
            )
            withAnimation(.appQuick) { result = loaded }
            duration = loaded.duration
        }
    }

    /// 无封面时的占位：去掉白底，仅显示放大后的类型/目录图标，尺寸随容器自适应
    /// （列表小缩略图与网格大卡都能得到足够大的图标）。
    private var placeholderIcon: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            Image(systemName: entry.placeholderSymbol)
                .font(.system(size: immersivePlaceholder ? 40 : max(30, side * 0.55)))
                .foregroundStyle(
                    immersivePlaceholder
                        ? Color.white.opacity(0.9)
                        : (entry.isDir ? AppColors.primary : AppColors.textSecondary)
                )
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

extension FileEntry {
    /// 无封面时的类型渐变底（参照旧版 Flutter 深色配色）
    var coverPlaceholderGradient: LinearGradient {
        let colors: [Color]
        switch MediaType.detect(ext: ext) {
        case .video: colors = [Color(hex: 0x0D0D2B), Color(hex: 0x000000)]
        case .audio: colors = [Color(hex: 0x0F2027), Color(hex: 0x203A43)]
        case .novel: colors = [Color(hex: 0x1A0533), Color(hex: 0x0D021A)]
        case .comic: colors = [Color(hex: 0x2D1515), Color(hex: 0x1A0A0A)]
        default: colors = [Color(hex: 0x232526), Color(hex: 0x000000)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// 占位 / 无封面时的类型图标
    var placeholderSymbol: String {
        if isDir { return "folder.fill" }
        switch MediaType.detect(ext: ext) {
        case .video: return "film"
        case .audio: return "music.note"
        case .novel: return "text.book.closed"
        case .comic: return "photo.stack"
        case .image: return "photo"
        case .subtitle: return "captions.bubble"
        case .other: return "doc"
        }
    }
}
