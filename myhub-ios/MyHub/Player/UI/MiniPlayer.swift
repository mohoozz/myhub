import SwiftUI
import UIKit

/// 贴底式 mini 播放器（对齐 Flutter `MiniPlayer`，QQ 音乐风格）：
/// iPhone 上紧贴底部页签栏、宽度占满屏幕；点击展开回全屏、下拉拖拽关闭。
///
/// 封面 64×64 圆角 8、顶部溢出 8px（浮在卡片上边界，突出显示）；
/// 标题显示「标题」，副标题显示「作者」（不显示路径）；
/// 视频播放时封面实时渲染画面（`MiniCoverPreview`），音频播放时显示内嵌/同目录封面（缺失回落图标）。
struct MiniPlayer: View {
    @EnvironmentObject private var player: PlayerPresenter
    @StateObject private var core = PlayerCore.shared
    @GestureState private var dragOffset: CGFloat = 0
    /// 音频内嵌/同目录封面（异步经 `CoverService` 加载，与全屏/锁屏同源缓存，缺失时回落 music.note 图标）
    @State private var audioCover: UIImage?

    /// 封面尺寸 / 顶部溢出（对齐 Flutter compact 布局）
    private let coverSize: CGFloat = 64
    private let coverOverflow: CGFloat = 8
    /// 封面距卡片左缘 / 封面与标题区间距
    private let coverLeading: CGFloat = 16
    private let coverGap: CGFloat = 12

    private var progressRatio: CGFloat {
        guard core.duration > 0 else { return 0 }
        return CGFloat(min(max(core.currentTime / core.duration, 0), 1))
    }

    /// 「作者 - 标题」解析：标题行显示标题，副标题行显示作者（对齐 Flutter，不再显示路径）
    private var parsedTitle: String {
        guard let title = player.current?.title else { return "" }
        return NowPlaying.parseAuthorTitle(title).title
    }

    private var parsedAuthor: String? {
        guard let title = player.current?.title else { return nil }
        return NowPlaying.parseAuthorTitle(title).author
    }

    /// 音频模式（含用户强制仅音频）→ 图标占位；否则视频实时画面
    private var isAudio: Bool {
        core.isAudioOnly || player.current?.isAudioOnly == true
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 卡片主体（不含封面）。封面作为 ZStack 兄弟节点而非卡片子节点，
            // 顶部溢出才不会被卡片的 ClipShape 裁掉。
            // 贴底布局：与底部页签栏同背景色、仅顶部圆角、宽度占满（对齐 Flutter mini）。
            cardBody
                .background(AppColors.sidebarBackground)
                .clipShape(TopRoundedShape(radius: 16))

            // 封面浮层：顶部溢出 8px（QQ 音乐观感）
            cover
                .padding(.leading, coverLeading)
                .offset(y: -coverOverflow)
        }
        .offset(y: dragOffset)
        .gesture(
            DragGesture()
                .updating($dragOffset) { value, state, _ in
                    state = max(0, value.translation.height)
                }
                .onEnded { value in
                    if value.translation.height > 60 { player.close() }   // 下拉拖拽关闭
                }
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
        // 切歌或音/视频模式切换时重新加载音频封面
        .task(id: coverLoadKey) { await loadAudioCover() }
    }

    /// 音频封面加载键：随播放路径或音/视频模式变化而变化，触发重新加载
    private var coverLoadKey: String {
        "\(player.current?.path ?? "")|\(isAudio)"
    }

    /// 音频模式加载内嵌 / 同目录封面（复用 `CoverService` 内存/磁盘缓存，命中即时返回，与全屏/锁屏同源）。
    /// 加载到即显示并回填锁屏封面；缺失或非音频时保持图标占位。
    private func loadAudioCover() async {
        audioCover = nil   // 切歌先清空，避免残留上一首封面
        guard isAudio, let item = player.current else { return }
        let result = await CoverService.shared.cover(forItem: item)
        // 加载期间可能已切歌，回填前确认仍是当前条目
        guard player.current?.path == item.path, let image = result.image else { return }
        audioCover = image
        NowPlaying.shared.setArtwork(image, for: item.path)
    }

    /// 卡片主体：标题/副标题 + 右侧操作按钮 + 底部 2px 进度条
    private var cardBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // 标题区（含空白）点击展开回全屏；按钮区单独响应，不再整卡 expand
                VStack(alignment: .leading, spacing: 3) {
                    Text(parsedTitle)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)
                    if let author = parsedAuthor {
                        Text(author)
                            .font(.footnote)
                            .foregroundStyle(AppColors.textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { player.expand() }
                controls
            }
            .buttonStyle(.pressScale)
            .foregroundStyle(AppColors.textPrimary)
            .padding(.leading, coverLeading + coverSize + coverGap)
            .padding(.trailing, 12)
            .padding(.top, 8)
            .padding(.bottom, 12)

            // 播放进度细条（灵动岛 / QQ 音乐风格）
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppColors.separator)
                    Capsule()
                        .fill(AppColors.primary)
                        .frame(width: geometry.size.width * progressRatio)
                }
            }
            .frame(height: 2)
            .padding(.horizontal, coverLeading)
            .padding(.bottom, 8)
        }
    }

    /// 右侧操作按钮：播放暂停 / 关闭（按钮放大，同时撑高卡片主体，避免封面遮住进度条）
    private var controls: some View {
        HStack(spacing: 4) {
            Button { core.togglePlayPause() } label: {
                Group {
                    if core.isSeeking || core.state == .loading || core.state == .buffering {
                        ProgressView()
                            .tint(AppColors.primary)
                    } else {
                        Image(systemName: core.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 24, weight: .medium))
                    }
                }
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
            }
            Button { player.close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(width: 44, height: 52)
                    .contentShape(Rectangle())
            }
        }
    }

    /// 封面：视频模式实时画面 / 音频模式内嵌封面（缺失回落图标）；点击展开全屏
    @ViewBuilder
    private var cover: some View {
        Group {
            if isAudio {
                if let audioCover {
                    Image(uiImage: audioCover)
                        .resizable()
                        .scaledToFill()   // 填满封面（对齐全屏/浏览页 BoxFit.cover 观感）
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppColors.primary.opacity(0.12))
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.system(size: 24, weight: .medium))
                                .foregroundStyle(AppColors.primary)
                        }
                }
            } else {
                MiniCoverPreview(output: core.videoOutput)
            }
        }
        .frame(width: coverSize, height: coverSize)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppColors.separator, lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture { player.expand() }
    }
}

/// 仅顶部圆角（贴底 mini 播放器，对齐 Flutter mini 顶部 16 圆角）
private struct TopRoundedShape: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, min(rect.width, rect.height))
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.maxY))
        path.addLine(to: CGPoint(x: 0, y: r))
        path.addArc(center: CGPoint(x: r, y: r), radius: r,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX - r, y: 0))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: r), radius: r,
                    startAngle: .degrees(270), endAngle: .degrees(360), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
