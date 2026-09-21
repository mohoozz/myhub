import Foundation
import SwiftUI

// MARK: - 内容块（txt 段落 / epub 段落与图片的统一抽象）

/// 阅读器内容块：分页器的输入单元
enum ReaderBlock: Equatable {
    /// 文本段；heading 0 = 正文，1~3 = 标题级（字号逐级放大加粗）
    case text(String, heading: Int)
    /// 插图（epub）；data 为已解压图片（nil = 加载失败占位）
    case image(name: String, data: Data?)
}

/// 目录项（txt 章节 / epub spine 统一）
struct NovelTocEntry: Identifiable, Equatable {
    let id: Int           // 章序号（txt 章节下标 / epub spine 下标）
    let title: String
}

// MARK: - 统一进度锚点（IOS-205/206，排版无关）

/// 排版无关进度锚点（方案 C：结构锚点 + 片段重定位）：
/// - 结构锚点：章序号 + 章标题 + 段落序号 + 段内 UTF-16 偏移（与排版解耦，不依赖字节换编码）；
/// - 内容校验：锚点位置的后续文本片段（textAfter），恢复时按内容搜索重定位，
///   编码变化、字号重排、分章规则微调、文件轻微编辑都不再漂移；
/// - 兜底：全书百分比 percent；
/// - 兼容：`offset`（txt 全局字节偏移）仅为读取历史进度保留，新写入恒为 0，读取时经索引换算一次。
struct NovelAnchor: Codable {
    var kind: Kind
    /// txt 旧版字段：全局字节偏移（只读兼容，新写入恒 0）
    var offset: Int64 = 0
    /// epub：spine 序号 / 段落序号 / 段内字符偏移
    var spineIndex: Int = 0
    var paragraphIndex: Int = 0
    var characterOffset: Int = 0
    /// 结构锚点：章序号（txt 章下标 / epub spine 下标）
    var chapterIndex: Int? = nil
    /// 章标题（分章规则变化时校验章号是否仍在同一章）
    var chapterTitle: String? = nil
    /// 章内 UTF-16 字符位置：片段搜索的 hint（消歧 + 搜索失败时直接使用）
    var chapterCharOffset: Int? = nil
    /// 定位片段：锚点位置的后续纯文本（重定位的核心依据）
    var textAfter: String? = nil
    /// 全书百分比（兜底定位）
    var percent: Double? = nil
    /// 文件指纹
    var fileSize: Int64 = 0
    var modTime: TimeInterval = 0

    enum Kind: String, Codable {
        case txt, epub
    }

    /// 是否带内容/结构信息（旧版纯字节锚点为 false，需经索引换算一次）
    var hasStructure: Bool {
        chapterIndex != nil || chapterCharOffset != nil || textAfter?.isEmpty == false
    }

    /// 旧版 txt 字节偏移锚点（需要按索引换算成章内字符位置）
    var isLegacyByteOffset: Bool {
        kind == .txt && !hasStructure && offset > 0
    }

    /// txt 结构锚点
    static func txt(
        chapterIndex: Int, chapterTitle: String,
        paragraphIndex: Int, offsetInParagraph: Int,
        chapterCharOffset: Int, textAfter: String?, percent: Double,
        fileSize: Int64, modTime: Date
    ) -> NovelAnchor {
        NovelAnchor(
            kind: .txt,
            offset: 0,
            spineIndex: chapterIndex,
            paragraphIndex: paragraphIndex,
            characterOffset: offsetInParagraph,
            chapterIndex: chapterIndex,
            chapterTitle: chapterTitle,
            chapterCharOffset: chapterCharOffset,
            textAfter: textAfter,
            percent: percent,
            fileSize: fileSize,
            modTime: modTime.timeIntervalSince1970
        )
    }

    /// epub 结构锚点
    static func epub(
        spineIndex: Int, chapterTitle: String,
        paragraphIndex: Int, offsetInParagraph: Int,
        chapterCharOffset: Int, textAfter: String?, percent: Double,
        fileSize: Int64, modTime: Date
    ) -> NovelAnchor {
        NovelAnchor(
            kind: .epub,
            offset: 0,
            spineIndex: spineIndex,
            paragraphIndex: paragraphIndex,
            characterOffset: offsetInParagraph,
            chapterIndex: spineIndex,
            chapterTitle: chapterTitle,
            chapterCharOffset: chapterCharOffset,
            textAfter: textAfter,
            percent: percent,
            fileSize: fileSize,
            modTime: modTime.timeIntervalSince1970
        )
    }

    /// 解析进度 JSON；兼容旧版纯 Int64 字符串（txt 全局字节偏移，无指纹）
    static func parse(_ json: String, fileSize: Int64, modTime: Date, isEpub: Bool) -> NovelAnchor? {
        let trimmed = json.trimmingCharacters(in: .whitespaces)
        if let data = trimmed.data(using: .utf8),
           let anchor = try? JSONDecoder().decode(NovelAnchor.self, from: data) {
            return anchor
        }
        if !isEpub, let offset = Int64(trimmed) {
            return NovelAnchor(kind: .txt, offset: offset, fileSize: fileSize,
                               modTime: modTime.timeIntervalSince1970)
        }
        return nil
    }

    func json() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    /// 指纹是否匹配当前文件（不匹配说明文件被替换）
    func fingerprintMatches(fileSize: Int64, modTime: Date) -> Bool {
        self.fileSize == fileSize && abs(self.modTime - modTime.timeIntervalSince1970) < 2
    }

    /// 文件大小一致、仅 mtime 差异（服务端精度/时区漂移）：锚点仍然可用，不重置进度
    func sizeMatches(_ fileSize: Int64) -> Bool {
        self.fileSize == fileSize
    }
}

// MARK: - 阅读器主题配色（IOS-502：跟随系统 / 日间 / 夜间 / 护眼）

struct ReaderThemeSpec {
    let background: Color
    let text: Color
    let secondaryText: Color
    let controlBackground: Color

    static func spec(for theme: ReaderTheme) -> ReaderThemeSpec {
        switch theme {
        case .auto:
            // 跟随 App 主题（浅色/深色），与页面背景对齐
            return ReaderThemeSpec(
                background: AppColors.pageBackground,
                text: AppColors.textPrimary,
                secondaryText: AppColors.textSecondary,
                controlBackground: AppColors.cardBackground
            )
        case .day:
            return ReaderThemeSpec(
                background: Color(hex: 0xFAF7F2),
                text: Color(hex: 0x1F2937),
                secondaryText: Color(hex: 0x6B7280),
                controlBackground: Color(hex: 0xFFFFFF)
            )
        case .eyeCare:
            return ReaderThemeSpec(
                background: Color(hex: 0xC7EDCC),
                text: Color(hex: 0x1F2937),
                secondaryText: Color(hex: 0x4B5563),
                controlBackground: Color(hex: 0xE3F3E6)
            )
        case .night:
            // 沉浸式场景统一纯黑背景（§2.2.3）
            return ReaderThemeSpec(
                background: Color.black,
                text: Color(hex: 0xB3B3B3),
                secondaryText: Color(hex: 0x7A7A7A),
                controlBackground: Color(hex: 0x121212)
            )
        }
    }
}

// MARK: - 阅读排版配置（设置实时生效）

struct ReaderAppearance: Equatable {
    var fontSize: Double
    var lineSpacing: Double
    var theme: ReaderTheme
    var pageMode: ReaderPageMode
    var useSerifFont: Bool

    static func current() -> ReaderAppearance {
        ReaderAppearance(
            fontSize: AppSettings.Reader.fontSize,
            lineSpacing: AppSettings.Reader.lineSpacing,
            theme: AppSettings.Reader.theme,
            pageMode: AppSettings.Reader.pageMode,
            useSerifFont: AppSettings.Reader.useSerifFont
        )
    }

    /// 正文字体：思源宋体（Noto Serif SC，内置资源；未打包时回退系统宋体）
    func bodyFont(heading: Int = 0) -> UIFont {
        let size = heading > 0 ? fontSize + Double(4 - min(heading, 3)) * 2.5 : fontSize
        let weight: UIFont.Weight = heading > 0 ? .semibold : .regular
        if useSerifFont,
           let serif = UIFont(name: "NotoSerifSC-Regular", size: size) {
            return UIFontMetrics.default.scaledFont(for: serif)
        }
        if useSerifFont {
            return UIFont.systemFont(ofSize: size, weight: weight).withDesign(.serif)
        }
        return UIFont.systemFont(ofSize: size, weight: weight)
    }

    /// 行距（倍数 → 段样式行间距增量）
    var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let font = bodyFont()
        style.minimumLineHeight = font.lineHeight * lineSpacing
        style.maximumLineHeight = font.lineHeight * lineSpacing
        style.paragraphSpacing = fontSize * 0.45
        style.lineBreakMode = .byWordWrapping
        return style
    }
}

private extension UIFont {
    func withDesign(_ design: UIFontDescriptor.SystemDesign) -> UIFont {
        guard let descriptor = fontDescriptor.withDesign(design) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
