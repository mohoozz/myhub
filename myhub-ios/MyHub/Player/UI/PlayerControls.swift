import AVKit
import SwiftUI

/// 播放控制栏（IOS-201 / IOS-701）：
/// 顶栏——圆形悬浮按钮：退出 / PiP / 音轨 / 更多（纯音频、小窗、解码方式）；
/// 底栏——标题 + 深色圆角控制卡片：进度条（含缓冲段 + 拖动）+ 倍速、当前/剩余时间、
///       AirPlay、快退/快进、播放暂停、字幕（内嵌 + 外挂）。
struct PlayerControls: View {
    @ObservedObject var core: PlayerCore
    @ObservedObject var subtitles: SubtitleManager
    @ObservedObject var pip: PiPState
    let item: PlayableItem?
    let onExit: () -> Void
    let onMini: () -> Void
    /// 任意交互回调（重置控制层自动隐藏计时）
    let onInteraction: () -> Void

    @State private var scrubValue: Double = 0
    @State private var scrubbing = false

    private var displayTime: Double {
        scrubbing ? scrubValue : core.currentTime
    }

    private var remainingTime: Double {
        max(core.duration - displayTime, 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            bottomSection
        }
        .onAppear { scrubValue = core.currentTime }
        .onChange(of: core.currentTime) { newValue in
            if !scrubbing { scrubValue = newValue }
        }
    }

    // MARK: - 顶栏（圆形悬浮按钮）

    private var topBar: some View {
        HStack(spacing: 12) {
            roundButton("xmark", label: "退出", action: onExit)
            if pip.isSupported, !core.isAudioOnly, item?.isAudioOnly == false {
                roundButton("pip.enter", label: "画中画") {
                    pip.start()
                    onInteraction()
                }
            }
            Spacer()
            audioTrackMenu
            moreMenu
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func roundButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            roundIcon(systemName)
        }
        .buttonStyle(.pressScale)
        .accessibilityLabel(label)
    }

    private func roundIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.black.opacity(0.55))
            .clipShape(Circle())
    }

    // MARK: - 底栏（标题 + 圆角控制卡片）

    private var bottomSection: some View {
        VStack(spacing: 10) {
            Text(item?.title ?? "")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .padding(.horizontal, 28)

            VStack(spacing: 12) {
                // 进度条 + 倍速
                HStack(spacing: 10) {
                    progressBar
                    rateMenu
                }

                // 当前时间 / 剩余时间
                HStack {
                    Text(DisplayFormatters.duration(displayTime))
                    Spacer()
                    Text("-\(DisplayFormatters.duration(remainingTime))")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))

                // 播放控制：AirPlay / 快退 / 播放暂停 / 快进 / 字幕
                HStack {
                    AirPlayRoutePicker()
                        .frame(width: 32, height: 32)
                        .accessibilityLabel("AirPlay")
                    Spacer()
                    HStack(spacing: 40) {
                        skipButton(systemName: "backward.end.fill",
                                   delta: -AppSettings.Player.seekStepSeconds, label: "快退")
                        playPauseButton
                        skipButton(systemName: "forward.end.fill",
                                   delta: AppSettings.Player.seekStepSeconds, label: "快进")
                    }
                    Spacer()
                    subtitleMenu
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.black.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 14)
        }
        .padding(.bottom, 6)
    }

    private func skipButton(systemName: String, delta: Double, label: String) -> some View {
        Button {
            core.seek(by: delta)
            onInteraction()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 24))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.pressScale)
        .accessibilityLabel(label)
    }

    private var playPauseButton: some View {
        Button {
            core.togglePlayPause()
            onInteraction()
        } label: {
            Image(systemName: core.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 32))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.pressScale)
        .accessibilityLabel(core.isPlaying ? "暂停" : "播放")
    }

    /// 自定义进度条：轨道 / 缓冲段 / 已播放 / 拖钮，支持点击定位与拖动
    private var progressBar: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.25))
                    .frame(height: 5)
                Capsule()
                    .fill(.white.opacity(0.4))
                    .frame(width: width * bufferRatio, height: 5)
                Capsule()
                    .fill(.white)
                    .frame(width: width * playedRatio, height: 5)
                Circle()
                    .fill(.white)
                    .frame(width: 12, height: 12)
                    .offset(x: min(max(0, width * playedRatio - 6), max(width - 12, 0)))
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrubbing = true
                        scrubValue = time(at: value.location.x, width: width)
                    }
                    .onEnded { value in
                        scrubValue = time(at: value.location.x, width: width)
                        core.seek(to: scrubValue)
                        scrubbing = false
                        onInteraction()
                    }
            )
        }
        .frame(height: 24)
    }

    private var playedRatio: CGFloat {
        guard core.duration > 0 else { return 0 }
        return CGFloat(min(max(displayTime / core.duration, 0), 1))
    }

    private var bufferRatio: CGFloat {
        guard core.duration > 0 else { return 0 }
        return CGFloat(min(max(core.bufferedTime / core.duration, 0), 1))
    }

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(x / width, 0), 1) * core.duration
    }

    // MARK: - 倍速 / 字幕 / 音轨 / 更多

    private var rateMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0], id: \.self) { option in
                Button {
                    core.setRate(Float(option))
                    onInteraction()
                } label: {
                    checkLabel(rateTitle(Float(option)),
                               checked: abs(core.rate - Float(option)) < 0.01)
                }
            }
        } label: {
            Text(rateTitle(core.rate))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.white.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    /// 整数倍速显示一位小数（1.0x），其余原样（0.75x）
    private func rateTitle(_ rate: Float) -> String {
        rate == rate.rounded() ? String(format: "%.1fx", rate) : String(format: "%gx", rate)
    }

    private var subtitleMenu: some View {
        Menu {
            Button {
                core.selectSubtitleTrack(nil)
                subtitles.clearSelection()
                onInteraction()
            } label: {
                checkLabel("关闭字幕",
                           checked: core.selectedSubtitleTrackID == nil && subtitles.activeExternalPath == nil)
            }
            if !core.subtitleTracks.isEmpty {
                Section("内嵌字幕") {
                    ForEach(core.subtitleTracks) { track in
                        Button {
                            subtitles.clearSelection()
                            core.selectSubtitleTrack(track.id)
                            onInteraction()
                        } label: {
                            checkLabel(track.name, checked: core.selectedSubtitleTrackID == track.id)
                        }
                    }
                }
            }
            if !subtitles.externalTracks.isEmpty {
                Section("外挂字幕") {
                    ForEach(subtitles.externalTracks) { track in
                        Button {
                            core.selectSubtitleTrack(nil)
                            Task { await subtitles.select(track: track, connectionID: item?.connectionID) }
                            onInteraction()
                        } label: {
                            checkLabel(track.displayName,
                                       checked: subtitles.activeExternalPath == track.path)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble")
                .font(.system(size: 20))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
        }
        .opacity(core.subtitleTracks.isEmpty && subtitles.externalTracks.isEmpty ? 0.35 : 1)
    }

    private var audioTrackMenu: some View {
        Menu {
            ForEach(core.audioTracks) { track in
                Button {
                    core.selectAudioTrack(track.id)
                    onInteraction()
                } label: {
                    checkLabel(track.name, checked: core.selectedAudioTrackID == track.id)
                }
            }
        } label: {
            roundIcon("speaker.wave.2.fill")
        }
        .opacity(core.audioTracks.count > 1 ? 1 : 0.5)
        .disabled(core.audioTracks.count <= 1)
        .accessibilityLabel("音轨")
    }

    private var moreMenu: some View {
        Menu {
            if item?.isAudioOnly == false {
                Button {
                    core.setAudioOnly(!core.isAudioOnly)
                    onInteraction()
                } label: {
                    Label(core.isAudioOnly ? "退出纯音频模式" : "纯音频模式",
                          systemImage: core.isAudioOnly ? "waveform.circle.fill" : "waveform.circle")
                }
            }
            Button {
                onMini()
            } label: {
                Label("小窗播放", systemImage: "chevron.down")
            }
            if let kind = core.engineKind {
                Divider()
                Text("\(kind.displayName)解码")
            }
        } label: {
            roundIcon("ellipsis")
        }
        .accessibilityLabel("更多")
    }

    private func checkLabel(_ title: String, checked: Bool) -> some View {
        HStack {
            Text(title)
            if checked { Image(systemName: "checkmark") }
        }
    }
}

/// AirPlay 路由选择器（AVRoutePickerView 桥接，投屏面板由系统弹出）
private struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = true
        picker.tintColor = .white
        picker.activeTintColor = .systemBlue
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
