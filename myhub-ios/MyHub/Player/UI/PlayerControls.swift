import SwiftUI

/// 播放控制栏（IOS-201 / IOS-701）：
/// 顶栏——退出（直接退出）/ 标题 + 引擎徽标 / 纯音频切换 / PiP / 进入 mini；
/// 底栏——播放暂停、进度条（含缓冲段 + 拖动）、时间、倍速（0.5~3.0x）、字幕（内嵌 + 外挂）、音轨。
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

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            bottomBar
        }
        .onAppear { scrubValue = core.currentTime }
        .onChange(of: core.currentTime) { newValue in
            if !scrubbing { scrubValue = newValue }
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 18) {
            Button(action: onExit) {
                Image(systemName: "xmark")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item?.title ?? "")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let kind = core.engineKind {
                    Text("\(kind.displayName)解码")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer()
            if item?.isAudioOnly == false {
                Button {
                    core.setAudioOnly(!core.isAudioOnly)
                    onInteraction()
                } label: {
                    Image(systemName: core.isAudioOnly ? "waveform.circle.fill" : "waveform.circle")
                }
                .accessibilityLabel("纯音频模式")
            }
            if pip.isSupported, !core.isAudioOnly, item?.isAudioOnly == false {
                Button {
                    pip.start()
                    onInteraction()
                } label: {
                    Image(systemName: "pip.enter")
                }
            }
            Button(action: onMini) {
                Image(systemName: "chevron.down")
            }
        }
        .font(.headline)
        .foregroundStyle(.white)
        .padding()
        .background(topGradient)
    }

    // MARK: - 底栏

    private var bottomBar: some View {
        VStack(spacing: 12) {
            // 进度条 + 缓冲段
            HStack(spacing: 10) {
                Text(DisplayFormatters.duration(displayTime))
                progressBar
                Text(DisplayFormatters.duration(core.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))

            // 控制按钮
            HStack(spacing: 28) {
                Button {
                    core.togglePlayPause()
                    onInteraction()
                } label: {
                    Image(systemName: core.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }
                rateMenu
                subtitleMenu
                audioTrackMenu
            }
            .foregroundStyle(.white)
        }
        .padding()
        .background(bottomGradient)
    }

    /// 自定义进度条：轨道 / 缓冲段 / 已播放 / 拖钮，支持点击定位与拖动
    private var progressBar: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule()
                    .fill(.white.opacity(0.4))
                    .frame(width: width * bufferRatio)
                Capsule()
                    .fill(AppColors.primary)
                    .frame(width: width * playedRatio)
                Circle()
                    .fill(.white)
                    .frame(width: 12, height: 12)
                    .offset(x: max(0, width * playedRatio - 6))
            }
            .frame(height: 20)
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
        .frame(height: 20)
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

    // MARK: - 倍速 / 字幕 / 音轨

    private var rateMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0], id: \.self) { option in
                Button {
                    core.setRate(Float(option))
                    onInteraction()
                } label: {
                    checkLabel(String(format: "%gx", option),
                               checked: abs(core.rate - Float(option)) < 0.01)
                }
            }
        } label: {
            Text(String(format: "%gx", core.rate))
                .font(.subheadline.weight(.medium).monospacedDigit())
                .frame(minWidth: 44)
        }
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
            Image(systemName: "person.wave.2")
        }
        .opacity(core.audioTracks.count > 1 ? 1 : 0.35)
        .disabled(core.audioTracks.count <= 1)
    }

    private func checkLabel(_ title: String, checked: Bool) -> some View {
        HStack {
            Text(title)
            if checked { Image(systemName: "checkmark") }
        }
    }

    // MARK: - 渐变背景（保证白字可读性）

    private var topGradient: some View {
        LinearGradient(
            colors: [.black.opacity(0.65), .clear],
            startPoint: .top, endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

    private var bottomGradient: some View {
        LinearGradient(
            colors: [.clear, .black.opacity(0.65)],
            startPoint: .top, endPoint: .bottom
        )
        .allowsHitTesting(false)
    }
}
