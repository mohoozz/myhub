import Foundation
import CoreText
import UIKit

/// 排版结果：整章 attributed 文本 + 行边界分页 + 块位置映射（锚点换算）
struct ChapterPagination {
    /// 页内行映射：把「页内纵向偏移」换算成字符位置（滚动模式连续上报，消除页块离散化）
    /// - `tops`：各行距本页页顶的纵向位置（首行归一化为 0，仅由相邻行间距累加得到，
    ///   规避 CoreText 行 origin 坐标系的上下方向差异）；
    /// - `starts`：各行的起始 UTF-16 字符位置（相对整章，升序）。
    struct PageLineMap {
        let tops: [CGFloat]
        let starts: [Int]
    }

    let attributedText: NSAttributedString
    /// 每页字符范围（在 attributedText 中）
    let pages: [Range<Int>]
    /// 每个 ReaderBlock 在 attributedText 中的起始字符位置（epub 段落锚点换算）
    let blockStarts: [Int]
    /// 与 `pages` 一一对应的行映射；nil = 该页无法建立可靠映射（调用方退化按比例插值）
    let pageLineMaps: [PageLineMap?]
    /// 每页预切片富文本（构建时一次性生成）。
    /// 避免 UI 每帧重建时反复 `attributedSubstring` 深拷贝（大章几百页时主线程卡顿）。
    private let pageStrings: [NSAttributedString]

    init(
        attributedText: NSAttributedString,
        pages: [Range<Int>],
        blockStarts: [Int],
        pageLineMaps: [PageLineMap?] = []
    ) {
        self.attributedText = attributedText
        self.pages = pages
        self.blockStarts = blockStarts
        self.pageLineMaps = pageLineMaps
        self.pageStrings = pages.map {
            attributedText.attributedSubstring(
                from: NSRange(location: $0.lowerBound, length: $0.count)
            )
        }
    }

    /// 指定页的富文本（O(1)，预切片缓存）
    func pageContent(_ index: Int) -> NSAttributedString {
        guard pageStrings.indices.contains(index) else { return NSAttributedString() }
        return pageStrings[index]
    }

    /// 字符位置 → 页下标（最后一个 start <= pos 的页）
    func pageIndex(forCharOffset offset: Int) -> Int {
        var result = 0
        for (index, page) in pages.enumerated() where page.lowerBound <= offset {
            result = index
        }
        return min(result, max(pages.count - 1, 0))
    }

    /// 字符位置 → (段落序号, 段内字符偏移)：最后一个 blockStart <= pos 的文本块
    func paragraphAnchor(forCharOffset offset: Int, blocks: [ReaderBlock]) -> (paragraph: Int, offsetInParagraph: Int) {
        var textBlockOrdinal = -1
        var anchor = (paragraph: 0, offsetInParagraph: 0)
        for (index, block) in blocks.enumerated() {
            guard case .text = block else { continue }
            textBlockOrdinal += 1
            if blockStarts[index] <= offset {
                anchor = (textBlockOrdinal, offset - blockStarts[index])
            } else {
                break
            }
        }
        return anchor
    }

    /// (段落序号, 段内偏移) → attributedText 字符位置
    func charOffset(forParagraph paragraph: Int, offsetInParagraph: Int, blocks: [ReaderBlock]) -> Int {
        var textBlockOrdinal = -1
        for (index, block) in blocks.enumerated() {
            guard case .text = block else { continue }
            textBlockOrdinal += 1
            if textBlockOrdinal == paragraph {
                return blockStarts[index] + offsetInParagraph
            }
        }
        return 0
    }

    // MARK: - 滚动模式：页内纵向偏移 → 连续字符位置

    /// 页内纵向偏移（点）→ 该处对应的 UTF-16 字符位置。
    /// 滚动模式用它上报「可见顶部的连续字符位置」，取代“当前页页首”这种页块粒度的离散值：
    /// - 有行映射：取「页顶之下最后一行」的行首（行级精度，典型误差 ≈ 一行 ≈ 40 字）；
    /// - 无行映射（坐标异常/单行页）：按页高比例线性插值兜底，误差不超过一页。
    /// 行映射异常时**绝不返回错位值**，只会退化为插值。
    /// - Parameter pageHeight: 页面内容区实际高度（无行映射时插值的分母，传页块渲染高度）
    func charOffset(inPage index: Int, offsetY: CGFloat, pageHeight: CGFloat) -> Int {
        guard pages.indices.contains(index) else { return 0 }
        let page = pages[index]
        let clampedMax = max(page.upperBound - 1, page.lowerBound)
        let offset = max(0, offsetY)
        if pageLineMaps.indices.contains(index), let map = pageLineMaps[index], !map.starts.isEmpty {
            var result = page.lowerBound
            for (line, top) in map.tops.enumerated() where top <= offset {
                result = map.starts[line]
            }
            return min(max(result, page.lowerBound), clampedMax)
        }
        guard pageHeight > 1 else { return page.lowerBound }
        let ratio = min(max(offset / pageHeight, 0), 1)
        let delta = Int((CGFloat(page.count) * ratio).rounded(.down))
        return min(max(page.lowerBound + delta, page.lowerBound), clampedMax)
    }

    // MARK: - 片段重定位（锚点核心：按内容找回位置，与字节/编码无关）

    /// 取锚点位置的后续纯文本片段（写入进度；下次恢复时按内容搜索重定位）
    /// 返回原文不做裁剪，保证搜索命中位置与锚点位置严格对齐
    func locatorSnippet(from charOffset: Int, maxLength: Int = 48) -> String? {
        let length = attributedText.length
        guard length > 0 else { return nil }
        let start = min(max(charOffset, 0), length - 1)
        let end = min(start + maxLength, length)
        let raw = (attributedText.string as NSString)
            .substring(with: NSRange(location: start, length: end - start))
        // 全空白片段无定位价值（页首恰在段间分隔符上）
        guard raw.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4 else { return nil }
        return raw
    }

    /// 片段搜索重定位：返回片段的 UTF-16 字符位置。
    /// - 片段被轻微编辑过也能命中：从左侧逐步截短（drop 8/16/24 字符）后重试，命中后补偿回真实起点；
    /// - 多处命中时取最接近 hint 的一处（hint 来自段号/章内偏移，仅用于消歧与提速）
    func charOffset(forLocatorFragment fragment: String, hint: Int) -> Int? {
        let ns = attributedText.string as NSString
        guard ns.length > 0, !fragment.isEmpty else { return nil }
        let fragmentNS = fragment as NSString
        for drop in [0, 8, 16, 24] where drop < fragmentNS.length {
            let needle = fragmentNS.substring(from: drop)
            guard needle.count >= 4 else { break }
            var matches: [Int] = []
            var searchStart = 0
            // 命中上限 32：长章里重复的短句仍可收敛，避免极端文本退化为全章扫描
            while matches.count < 32, searchStart < ns.length {
                let found = ns.range(
                    of: needle, options: [.literal],
                    range: NSRange(location: searchStart, length: ns.length - searchStart)
                )
                guard found.location != NSNotFound else { break }
                matches.append(found.location - drop)
                searchStart = found.location + max(found.length, 1)
            }
            if !matches.isEmpty {
                return matches.min { abs($0 - hint) < abs($1 - hint) }
            }
        }
        return nil
    }
}

/// 文本分页器（`TextPainter` 行边界分页，TODO §5）：
/// 把章节内容块组装为 NSAttributedString（标题放大加粗、插图 NSTextAttachment 等比嵌入），
/// 用 CTFramesetter 一次性排版，逐行 CTLineGetStringRange 按行 origin 切页，**不截断行**。
enum TextPaginator {

    static func paginate(
        blocks: [ReaderBlock],
        appearance: ReaderAppearance,
        pageSize: CGSize,
        textColor: UIColor
    ) -> ChapterPagination {
        let (attributed, blockStarts) = assemble(
            blocks: blocks, appearance: appearance, pageSize: pageSize, textColor: textColor
        )
        let (pages, lineMaps) = splitPages(attributed: attributed, pageSize: pageSize)
        // blockStarts 正常应与 blocks 等长；不等长时锚点换算 blockStarts[index] 会越界闪退，先留痕
        if blockStarts.count != blocks.count {
            AppLogger.shared.log(
                "TextPaginator: blockStarts(\(blockStarts.count)) ≠ blocks(\(blocks.count))，锚点换算存在越界风险",
                level: .warn, module: "novel-reader"
            )
        }
        return ChapterPagination(
            attributedText: attributed, pages: pages, blockStarts: blockStarts, pageLineMaps: lineMaps
        )
    }

    // MARK: - 组装

    private static func assemble(
        blocks: [ReaderBlock],
        appearance: ReaderAppearance,
        pageSize: CGSize,
        textColor: UIColor
    ) -> (NSAttributedString, [Int]) {
        let result = NSMutableAttributedString()
        var blockStarts: [Int] = []
        let separator = "\n"

        for block in blocks {
            if result.length > 0 {
                result.append(NSAttributedString(string: separator, attributes: [
                    .font: appearance.bodyFont(),
                    .paragraphStyle: appearance.paragraphStyle,
                ]))
            }
            blockStarts.append(result.length)
            switch block {
            case .text(let text, let heading):
                result.append(NSAttributedString(string: text, attributes: [
                    .font: appearance.bodyFont(heading: heading),
                    .foregroundColor: textColor,
                    .paragraphStyle: appearance.paragraphStyle,
                ]))
            case .image(_, let data):
                if let data, let image = UIImage(data: data) {
                    result.append(NSAttributedString(attachment: attachment(
                        image: image, pageWidth: pageSize.width
                    )))
                } else {
                    result.append(NSAttributedString(string: "［图片加载失败］", attributes: [
                        .font: appearance.bodyFont(),
                        .foregroundColor: UIColor.gray,
                        .paragraphStyle: appearance.paragraphStyle,
                    ]))
                }
            }
        }
        if result.length == 0 {
            blockStarts = [0]
            result.append(NSAttributedString(string: "（本章无内容）", attributes: [
                .font: appearance.bodyFont(),
                .foregroundColor: textColor,
                .paragraphStyle: appearance.paragraphStyle,
            ]))
        }
        return (result, blockStarts)
    }

    /// 插图附件：等比缩放到页宽以内、高度不超过 65% 屏高
    private static func attachment(image: UIImage, pageWidth: CGFloat) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        attachment.image = image
        let maxWidth = max(pageWidth - 48, 120)
        let maxHeight = UIScreen.main.bounds.height * 0.65
        let scale = min(maxWidth / image.size.width, maxHeight / image.size.height, 1)
        attachment.bounds = CGRect(
            x: 0, y: 0,
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        return attachment
    }

    // MARK: - 行边界分页

    private static func splitPages(
        attributed: NSAttributedString, pageSize: CGSize
    ) -> (pages: [Range<Int>], lineMaps: [ChapterPagination.PageLineMap?]) {
        guard attributed.length > 0, pageSize.width > 20, pageSize.height > 20 else {
            return ([0..<attributed.length], [nil])
        }
        // 逐屏排版：CTFramesetterCreateFrame 传入 length=0 表示“从 currentIndex 起排满 path 为止”，
        // CTFrameGetVisibleStringRange 返回本屏完整可见（不截断行）的字符范围，游标推进到下一页起点。
        // 参照 Legado（gedoor/legado）PageSplitter 的分页算法，避免单帧取行导致整章只出 1 页。
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var pages: [Range<Int>] = []
        var lineMaps: [ChapterPagination.PageLineMap?] = []
        var currentIndex = 0
        let totalLength = attributed.length
        while currentIndex < totalLength {
            let path = CGPath(rect: CGRect(origin: .zero, size: pageSize), transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: currentIndex, length: 0),
                path,
                nil
            )
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break }
            let pageEnd = currentIndex + visible.length
            pages.append(currentIndex..<pageEnd)
            lineMaps.append(lineMap(frame: frame, pageStart: currentIndex, pageEnd: pageEnd))
            currentIndex = pageEnd
        }
        guard !pages.isEmpty else { return ([0..<attributed.length], [nil]) }
        return (pages, lineMaps)
    }

    /// 页内行映射构建（滚动模式连续上报的基础）：
    /// - 行纵向位置只取**相邻行距的累加值**（首行归一化为 0）：CoreText 行 origin 的 y 方向
    ///   在不同上下文可能自上或自下，差值法与该方向无关，避免整表上下颠倒导致位置错乱；
    /// - 行字符范围基准（整串 / 当前帧起点）按首行位置自动判定；
    /// - 任一校验不通过返回 nil：调用方退化为按比例插值，**绝不返回错位值**。
    private static func lineMap(
        frame: CTFrame, pageStart: Int, pageEnd: Int
    ) -> ChapterPagination.PageLineMap? {
        guard let lines = CTFrameGetLines(frame) as? [CTLine], lines.count >= 2, pageEnd > pageStart else {
            return nil
        }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        // 首行 location == 0 且本页不从 0 开始 ⇒ 行 range 相对本帧起点
        let base = CTLineGetStringRange(lines[0]).location == 0 && pageStart != 0 ? pageStart : 0
        var tops: [CGFloat] = []
        var starts: [Int] = []
        var top: CGFloat = 0
        for (index, line) in lines.enumerated() {
            let start = base + CTLineGetStringRange(line).location
            guard start >= pageStart, start < pageEnd else { return nil }
            if index > 0 { top += abs(origins[index].y - origins[index - 1].y) }
            tops.append(top)
            starts.append(start)
        }
        guard top > 0 else { return nil }
        for index in 1..<starts.count {
            guard starts[index] > starts[index - 1], tops[index] >= tops[index - 1] else { return nil }
        }
        return ChapterPagination.PageLineMap(tops: tops, starts: starts)
    }
}
