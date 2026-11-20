import SwiftUI

/// 远程封面组件（浏览页与「正在阅读」页共用）
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
        case .archive: colors = [Color(hex: 0x1E2A38), Color(hex: 0x0B0F14)]   // 石板灰蓝
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
        case .archive: return "doc.zipper"
        case .image: return "photo"
        case .subtitle: return "captions.bubble"
        case .other: return "doc"
        }
    }
}
