import SwiftUI
import UIKit

/// 内置浏览器沉浸态左下角悬浮控件
/// （原型 `prototype/browser-exit-handle-collapse-options.html` 确认组合：
/// 形态 **C**「悬浮圆钮 + 播放微件」· 策略 **S1**「进入浏览器页签即隐藏页签栏与 mini 播放器」·
/// 图标 **E9-b** `arrow.uturn.down` · 收缩 **R1**「整体半隐贴边」· 触发 **T1**「跟随操作栏联动」·
/// 点击 **K1**「收缩态一点即退」）。
///
/// 两种形态：
/// - 无播放会话：单颗 38pt 圆钮（仅退出键）；
/// - 有 mini 播放会话：竖向双联胶囊（上格播放微件 / 下格退出键）。沉浸态下全局 mini 播放器被一并隐藏，
///   上格是沉浸期间**唯一**的播放控制入口（点击暂停/继续、长按展开回全屏播放器）。
///
/// 两种状态（R1）：展开态距屏幕左缘 `leadingInset`；收缩态整体左移、屏内仅留 `collapsedReveal` 宽的一道圆弧
/// 并降至半透明，左侧圆角被屏幕边缘自然裁切，形成贴边半胶囊。
///
/// 图标取 `arrow.uturn.down`（掉头箭头朝下，指向底栏将要出现的位置）而非 `arrow.uturn.left`：
/// 后者与操作栏左侧的网页后退键 `chevron.left` 同为「水平向左的返回」，同屏易混淆；朝下即错开方向维度。
/// 再叠一道区分：本控件图标上主题蓝，操作栏导航键为黑灰单色。
struct BrowserExitHandle: View {
    /// 是否收缩为贴边半隐态：与底部操作栏的 `toolbarMini` 同源联动（T1，滚动页面即一起收起）
    let collapsed: Bool
    /// 退出沉浸态（回到进入浏览器前的页签，页签栏与 mini 播放器随之恢复）
    let onExit: () -> Void

    @EnvironmentObject private var player: PlayerPresenter
    @ObservedObject private var core = PlayerCore.shared

    /// 音频内嵌 / 同目录封面（经 `CoverService` 加载，与 mini 播放器 / 锁屏同源缓存，缺失时回落图标占位）
    @State private var audioCover: UIImage?
    /// 首启一次性提示气泡（「退出全屏」，2s 后淡出；标记存 `AppSettings.Browser.exitHandleTipShown`）
    @State private var showTip = false

    /// 圆钮直径 = 单格高度（双联时总高 2×38 + 1pt 分隔）
    private let diameter: CGFloat = 38
    /// 展开态距屏幕左缘：与底部操作栏胶囊的左右内缩 12pt 对齐
    private let leadingInset: CGFloat = 12
    /// 收缩态屏内露出宽度（R1）
    private let collapsedReveal: CGFloat = 14
    /// 收缩态命中区外扩量：露出仅 14pt，不外扩难以点中（仅扩命中区，不影响布局与观感）
    private let hitExpand: CGFloat = 10

    /// 是否显示播放微件：沉浸态下全局 mini 播放器被隐藏，有会话时由本控件接管播放控制
    private var hasPlaybackWidget: Bool {
        player.isMini && player.current != nil
    }

    /// 收缩位移：使控件右缘恰停在屏内 `collapsedReveal` 处
    private var collapsedOffset: CGFloat {
        -(leadingInset + diameter - collapsedReveal)
    }

    var body: some View {
        // 气泡与底部退出格「底对齐」：HStack 底边即退出格底边，气泡在其内部垂直居中
        HStack(alignment: .bottom, spacing: 8) {
            capsuleBody
            if showTip && !collapsed {
                tipBubble
            }
        }
        .padding(.leading, leadingInset)
        .offset(x: collapsed ? collapsedOffset : 0)
        .opacity(collapsed ? 0.55 : 1)
        .animation(.appQuick, value: collapsed)
        .animation(.appQuick, value: hasPlaybackWidget)
        // 切歌 / 音视频模式切换时重新加载封面
        .task(id: coverLoadKey) { await loadAudioCover() }
        .onAppear { presentTipIfNeeded() }
    }

    // MARK: - 胶囊本体

    private var capsuleBody: some View {
        VStack(spacing: 0) {
            if hasPlaybackWidget {
                playbackCell
                Divider()
                    .overlay(AppColors.separator)
                    .frame(width: diameter)
            }
            exitCell
        }
        .frame(width: diameter)
        .background(AppColors.cardBackground)
        // 圆角取半宽：单钮时为正圆，双联时为上下半圆的竖向胶囊
        .clipShape(RoundedRectangle(cornerRadius: diameter / 2, style: .continuous))
        // 1pt 极浅描边 + 轻阴影：与悬浮页签栏 / mini 播放器 / 操作栏胶囊统一为 `cardBorder`
        .overlay {
            RoundedRectangle(cornerRadius: diameter / 2, style: .continuous)
                .stroke(AppColors.cardBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
    }

    /// 退出格：点一下即退出沉浸态（K1，收缩态无需先展开）
    private var exitCell: some View {
        Button(action: handleExit) {
            Image(systemName: "arrow.uturn.down")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AppColors.primary)
                .frame(width: diameter, height: diameter)
                .contentShape(hitShape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("退出全屏浏览，显示页签栏")
    }

    /// 播放微件格：点击暂停 / 继续。
    ///
    /// 封面只取静态图（音频走 `CoverService`，视频回落图标）而非实时画面：
    /// 38pt 下实时预览无意义，且会与全局 mini 播放器来回争夺 `videoOutput` 的渲染宿主。
    ///
    /// 不叠加「长按展开全屏播放器」：`Button` 与长按手势共存会双触发（项目为此在
    /// `PopupMenu` 另造了 `PressBridge` 做 `require(toFail:)` 互斥），而 38pt 小格上
    /// 的长按属次要路径——需要全屏播放器时先点退出钮回到原页签，mini 播放器即恢复可点。
    private var playbackCell: some View {
        Button {
            core.togglePlayPause()
        } label: {
            ZStack {
                coverBackground
                // 有封面图时叠暗色遮罩，保证白色播放图标可读；图标占位底色本就浅，无需遮罩
                if audioCover != nil {
                    Color.black.opacity(0.30)
                }
                playbackSymbol
            }
            .frame(width: diameter, height: diameter)
            .clipped()
            .contentShape(hitShape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(core.isPlaying ? "暂停" : "继续播放")
    }

    @ViewBuilder
    private var playbackSymbol: some View {
        if core.isSeeking || core.state == .loading || core.state == .buffering {
            ProgressView()
                .controlSize(.mini)
                .tint(symbolColor)
        } else {
            Image(systemName: core.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(symbolColor)
        }
    }

    /// 播放图标色：压在封面暗色遮罩上用白色，图标占位浅底上用主题蓝
    private var symbolColor: Color {
        audioCover != nil ? Color.white : AppColors.primary
    }

    @ViewBuilder
    private var coverBackground: some View {
        if let audioCover {
            Image(uiImage: audioCover)
                .resizable()
                .scaledToFill()
        } else {
            AppColors.primary.opacity(0.12)
        }
    }

    /// 首启提示气泡：仅第一次进入沉浸态时出现 2s，缓解贴边半隐控件的发现性问题
    private var tipBubble: some View {
        Text("退出全屏")
            .font(.caption2.weight(.medium))
            .foregroundStyle(AppColors.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(AppColors.cardBackground))
            .overlay(Capsule().stroke(AppColors.cardBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
            // 撑到与退出格同高并底对齐 → 气泡中心与退出格中心齐平
            .frame(height: diameter)
            .transition(.opacity.combined(with: .move(edge: .leading)))
            .allowsHitTesting(false)
    }

    // MARK: - 命中区

    /// 命中形状：收缩态仅**向右**外扩 `hitExpand`，补偿仅 `collapsedReveal` 的屏内露出宽度。
    /// 刻意不作四周等距外扩——双联形态下上下外扩会让两格命中区相互重叠（点播放格下缘会误触退出）；
    /// 也不宜扩得过宽，本控件浮在 `WKWebView` 之上，扩出的区域会吃掉该范围内的网页点击。
    private var hitShape: TrailingExpandedRect {
        TrailingExpandedRect(expand: collapsed ? hitExpand : 0)
    }

    // MARK: - 行为

    private func handleExit() {
        // prepare 预唤醒触觉引擎，确保即时可靠触发（与播放页长按锁定、弹出菜单长按一致）
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
        onExit()
    }

    private func presentTipIfNeeded() {
        guard !AppSettings.Browser.exitHandleTipShown else { return }
        AppSettings.Browser.exitHandleTipShown = true
        withAnimation(.appQuick) { showTip = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.appQuick) { showTip = false }
        }
    }

    // MARK: - 封面

    /// 音频模式（含用户强制仅音频）→ 取内嵌/同目录封面；视频模式保持图标占位
    private var isAudio: Bool {
        core.isAudioOnly || player.current?.isAudioOnly == true
    }

    /// 封面加载键：随播放路径或音/视频模式变化而变化，触发重新加载
    private var coverLoadKey: String {
        "\(player.current?.path ?? "")|\(isAudio)"
    }

    private func loadAudioCover() async {
        audioCover = nil   // 切歌先清空，避免残留上一首封面
        guard hasPlaybackWidget, isAudio, let item = player.current else { return }
        let result = await CoverService.shared.cover(forItem: item)
        // 加载期间可能已切歌，回填前确认仍是当前条目
        guard player.current?.path == item.path, let image = result.image else { return }
        audioCover = image
    }
}

/// 仅向右加宽的矩形命中形状：用于贴边半隐控件在不改变布局与观感的前提下扩大可点范围
private struct TrailingExpandedRect: Shape {
    let expand: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width + expand, height: rect.height))
    }
}
