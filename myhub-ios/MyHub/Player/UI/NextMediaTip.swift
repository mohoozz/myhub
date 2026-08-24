import GRDB
import SwiftUI

/// 播完查找下一个（IOS-204）：在当前目录按浏览排序偏好查找下一个同类型（视频/音频）文件
enum NextMediaFinder {
    static func find(after item: PlayableItem) async -> (Connection, FileEntry)? {
        guard let connectionID = item.connectionID,
              let db = AppDatabase.shared.dbQueue,
              let connection = try? await db.read({ try Connection.fetchOne($0, id: connectionID) }),
              let adapter = try? AdapterFactory.makeAdapter(for: connection) else { return nil }

        let mediaType = MediaType.detect(ext: StoragePath.ext(of: item.path))
        guard mediaType == .video || mediaType == .audio else { return nil }

        let parent = StoragePath.parent(of: item.path)
        guard let siblings = try? await adapter.list(parent) else { return nil }
        let sameType = siblings.filter { !$0.isDir && MediaType.detect(ext: $0.ext) == mediaType }

        // 与浏览页一致的排序偏好（AppSettings.Browse.sortKey / sortAscending）
        let ascending = AppSettings.Browse.sortAscending
        let sorted: [FileEntry]
        switch AppSettings.Browse.sortKey {
        case .name:
            sorted = sameType.sorted {
                ascending
                    ? $0.name.naturalCompare($1.name) == .orderedAscending
                    : $0.name.naturalCompare($1.name) == .orderedDescending
            }
        case .size:
            sorted = sameType.sorted { ascending ? $0.size < $1.size : $0.size > $1.size }
        case .modTime:
            sorted = sameType.sorted { ascending ? $0.modTime < $1.modTime : $0.modTime > $1.modTime }
        }

        guard let index = sorted.firstIndex(where: { $0.path == item.path }),
              index + 1 < sorted.count else { return nil }
        return (connection, sorted[index + 1])
    }
}

/// 「下一个：xxx」底部提示（IOS-204）：5s 倒计时自动播放，点击立即播放，可取消
struct NextMediaTip: View {
    let entry: FileEntry
    let remaining: Int
    let onPlay: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                HStack(spacing: 12) {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("下一个")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                        Text(entry.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    // 倒计时环
                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.25), lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: CGFloat(remaining) / 5)
                            .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(remaining)")
                            .font(.caption2.monospacedDigit())
                    }
                    .frame(width: 28, height: 28)
                }
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.9))
        .background(.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.15), lineWidth: 0.5)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 480)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
