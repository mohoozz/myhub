import SwiftUI
import UIKit

/// 字幕渲染层（外挂 SRT / ASS 通用）：
/// - 按 ASS `PlayRes` 映射到**视频实际显示区域**（letterbox 内），竖屏/横屏都贴画面底部；
/// - 支持 `\an` 对齐、`\pos` 定位、`\move` 滚动弹幕、`\c` 颜色、`\bord` 描边，可同时叠加多条；
/// - 纯文字 + 描边，无背景色块；位置固定，不随控制栏显隐上下移动。
final class SubtitleRenderView: UIView {
    var timeline: SubtitleTimeline = .empty {
        didSet {
            cueStarts = timeline.cues.map { $0.start }
            timelineHasAnimation = timeline.hasAnimation
            textCache.removeAll()
            updateDisplayLink()
            setNeedsDisplay()
        }
    }

    /// 视频画面尺寸（像素）；.zero = 未知，按整个视图区域对齐
    var videoSize: CGSize = .zero {
        didSet { if videoSize != oldValue { setNeedsDisplay() } }
    }

    /// 播放器设置的字幕字号（仅 SRT 这类无样式的字幕使用）
    var simpleFontSize: CGFloat = 16 {
        didSet {
            guard simpleFontSize != oldValue else { return }
            textCache.removeAll()
            setNeedsDisplay()
        }
    }

    var isPlaying: Bool = false {
        didSet {
            guard isPlaying != oldValue else { return }
            clockPlaying = isPlaying
            clockAnchor = CACurrentMediaTime()
            updateDisplayLink()
            setNeedsDisplay()
        }
    }

    var playbackRate: Float = 1

    /// 字幕延迟（秒，正数 = 字幕延后显示）
    var subtitleDelay: TimeInterval = 0 {
        didSet {
            guard subtitleDelay != oldValue else { return }
            syncClock(to: playerTime)
        }
    }

    /// 播放器时间（PlayerCore 4Hz 回调），内部本地时钟平滑插值
    var playerTime: TimeInterval = 0 {
        didSet { syncClock(to: playerTime) }
    }

    // MARK: - 内部状态

    private var cueStarts: [TimeInterval] = []
    private var timelineHasAnimation = false
    private var clockBase: TimeInterval = 0
    private var clockAnchor: CFTimeInterval = CACurrentMediaTime()
    private var clockPlaying = false

    private struct CachedText {
        let string: NSAttributedString
        let size: CGSize
    }
    private var textCache: [String: CachedText] = [:]
    private var fontCache: [String: UIFont] = [:]
    private var displayLink: CADisplayLink?
    private let linkProxy = SubtitleDisplayLinkProxy()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
        linkProxy.view = self
    }

    deinit { displayLink?.invalidate() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            displayLink?.invalidate()
            displayLink = nil
        } else {
            updateDisplayLink()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        textCache.removeAll()
        setNeedsDisplay()
    }

    // MARK: - 时钟

    private func syncClock(to time: TimeInterval) {
        let target = time - subtitleDelay
        let predicted = currentTime()
        let delta = target - predicted
        // 暂停 / seek 直接对齐；正常播放缓慢收敛，避免 4Hz 校准造成抖动
        if !clockPlaying || abs(delta) > 0.5 || abs(delta) < 0.001 {
            clockBase = target
        } else {
            clockBase = predicted + delta * 0.35
        }
        clockAnchor = CACurrentMediaTime()
        if !timelineHasAnimation { setNeedsDisplay() }
    }

    private func currentTime() -> TimeInterval {
        guard clockPlaying else { return clockBase }
        let elapsed = CACurrentMediaTime() - clockAnchor
        return clockBase + elapsed * Double(max(0.1, playbackRate))
    }

    private func updateDisplayLink() {
        let needed = clockPlaying && timelineHasAnimation && window != nil
        if needed {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: linkProxy, selector: #selector(SubtitleDisplayLinkProxy.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if let link = displayLink {
            link.invalidate()
            displayLink = nil
        }
    }

    fileprivate func tick() { setNeedsDisplay() }

    // MARK: - 绘制

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.clear(rect)   // 透明背景：字幕不铺底色
        let videoRect = resolvedVideoRect()
        let time = currentTime()
        let active = activeCues(at: time)
        guard !active.isEmpty else { return }
        let metrics = resolveMetrics(videoRect: videoRect)
        for cue in active {
            draw(cue, at: time, videoRect: videoRect, metrics: metrics)
        }
    }

    /// 视频实际显示区域（与 AVPlayerLayer `.resizeAspect` / VLC 等比缩放一致）
    private func resolvedVideoRect() -> CGRect {
        let area = bounds
        guard area.width > 1, area.height > 1,
              videoSize.width > 1, videoSize.height > 1 else { return area }
        let scale = min(area.width / videoSize.width, area.height / videoSize.height)
        let fitted = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(
            x: area.midX - fitted.width / 2,
            y: area.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    private struct Metrics {
        let scaleX: CGFloat
        let scaleY: CGFloat
        let fontScale: CGFloat
        let isAss: Bool
    }

    private func resolveMetrics(videoRect: CGRect) -> Metrics {
        guard timeline.isASS, videoRect.width > 1, videoRect.height > 1 else {
            return Metrics(scaleX: 1, scaleY: 1, fontScale: 1, isAss: false)
        }
        // 缺 PlayRes 的 ASS 按 1080p 画布兜底，避免坐标被当成视图点导致跑到画面外
        var script = timeline.scriptSize ?? CGSize(width: 1920, height: 1080)
        if script.width < 1 || script.height < 1 { script = CGSize(width: 1920, height: 1080) }
        let scaleX = videoRect.width / script.width
        let scaleY = videoRect.height / script.height
        return Metrics(scaleX: scaleX, scaleY: scaleY, fontScale: scaleY, isAss: true)
    }

    /// 当前时刻可见 cue（按 layer 由下到上）
    private func activeCues(at time: TimeInterval) -> [SubtitleCue] {
        let cues = timeline.cues
        guard !cues.isEmpty, !cueStarts.isEmpty else { return [] }
        var low = 0
        var high = cueStarts.count - 1
        var last = -1
        while low <= high {
            let mid = (low + high) / 2
            if cueStarts[mid] <= time {
                last = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard last >= 0 else { return [] }
        var result: [SubtitleCue] = []
        var index = last
        var scanned = 0
        // 回扫到起点早于 90s 的 cue 为止（弹幕时长短，回扫量可控），并设硬上限兜底
        while index >= 0, scanned < 3000 {
            let cue = cues[index]
            if time >= cue.start, time <= cue.end {
                result.append(cue)
            } else if time - cue.start > 90 {
                break
            }
            index -= 1
            scanned += 1
        }
        let sorted = result.sorted { $0.layer < $1.layer }
        // 极端密集的弹幕兜底：单帧最多绘制 120 条（保留上层）
        return sorted.count > 120 ? Array(sorted.suffix(120)) : sorted
    }

    // MARK: - 单条绘制

    private func draw(_ cue: SubtitleCue, at time: TimeInterval, videoRect: CGRect, metrics: Metrics) {
        let rawSize = metrics.isAss ? cue.style.fontSize * metrics.fontScale : simpleFontSize
        guard rawSize > 1, rawSize.isFinite else { return }
        // 异常 `\fs` 兜底：字号不超过画面高度
        let fontSize = min(rawSize, max(24, bounds.height))
        // 描边/阴影宽度是 PlayRes 单位，需与字号同步缩放；简单字幕给一层细描边保证可读性
        let outlineWidth = metrics.isAss
            ? cue.style.outlineWidth * metrics.fontScale
            : max(1.2, simpleFontSize * 0.09)
        let shadowOffset = metrics.isAss ? cue.style.shadow * metrics.fontScale : 0
        let cached = attributedText(
            for: cue,
            fontSize: fontSize,
            outlineWidth: outlineWidth,
            shadowOffset: shadowOffset
        )
        let anchor = anchorPoint(for: cue, at: time, videoRect: videoRect, metrics: metrics)
        let origin = blockOrigin(blockSize: cached.size, anchor: anchor, alignment: cue.style.alignment)
        cached.string.draw(in: CGRect(
            origin: origin,
            size: CGSize(width: cached.size.width + 2, height: cached.size.height + 2)
        ))
    }

    /// 锚点（视图坐标）
    private func anchorPoint(
        for cue: SubtitleCue,
        at time: TimeInterval,
        videoRect: CGRect,
        metrics: Metrics
    ) -> CGPoint {
        if let move = cue.move {
            let startAt = cue.start + move.startOffset
            let endAt = cue.start + move.endOffset
            var point = move.from
            if time <= startAt {
                point = move.from
            } else if time >= endAt {
                point = move.to
            } else {
                let progress = CGFloat((time - startAt) / max(0.001, endAt - startAt))
                point = CGPoint(
                    x: move.from.x + (move.to.x - move.from.x) * progress,
                    y: move.from.y + (move.to.y - move.from.y) * progress
                )
            }
            return CGPoint(
                x: videoRect.minX + point.x * metrics.scaleX,
                y: videoRect.minY + point.y * metrics.scaleY
            )
        }

        if let position = cue.position {
            return CGPoint(
                x: videoRect.minX + position.x * metrics.scaleX,
                y: videoRect.minY + position.y * metrics.scaleY
            )
        }

        let alignment = cue.style.alignment
        let horizontal = (alignment - 1) % 3   // 0 左 / 1 中 / 2 右
        let x: CGFloat
        switch horizontal {
        case 0: x = videoRect.minX + cue.style.marginL * metrics.scaleX
        case 2: x = videoRect.maxX - cue.style.marginR * metrics.scaleX
        default: x = videoRect.midX
        }

        // 简单字幕（SRT）留固定边距，避免贴住画面底边
        let marginV = metrics.isAss
            ? cue.style.marginV * metrics.scaleY
            : max(24, simpleFontSize * 1.2)
        let y: CGFloat
        if alignment <= 3 {
            y = videoRect.maxY - marginV
        } else if alignment <= 6 {
            y = videoRect.midY
        } else {
            y = videoRect.minY + marginV
        }
        return CGPoint(x: x, y: y)
    }

    /// 按 numpad 对齐把文字块放到锚点旁
    private func blockOrigin(blockSize: CGSize, anchor: CGPoint, alignment: Int) -> CGPoint {
        let horizontal = (alignment - 1) % 3
        let x: CGFloat
        switch horizontal {
        case 0: x = anchor.x
        case 1: x = anchor.x - blockSize.width / 2
        default: x = anchor.x - blockSize.width
        }
        let y: CGFloat
        if alignment <= 3 {
            y = anchor.y - blockSize.height
        } else if alignment <= 6 {
            y = anchor.y - blockSize.height / 2
        } else {
            y = anchor.y
        }
        return CGPoint(x: x, y: y)
    }

    // MARK: - 文本构建

    private func attributedText(
        for cue: SubtitleCue,
        fontSize: CGFloat,
        outlineWidth: CGFloat,
        shadowOffset: CGFloat
    ) -> CachedText {
        let key = "\(cue.id)|\(Int(fontSize * 2))|\(Int(outlineWidth * 10))|\(Int(shadowOffset * 10))"
        if let cached = textCache[key] { return cached }

        let style = cue.style
        let font = resolveFont(name: style.fontName, size: fontSize, bold: style.bold, italic: style.italic)
        let paragraph = NSMutableParagraphStyle()
        switch (style.alignment - 1) % 3 {
        case 0: paragraph.alignment = .left
        case 2: paragraph.alignment = .right
        default: paragraph.alignment = .center
        }

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style.primaryColor,
            .paragraphStyle: paragraph
        ]
        // 描边：strokeWidth 为字号百分比，负值 = 填充 + 描边（外描边宽度按一半折算）
        if outlineWidth > 0.01 {
            attributes[.strokeColor] = style.outlineColor
            attributes[.strokeWidth] = -(200 * outlineWidth / fontSize)
        }
        if shadowOffset > 0.01 {
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.8)
            shadow.shadowOffset = CGSize(width: shadowOffset, height: shadowOffset)
            shadow.shadowBlurRadius = 0
            attributes[.shadow] = shadow
        }

        let string = NSAttributedString(string: cue.text, attributes: attributes)
        let measured = string.boundingRect(
            with: CGSize(width: 10000, height: 10000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).size
        let result = CachedText(string: string, size: measured)
        if textCache.count > 800 { textCache.removeAll() }
        textCache[key] = result
        return result
    }

    private func resolveFont(name: String, size: CGFloat, bold: Bool, italic: Bool) -> UIFont {
        let key = "\(name)|\(Int(size * 2))|\(bold)|\(italic)"
        if let cached = fontCache[key] { return cached }

        var base: UIFont?
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            for candidate in fontCandidates(for: trimmed) {
                if let font = UIFont(name: candidate, size: size) {
                    base = font
                    break
                }
            }
        }
        if base == nil {
            base = UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        }
        var result = base ?? UIFont.systemFont(ofSize: size)
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let descriptor = result.fontDescriptor.withSymbolicTraits(traits) {
            result = UIFont(descriptor: descriptor, size: size)
        }
        if fontCache.count > 200 { fontCache.removeAll() }
        fontCache[key] = result
        return result
    }

    /// ASS 里常见的字体族名（微软雅黑 / 黑体 / 宋体…）在 iOS 上都不存在：
    /// 统一回落到打包的思源黑体（Noto Sans SC，已由 `SubtitleFontRegistry` 注册）与系统苹方
    private func fontCandidates(for name: String) -> [String] {
        let normalized = name.lowercased().replacingOccurrences(of: " ", with: "")
        let cjkNames = ["yahei", "msyh", "微软雅黑", "simhei", "黑体", "heiti", "song", "宋体",
                        "simsun", "pingfang", "noto", "sourcehan", "思源"]
        let cjkFallbacks = ["NotoSansSC-Regular", "Noto Sans SC", "PingFangSC-Regular"]
        if cjkNames.contains(where: { normalized.contains($0) }) {
            return cjkFallbacks + [name]
        }
        return [name] + cjkFallbacks
    }
}

/// CADisplayLink 弱引用代理（避免 target 强引用形成环）
private final class SubtitleDisplayLinkProxy {
    weak var view: SubtitleRenderView?
    @objc func tick() { view?.tick() }
}

/// SwiftUI 桥：时间轴来自 SubtitleManager，播放时间由 PlayerCore（4Hz）驱动，
/// 视图内部再用本地时钟插值到 30fps 渲染滚动弹幕
struct SubtitleOverlay: UIViewRepresentable {
    let timeline: SubtitleTimeline
    let videoSize: CGSize
    let time: TimeInterval
    let isPlaying: Bool
    let rate: Float
    let fontSize: CGFloat
    let delay: TimeInterval

    func makeUIView(context: Context) -> SubtitleRenderView {
        SubtitleRenderView(frame: .zero)
    }

    func updateUIView(_ view: SubtitleRenderView, context: Context) {
        view.videoSize = videoSize
        view.simpleFontSize = fontSize
        view.playbackRate = rate
        view.subtitleDelay = delay
        if view.timeline != timeline { view.timeline = timeline }
        view.isPlaying = isPlaying
        view.playerTime = time
    }
}

