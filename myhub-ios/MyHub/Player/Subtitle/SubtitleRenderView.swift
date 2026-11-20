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
    /// 追赶修正（-0.25…0.25）：校准时只微调推进速率、不改位置，滚动弹幕才不会一跳一跳
    private var clockRateCorrection: Double = 0

    private struct CachedText {
        /// 已经按字号/描边预渲染好的位图（含描边留白）
        let image: UIImage
        /// 文字块尺寸（点，不含留白），用于对齐定位
        let textSize: CGSize
        /// 位图四周的留白（描边/阴影外扩）
        let padding: CGFloat
    }
    private struct TextKey: Hashable {
        let id: Int
        let fontBucket: Int      // 字号 ×2，避免浮点抖动造成缓存失效
        let outlineBucket: Int   // 描边 ×10
        let shadowBucket: Int    // 阴影 ×10
    }
    private var textCache: [TextKey: CachedText] = [:]
    /// 当前帧在屏 cue 的 id（缓存溢出时只保留这些，避免整片清空导致下一帧集中重绘）
    private var visibleCueIDs: Set<Int> = []
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
        // 位图尺寸只与字号/描边有关（点为单位），布局变化不必丢弃缓存
        setNeedsDisplay()
    }

    // MARK: - 时钟

    private func syncClock(to time: TimeInterval) {
        let target = time - subtitleDelay
        let predicted = currentTime()
        let delta = target - predicted
        if !clockPlaying || abs(delta) > 0.6 {
            // 暂停 / seek / 大跳变：直接对齐
            clockBase = target
            clockRateCorrection = 0
        } else {
            // 正常播放：位置保持连续，只把误差摊进推进速率（±25%）慢慢追平。
            // 以前直接改位置，4Hz 校准一次就跳一下——滚动弹幕看起来一卡一卡的。
            clockBase = predicted
            clockRateCorrection = abs(delta) < 0.02 ? 0 : max(-0.2, min(0.2, delta * 2.5))
        }
        clockAnchor = CACurrentMediaTime()
        if !timelineHasAnimation { setNeedsDisplay() }
    }

    private func currentTime() -> TimeInterval {
        guard clockPlaying else { return clockBase }
        let elapsed = CACurrentMediaTime() - clockAnchor
        let rate = Double(max(0.1, playbackRate)) * (1 + clockRateCorrection)
        return clockBase + elapsed * rate
    }

    private func updateDisplayLink() {
        let needed = clockPlaying && timelineHasAnimation && window != nil
        if needed {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: linkProxy, selector: #selector(SubtitleDisplayLinkProxy.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 60, preferred: 60)
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
        visibleCueIDs = Set(active.map(\.id))
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
        let rawOutline = metrics.isAss
            ? cue.style.outlineWidth * metrics.fontScale
            : max(1.2, simpleFontSize * 0.09)
        // ASS 的 Outline 是 PlayRes 单位，弹幕/字幕文件里常出现「小字号配大描边」（如 25 号字配 2 描边）。
        // 描边由 renderedImage 以「外描边」方式绘制（不会吃掉字形填充），此处仅做异常值限幅。
        let outlineWidth = metrics.isAss ? min(rawOutline, fontSize * 0.12) : rawOutline
        let shadowOffset = metrics.isAss ? cue.style.shadow * metrics.fontScale : 0
        let cached = renderedImage(
            for: cue,
            fontSize: fontSize,
            outlineWidth: outlineWidth,
            shadowOffset: shadowOffset
        )
        let anchor = anchorPoint(for: cue, at: time, videoRect: videoRect, metrics: metrics)
        let origin = blockOrigin(blockSize: cached.textSize, anchor: anchor, alignment: cue.style.alignment)
        cached.image.draw(at: CGPoint(x: origin.x - cached.padding, y: origin.y - cached.padding))
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

    /// 把一条字幕预渲染成位图（按文字 + 样式缓存）。
    /// 描边分两遍画：先画「空心描边」打底，再用纯填充盖住描边内半圈 —— 等效于 libass 的外描边。
    /// 之前用负值 strokeWidth 一遍画完，CoreText 的描边是**居中**的，会吃掉字形填充；
    /// 弹幕这种「25 号字 + 2 描边」的小字场景下白字会被黑色描边糊成深色一团。
    private func renderedImage(
        for cue: SubtitleCue,
        fontSize: CGFloat,
        outlineWidth: CGFloat,
        shadowOffset: CGFloat
    ) -> CachedText {
        let key = TextKey(
            id: cue.id,
            fontBucket: Int(fontSize * 2),
            outlineBucket: Int(outlineWidth * 10),
            shadowBucket: Int(shadowOffset * 10)
        )
        if let cached = textCache[key] { return cached }

        let style = cue.style
        let font = resolveFont(name: style.fontName, size: fontSize, bold: style.bold, italic: style.italic)
        let paragraph = NSMutableParagraphStyle()
        switch (style.alignment - 1) % 3 {
        case 0: paragraph.alignment = .left
        case 2: paragraph.alignment = .right
        default: paragraph.alignment = .center
        }

        let fillAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: readableFill(for: style),
            .paragraphStyle: paragraph
        ]
        let fillText = NSAttributedString(string: cue.text, attributes: fillAttributes)
        let measured = fillText.boundingRect(
            with: CGSize(width: 10000, height: 10000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).size
        guard measured.width > 0.5, measured.height > 0.5 else {
            let empty = CachedText(image: UIImage(), textSize: .zero, padding: 0)
            textCache[key] = empty
            return empty
        }

        // 位图四周留出描边/阴影外扩的空间，避免被裁掉
        let padding = ceil(outlineWidth + shadowOffset) + 1
        let canvas = CGSize(
            width: ceil(measured.width) + padding * 2,
            height: ceil(measured.height) + padding * 2
        )
        let drawRect = CGRect(x: padding, y: padding, width: measured.width, height: measured.height)

        let renderer = UIGraphicsImageRenderer(size: canvas)
        let image = renderer.image { _ in
            if shadowOffset > 0.01 {
                let shadow = NSShadow()
                shadow.shadowColor = UIColor.black.withAlphaComponent(0.8)
                shadow.shadowOffset = CGSize(width: shadowOffset, height: shadowOffset)
                shadow.shadowBlurRadius = 0
                var attributes = fillAttributes
                attributes[.shadow] = shadow
                NSAttributedString(string: cue.text, attributes: attributes).draw(in: drawRect)
            }
            if outlineWidth > 0.01 {
                var attributes = fillAttributes
                attributes[.foregroundColor] = style.outlineColor
                attributes[.strokeColor] = style.outlineColor
                // 正值 = 只描边、不填充；取 2 倍外扩宽度，内半圈随后被填充盖掉
                attributes[.strokeWidth] = 200 * outlineWidth / fontSize
                NSAttributedString(string: cue.text, attributes: attributes).draw(in: drawRect)
            }
            fillText.draw(in: drawRect)
        }

        let result = CachedText(image: image, textSize: measured, padding: padding)
        // 超量时只淘汰已经离屏的字幕，避免播放中突然整体清空造成集中重绘（一帧掉帧）
        if textCache.count > 400 {
            textCache = textCache.filter { visibleCueIDs.contains($0.key.id) }
        }
        textCache[key] = result
        return result
    }

    /// 填充色可读性兜底：ASS 原样照搬作者配色，但「深色填充 + 深色描边」在视频上等于没字
    /// （以前所有字幕统一白字 + 半透明黑底，所以不会出现）。仅当填充和描边都明显偏深时才提亮为白色；
    /// 「黑字 + 白描边」这类刻意配色（描边是浅色）保持原样。
    private func readableFill(for style: SubtitleStyleSpec) -> UIColor {
        guard styleFillAndOutlineBothDark(style) else { return style.primaryColor }
        return .white
    }

    private func styleFillAndOutlineBothDark(_ style: SubtitleStyleSpec) -> Bool {
        relativeLuminance(of: style.primaryColor) < 0.25 && relativeLuminance(of: style.outlineColor) < 0.25
    }

    /// 0（黑）~1（白）；解析不了（含动态色）时按浅色处理，避免误改
    private func relativeLuminance(of color: UIColor) -> CGFloat {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return 1 }
        guard a > 0.35 else { return 1 }   // 本身就是半透明/几乎不可见，不当作深色
        return 0.299 * r + 0.587 * g + 0.114 * b
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

