import AVFoundation
import GRDB
import SwiftUI

/// 音频唱片封面模式（IOS-201 播放能力 / 纯音频模式 UI）：
/// - 播放时封面旋转、暂停停止（30fps 计时器驱动，暂停即冻结角度）；
/// - 封面来源：同目录同名图片 / cover / folder / front → ID3 内嵌 albumart（兜底占位图标）；
/// - 标题/作者按「作者 - 标题」文件名解析。
struct AudioCoverView: View {
    let item: PlayableItem
    let isPlaying: Bool

    @State private var cover: UIImage?
    @State private var angle: Double = 0

    private let ticker = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    private var parsed: (author: String?, title: String) {
        NowPlaying.parseAuthorTitle(item.title)
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle()
                    .fill(.white.opacity(0.06))
                if let cover {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 72))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .clipShape(Circle())
            .overlay {
                Circle().stroke(.white.opacity(0.18), lineWidth: 1)
            }
            .frame(width: 240, height: 240)
            .rotationEffect(.degrees(angle))
            .onReceive(ticker) { _ in
                guard isPlaying else { return }
                angle = (angle + 1.2).truncatingRemainder(dividingBy: 360)
            }

            VStack(spacing: 6) {
                Text(parsed.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let author = parsed.author {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 32)
            Spacer()
        }
        .task { await loadCover() }
    }

    // MARK: - 封面加载

    /// 同目录约定优先，ID3 内嵌兜底
    private func loadCover() async {
        if let siblingCover = await loadSiblingCover() {
            cover = siblingCover
            return
        }
        await loadEmbeddedCover()
    }

    /// 同目录同名图 / cover / folder / front（复用 CoverService 约定匹配）
    private func loadSiblingCover() async -> UIImage? {
        guard let connectionID = item.connectionID,
              let db = AppDatabase.shared.dbQueue,
              let connection = try? db.read({ try Connection.fetchOne($0, id: connectionID) }),
              let adapter = try? AdapterFactory.makeAdapter(for: connection) else { return nil }

        let parent = StoragePath.parent(of: item.path)
        guard let siblings = try? await adapter.list(parent) else { return nil }

        let selfEntry = FileEntry(
            name: item.title, path: item.path, isDir: false,
            size: 0, modTime: Date(), ext: StoragePath.ext(of: item.path)
        )
        guard let coverEntry = CoverService.audioCoverEntry(in: siblings, for: selfEntry),
              let data = try? await readAll(adapter: adapter, path: coverEntry.path) else { return nil }
        return UIImage(data: data)
    }

    /// ID3 内嵌封面（经当前播放 URL 读取，本地/代理串流均可）
    private func loadEmbeddedCover() async {
        guard let url = await PlayerCore.shared.request?.url else { return }
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata) else { return }
        for element in metadata where element.commonKey == .artwork {
            if let data = try? await element.load(.dataValue), let image = UIImage(data: data) {
                cover = image
                return
            }
        }
    }

    private func readAll(adapter: StorageAdapter, path: String) async throws -> Data {
        let stream = try await adapter.readStream(path, range: nil)
        var data = Data()
        for try await chunk in stream {
            data.append(chunk)
            if data.count > 24 * 1024 * 1024 { break }
        }
        return data
    }
}
