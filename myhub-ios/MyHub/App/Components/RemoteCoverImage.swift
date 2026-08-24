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

    @State private var result: CoverResult?

    init(
        entry: FileEntry,
        connection: Connection,
        adapter: StorageAdapter,
        siblings: [FileEntry] = [],
        duration: Binding<Double?> = .constant(nil)
    ) {
        self.entry = entry
        self.connection = connection
        self.adapter = adapter
        self.siblings = siblings
        self._duration = duration
    }

    var body: some View {
        ZStack {
            AppColors.cardBackground
            if let image = result?.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Image(systemName: entry.placeholderSymbol)
                    .font(.title2)
                    .foregroundStyle(entry.isDir ? AppColors.primary : AppColors.textSecondary)
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
}

extension FileEntry {
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
