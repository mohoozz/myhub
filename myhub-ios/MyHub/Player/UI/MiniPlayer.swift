import SwiftUI

/// 悬浮式 mini 播放器（占位，TODO §4.4）：
/// 跨页面保持（RootView 顶层悬浮）、点击展开回全屏、下拉拖拽关闭；
/// 深/浅色均带细边框，避免与黑色背景融为一体（IOS-701）。
struct MiniPlayer: View {
    @EnvironmentObject private var player: PlayerPresenter
    @StateObject private var core = PlayerCore.shared
    @GestureState private var dragOffset: CGFloat = 0

    private var progressRatio: CGFloat {
        guard core.duration > 0 else { return 0 }
        return CGFloat(min(max(core.currentTime / core.duration, 0), 1))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppColors.primary.opacity(0.12))
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: player.current?.isAudioOnly == true ? "music.note" : "play.rectangle.fill")
                            .foregroundStyle(AppColors.primary)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.current?.title ?? "")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)
                    Text(player.current?.path ?? "")
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { core.togglePlayPause() } label: {
                    Image(systemName: core.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                Button { player.close() } label: {
                    Image(systemName: "xmark")
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.pressScale)
            .foregroundStyle(AppColors.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

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
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColors.separator, lineWidth: 0.5)   // 深浅色细边框
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
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
            TapGesture().onEnded { player.expand() }   // 点击展开回全屏
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
