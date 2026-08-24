import Foundation
import CoreText
import UIKit

/// 排版结果：整章 attributed 文本 + 行边界分页 + 块位置映射（锚点换算）
struct ChapterPagination {
    let attributedText: NSAttributedString
    /// 每页字符范围（在 attributedText 中）
    let pages: [Range<Int>]
    /// 每个 ReaderBlock 在 attributedText 中的起始字符位置（epub 段落锚点换算）
    let blockStarts: [Int]

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
        let pages = splitPages(attributed: attributed, pageSize: pageSize)
        return ChapterPagination(attributedText: attributed, pages: pages, blockStarts: blockStarts)
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

    private static func splitPages(attributed: NSAttributedString, pageSize: CGSize) -> [Range<Int>] {
        guard attributed.length > 0, pageSize.width > 20, pageSize.height > 20 else {
            return [0..<attributed.length]
        }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(origin: .zero, size: pageSize), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil)
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else {
            return [0..<attributed.length]
        }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        var pages: [Range<Int>] = []
        var pageStart = 0
        var pageTopY = origins[0].y
        for (index, line) in lines.enumerated() {
            let range = CTLineGetStringRange(line)
            // CoreText 坐标自下而上：origin.y 越小越靠下；行超出页底则切页
            let lineBottom = origins[index].y
            if pageTopY - lineBottom > pageSize.height + 1, range.location > pageStart {
                pages.append(pageStart..<range.location)
                pageStart = range.location
                pageTopY = origins[index].y
            }
        }
        if pageStart < attributed.length {
            pages.append(pageStart..<attributed.length)
        }
        return pages.isEmpty ? [0..<attributed.length] : pages
    }
}
