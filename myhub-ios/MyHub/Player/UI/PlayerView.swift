import SwiftUI

/// 全屏播放器（TODO §4.3，沉浸纯黑）：
/// - 渲染层：视频画面（VideoRenderView）/ 纯音频唱片封面（AudioCoverView）；
/// - 手势层（GestureHandler）+ 中央悬浮数值胶囊；字幕 SwiftUI 浮层；
/// - 控制栏 3s 自动隐藏（播放中），点击切换；
/// - 中央「加载圈」与「大播放键」互斥不重叠；暂停/播放图标方向正确；
/// - 「退出」直接退出，「进入 mini」为独立按钮（IOS-701）。
struct PlayerView: View {
    @EnvironmentObject private var player: PlayerPresenter
    @StateObject private var core = PlayerCore.shared
    @StateObject private var subtitles = SubtitleManager()
    @StateObject private var pip = PiPState()

    @State private var showControls = true
    /// 界面锁定（长按进入；锁定后手势层失效）
    @State private var isInterfaceLocked = false
    @State private var feedback: GestureFeedback?
    @State private var hideTask: Task<Void, Never>?
    /// 中央下拉进入 mini 的跟随偏移
    @State private var miniDragOffset: CGFloat = 0
    /// 播完推荐下一个（IOS-204）
    @State private var nextCandidate: (connection: Connection, entry: FileEntry)?
    @State private var nextCountdown = 5
    @State private var nextTask: Task<Void, Never>?

    private var isAudioPresentation: Bool {
        core.isAudioOnly || player.current?.isAudioOnly == true
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 渲染层
            if isAudioPresentation {
                if let item = player.current {
                    AudioCoverView(item: item, isPlaying: core.isPlaying)
                }
            } else {
                VideoRenderView(output: core.videoOutput, pip: pip)
                    .ignoresSafeArea()
            }

            // 手势层
            PlayerGestureLayer(
                core: core,
                feedback: $feedback,
                miniDragOffset: $miniDragOffset,
                isLocked: $isInterfaceLocked,
                onToggleControls: { toggleControls() },
                onMini: { player.enterMini() },
                onLock: { lockInterface() }
            )

            // 字幕浮层
            if let text = subtitles.currentText, !text.isEmpty {
                VStack {
                    Spacer()
                    Text(text)
                        .font(.system(size: AppSettings.Player.subtitleFontSize, weight: .medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.55))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(.horizontal, 24)
                        .padding(.bottom, showControls ? 132 : 48)
                }
                .animation(.appQuick, value: showControls)
            }

            // 中央状态（加载圈 / 大播放键互斥）
            centerOverlay

            // 中央悬浮数值胶囊
            if let feedback {
                GestureFeedbackCapsule(feedback: feedback)
                    .transition(.opacity)
            }

            // 控制层
            if showControls {
                PlayerControls(
                    core: core,
                    subtitles: subtitles,
                    pip: pip,
                    item: player.current,
                    onExit: { player.close() },
                    onMini: { player.enterMini() },
                    onInteraction: { resetHideTimer() }
                )
                .transition(.opacity)
            }

            // 界面锁定（长按进入；锁定后手势层失效，仅显示解锁入口）
            if isInterfaceLocked {
                VStack {
                    Button {
                        unlockInterface()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 14, weight: .semibold))
                            Text("已锁定，点击解锁")
                                .font(.footnote.weight(.semibold))
                        }
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.55))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.pressScale)
                    .padding(.top, 56)
                    Spacer()
                }
                .transition(.opacity)
            }

            // 播完推荐下一个（底部提示 + 5s 倒计时）
            if let nextCandidate {
                VStack {
                    Spacer()
                    NextMediaTip(
                        entry: nextCandidate.entry,
                        remaining: nextCountdown,
                        onPlay: { playNext() },
                        onCancel: { cancelNext() }
                    )
                    .padding(.bottom, showControls ? 180 : 96)
                }
                .animation(.appQuick, value: showControls)
            }
        }
        .offset(y: miniDragOffset)   // 中央下拉跟随手指（进入 mini 过渡动画）
        .opacity(1 - min(Double(miniDragOffset) / 1200, 0.35))
        .immersive()
        .onAppear {
            resetHideTimer()
            Task {
                await subtitles.discover(
                    connectionID: player.current?.connectionID,
                    mediaPath: player.current?.path ?? ""
                )
            }
        }
        .onDisappear {
            hideTask?.cancel()
            nextTask?.cancel()
        }
        .onChange(of: core.currentTime) { newValue in
            subtitles.update(currentTime: newValue)
        }
        .onChange(of: core.state) { newState in
            if newState == .playing { resetHideTimer() }
            if newState == .ended { prepareNext() }
            if newState == .playing, nextCandidate != nil { cancelNext() }
        }
        .onChange(of: player.current) { _ in cancelNext() }
    }

    // MARK: - 播完推荐下一个（IOS-204）

    /// 播放结束：查找同目录下一个同类型文件，底部提示 5s 倒计时自动播放
    private func prepareNext() {
        nextTask?.cancel()
        guard let item = player.current else { return }
        nextTask = Task { @MainActor in
            guard let candidate = await NextMediaFinder.find(after: item), !Task.isCancelled else { return }
            withAnimation(.appQuick) { nextCandidate = candidate }
            for remaining in stride(from: 5, through: 1, by: -1) {
                nextCountdown = remaining
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
            }
            playNext()
        }
    }

    private func playNext() {
        guard let candidate = nextCandidate else { return }
        cancelNext()
        player.play(connection: candidate.connection, entry: candidate.entry)
    }

    private func cancelNext() {
        nextTask?.cancel()
        nextTask = nil
        withAnimation(.appQuick) { nextCandidate = nil }
    }

    // MARK: - 中央状态层

    @ViewBuilder
    private var centerOverlay: some View {
        switch core.state {
        case .loading, .buffering:
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(1.5)
        case .paused where showControls:
            Button {
                core.play()
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.pressScale)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.8))
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        case .idle:
            if let error = player.lastError {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 32)
            }
        default:
            EmptyView()
        }
    }

    // MARK: - 控制层自动隐藏

    private func toggleControls() {
        withAnimation(.appQuick) { showControls.toggle() }
        if showControls {
            resetHideTimer()
        } else {
            hideTask?.cancel()
        }
    }

    private func lockInterface() {
        hideTask?.cancel()
        withAnimation(.appQuick) {
            isInterfaceLocked = true
            showControls = false
        }
    }

    private func unlockInterface() {
        withAnimation(.appQuick) { isInterfaceLocked = false }
        resetHideTimer()
    }

    private func resetHideTimer() {
        hideTask?.cancel()
        if !showControls {
            withAnimation(.appQuick) { showControls = true }
        }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, core.isPlaying else { return }
            withAnimation(.appQuick) { showControls = false }
        }
    }
}
