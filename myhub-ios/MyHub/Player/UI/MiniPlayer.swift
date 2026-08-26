import SwiftUI

/// 悬浮式 mini 播放器（对齐 Flutter `MiniPlayer`，QQ 音乐风格）：
/// 跨页面保持（RootView 顶层悬浮）、点击展开回全屏、下拉拖拽关闭。
///
/// 封面 56×56 圆角 8、顶部溢出 8px（浮在卡片上边界，突出显示）；
/// 视频播放时封面实时渲染画面（`MiniCoverPreview`），音频播放时显示图标。
struct MiniPlayer: View {
    @EnvironmentObject private var player: PlayerPresenter
    @StateObject private var core = PlayerCore.shared
    @GestureState private var dragOffset: CGFloat = 0

    /// 封面尺寸 / 顶部溢出（对齐 Flutter compact 布局）
    private let coverSize: CGFloat = 56
    private let coverOverflow: CGFloat = 8
    /// 封面距卡片左缘 / 封面与标题区间距
    private let coverLeading: CGFloat = 12
    private let coverGap: CGFloat = 8

    private var progressRatio: CGFloat {
        guard core.duration > 0 else { return 0 }
        return CGFloat(min(max(core.currentTime / core.duration, 0), 1))
    }

    /// 音频模式（含用户强制仅音频）→ 图标占位；否则视频实时画面
    private var isAudio: Bool {
        core.isAudioOnly || player.current?.isAudioOnly == true
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 卡片主体（不含封面）。封面作为 ZStack 兄弟节点而非卡片子节点，
            // 顶部溢出才不会被卡片的 ClipShape 裁掉。
            cardBody
                .background(AppColors.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppColors.separator, lineWidth: 0.5)   // 深浅色细边框
                }
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)

            // 封面浮层：顶部溢出 8px（QQ 音乐观感）
            cover
                .padding(.leading, coverLeading)
                .offset(y: -coverOverflow)
        }
        .padding(.horizontal, 12)
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
        .simultaneousGesture(
            TapGesture().onEnded { player.expand() }   // 点击卡片展开回全屏
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// 卡片主体：标题/副标题 + 右侧操作按钮 + 底部 2px 进度条
    private var cardBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.current?.title ?? "")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)
                    Text(player.current?.path ?? "")
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                controls
            }
            .buttonStyle(.pressScale)
            .foregroundStyle(AppColors.textPrimary)
            .padding(.leading, coverLeading + coverSize + coverGap)
            .padding(.trailing, 8)
            .padding(.top, 4)
            .padding(.bottom, 6)

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
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }

    /// 右侧操作按钮：播放暂停 / 关闭
    private var controls: some View {
        HStack(spacing: 8) {
            Button { core.togglePlayPause() } label: {
                Group {
                    if core.isSeeking || core.state == .loading || core.state == .buffering {
                        ProgressView()
                            .tint(AppColors.primary)
                    } else {
                        Image(systemName: core.isPlaying ? "pause.fill" : "play.fill")
                    }
                }
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            Button { player.close() } label: {
                Image(systemName: "xmark")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
        }
    }

    /// 封面：视频模式实时画面 / 音频模式图标占位；点击展开全屏
    @ViewBuilder
    private var cover: some View {
        Group {
            if isAudio {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppColors.primary.opacity(0.12))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(AppColors.primary)
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
