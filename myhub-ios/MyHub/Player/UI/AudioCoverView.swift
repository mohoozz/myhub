import AVFoundation
import SwiftUI

/// 音频唱片封面模式（IOS-201 播放能力 / 纯音频模式 UI）：
/// - 播放时封面旋转、暂停停止（30fps 计时器驱动，暂停即冻结角度）；
/// - 封面来源统一走 `CoverService`（内存 + 磁盘缓存，与浏览页/锁屏同源，命中免重复网络拉取）：
///   同目录同名图片 / cover / folder / front → ID3 内嵌 albumart（兜底占位图标）；
/// - 加载完成后回填锁屏封面（`NowPlaying`），避免锁屏重复加载；
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
        .task(id: item.path) { await loadCover() }
    }

    // MARK: - 封面加载（统一 CoverService 缓存 + 回填锁屏）

    private func loadCover() async {
        let result = await CoverService.shared.cover(forItem: item)
        guard let image = result.image else { return }
        cover = image
        // 回填锁屏封面，避免 NowPlaying 再次加载同一封面
        NowPlaying.shared.setArtwork(image, for: item.path)
    }
}
