import CoreGraphics
import Foundation
import UIKit

/// 字幕移动动画（ASS `\move`）：从 from 线性走到 to，时间相对 cue 起点
struct SubtitleMove {
    var from: CGPoint
    var to: CGPoint
    /// 相对 cue 起点的秒偏移（`\move(x1,y1,x2,y2)` 缺省为整个 cue 时长）
    var startOffset: TimeInterval
    var endOffset: TimeInterval
}

/// 单条字幕的视觉样式（ASS `[V4+ Styles]` 展开结果；SRT 使用默认值）
struct SubtitleStyleSpec {
    var fontName: String = ""
    /// ASS 为 PlayRes 单位（缺省按 1080 高度的常见弹幕字号）；SRT 忽略（取播放器设置字号）
    var fontSize: CGFloat = 40
    var primaryColor: UIColor = .white
    var outlineColor: UIColor = .black
    var bold: Bool = false
    var italic: Bool = false
    /// 描边宽度（PlayRes 单位）
    var outlineWidth: CGFloat = 1.5
    var shadow: CGFloat = 0
    /// numpad 对齐：1/2/3 底 左/中/右，4/5/6 中，7/8/9 顶
    var alignment: Int = 2
    var marginL: CGFloat = 0
    var marginR: CGFloat = 0
    var marginV: CGFloat = 0
}

/// 单条字幕 cue（SRT / ASS 统一模型）
struct SubtitleCue: Identifiable {
    let id: Int
    var start: TimeInterval
    var end: TimeInterval
    /// 已剥离覆盖标签的纯文本（`\N` 已转成换行）
    var text: String
    var style: SubtitleStyleSpec
    /// 绝对定位（ASS PlayRes 坐标）；nil = 按 alignment + margin 布局
    var position: CGPoint?
    /// 线性移动（滚动弹幕）
    var move: SubtitleMove?
    /// ASS 事件层级：数值越大越靠上层
    var layer: Int = 0
}

/// 字幕时间轴：ASS 带脚本分辨率（PlayRes），SRT 为 nil（简单底部居中）
struct SubtitleTimeline {
    var cues: [SubtitleCue]
    var scriptSize: CGSize?
    /// 是否为 ASS/SSA（坐标 = PlayRes 单位）；false = SRT 简单模式（坐标 = 视图点）
    var isASS: Bool = false

    static let empty = SubtitleTimeline(cues: [], scriptSize: nil)

    var isEmpty: Bool { cues.isEmpty }
    /// 含移动动画（需要按帧重绘）
    var hasAnimation: Bool { cues.contains { $0.move != nil } }
}

/// 轻量相等判定：避免播放中 4Hz 刷新时对整条时间轴做 O(n) 比较
extension SubtitleTimeline: Equatable {
    static func == (lhs: SubtitleTimeline, rhs: SubtitleTimeline) -> Bool {
        lhs.isASS == rhs.isASS
            && lhs.scriptSize == rhs.scriptSize
            && lhs.cues.count == rhs.cues.count
            && lhs.cues.first?.id == rhs.cues.first?.id
            && lhs.cues.first?.start == rhs.cues.first?.start
            && lhs.cues.last?.start == rhs.cues.last?.start
            && lhs.cues.last?.text == rhs.cues.last?.text
    }
}

/// ASS / SSA 解析（支持 `[V4+ Styles]` 样式表、`\an` `\pos` `\move` `\c` `\fs` `\bord` 等覆盖标签）。
/// 目的：B 站导出的一类 ASS 弹幕能按各自位置 / 颜色 / 滚动轨迹渲染，而不是只能挤在最底下。
enum ASSParser {
    /// 解析失败或无有效事件时返回空时间轴
    static func parse(_ text: String) -> SubtitleTimeline {
        var playRes = CGSize.zero
        var styles: [String: SubtitleStyleSpec] = [:]
        var styleFormat: [String] = []
        var eventFormat: [String] = []
        var cues: [SubtitleCue] = []
        var section = ""
        var nextID = 0

        var normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalized.hasPrefix("\u{FEFF}") { normalized.removeFirst() }

        for rawLine in normalized.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix(";"), !line.hasPrefix("!:") else { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = line.lowercased()
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            switch section {
            case "[script info]":
                switch key {
                case "playresx":
                    if let v = Double(value), v > 0 { playRes.width = v }
                case "playresy":
                    if let v = Double(value), v > 0 { playRes.height = v }
                default:
                    break
                }

            case "[v4+ styles]", "[v4 styles]", "[v4++ styles]":
                if key == "format" {
                    styleFormat = splitFields(value, limit: nil).map { $0.lowercased() }
                } else if key == "style" {
                    parseStyle(value, format: styleFormat, into: &styles)
                }

            case "[events]":
                if key == "format" {
                    eventFormat = splitFields(value, limit: nil).map { $0.lowercased() }
                } else if key == "dialogue" || key == "comment" {
                    // Comment 行不渲染
                    guard key == "dialogue" else { continue }
                    guard let cue = parseEvent(
                        value, format: eventFormat, styles: styles, id: nextID
                    ) else { continue }
                    nextID += 1
                    cues.append(cue)
                }

            default:
                break
            }
        }

        guard !cues.isEmpty else { return .empty }
        let scriptSize = (playRes.width > 0 && playRes.height > 0) ? playRes : nil
        return SubtitleTimeline(
            cues: cues.sorted { $0.start < $1.start },
            scriptSize: scriptSize,
            isASS: true
        )
    }

    // MARK: - 样式表

    private static func parseStyle(_ value: String, format: [String], into styles: inout [String: SubtitleStyleSpec]) {
        let defaultFormat = [
            "name", "fontname", "fontsize", "primarycolour", "secondarycolour",
            "outlinecolour", "backcolour", "bold", "italic", "underline", "strikeout",
            "scalex", "scaley", "spacing", "angle", "borderstyle", "outline", "shadow",
            "alignment", "marginl", "marginr", "marginv", "encoding"
        ]
        let keys = format.isEmpty ? defaultFormat : format
        let fields = splitFields(value, limit: keys.count)
        var map: [String: String] = [:]
        for (key, field) in zip(keys, fields) { map[key] = field }

        var spec = SubtitleStyleSpec()
        let name = (map["name"] ?? "").trimmingCharacters(in: .whitespaces)
        spec.fontName = map["fontname"] ?? ""
        spec.fontSize = max(6, number(map["fontsize"], fallback: spec.fontSize))
        spec.primaryColor = assColor(map["primarycolour"]) ?? spec.primaryColor
        spec.outlineColor = assColor(map["outlinecolour"]) ?? spec.outlineColor
        spec.bold = (Int(map["bold"] ?? "") ?? 0) != 0
        spec.italic = (Int(map["italic"] ?? "") ?? 0) != 0
        spec.outlineWidth = max(0, number(map["outline"], fallback: spec.outlineWidth))
        spec.shadow = max(0, number(map["shadow"], fallback: 0))
        spec.alignment = Int(map["alignment"] ?? "") ?? spec.alignment
        spec.marginL = number(map["marginl"], fallback: 0)
        spec.marginR = number(map["marginr"], fallback: 0)
        spec.marginV = number(map["marginv"], fallback: 0)
        if !name.isEmpty { styles[name.lowercased()] = spec }
    }

    /// 字段转数值（缺失/非法时用兜底值）
    private static func number(_ raw: String?, fallback: CGFloat) -> CGFloat {
        guard let raw, let value = Double(raw.trimmingCharacters(in: .whitespaces)) else { return fallback }
        return CGFloat(value)
    }

    // MARK: - 事件行

    private static func parseEvent(
        _ value: String,
        format: [String],
        styles: [String: SubtitleStyleSpec],
        id: Int
    ) -> SubtitleCue? {
        let defaultFormat = [
            "layer", "start", "end", "style", "name",
            "marginl", "marginr", "marginv", "effect", "text"
        ]
        let keys = format.isEmpty ? defaultFormat : format
        let fields = splitFields(value, limit: keys.count)
        guard fields.count >= keys.count else { return nil }
        var map: [String: String] = [:]
        for (key, field) in zip(keys, fields) { map[key] = field }

        guard let start = parseTime(map["start"]),
              let end = parseTime(map["end"]),
              end > start else { return nil }

        var style = styles[(map["style"] ?? "").lowercased()] ?? SubtitleStyleSpec()
        // 事件级 margin 覆盖（0 视为未设置，沿用样式）
        let marginL = number(map["marginl"], fallback: 0)
        let marginR = number(map["marginr"], fallback: 0)
        let marginV = number(map["marginv"], fallback: 0)
        if marginL > 0 { style.marginL = marginL }
        if marginR > 0 { style.marginR = marginR }
        if marginV > 0 { style.marginV = marginV }

        let resolved = resolveOverrides(map["text"] ?? "", base: style, duration: end - start)
        let body = resolved.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }

        return SubtitleCue(
            id: id,
            start: start,
            end: end,
            text: body,
            style: resolved.style,
            position: resolved.position,
            move: resolved.move,
            layer: Int(map["layer"] ?? "") ?? 0
        )
    }

    // MARK: - 覆盖标签

    private static func resolveOverrides(
        _ raw: String,
        base: SubtitleStyleSpec,
        duration: TimeInterval
    ) -> (text: String, style: SubtitleStyleSpec, position: CGPoint?, move: SubtitleMove?) {
        var style = base
        var position: CGPoint?
        var move: SubtitleMove?
        var output = ""
        var index = raw.startIndex

        while index < raw.endIndex {
            let character = raw[index]
            if character == "{" {
                guard let close = raw[index...].firstIndex(of: "}") else { break }
                let block = String(raw[raw.index(after: index)..<close])
                applyOverrides(block, style: &style, position: &position, move: &move, duration: duration)
                index = raw.index(after: close)
                continue
            }
            output.append(character)
            index = raw.index(after: index)
        }

        output = output
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: "\u{00A0}")
        return (output, style, position, move)
    }

    private static func applyOverrides(
        _ block: String,
        style: inout SubtitleStyleSpec,
        position: inout CGPoint?,
        move: inout SubtitleMove?,
        duration: TimeInterval
    ) {
        for token in block.components(separatedBy: "\\") {
            let tag = token.trimmingCharacters(in: .whitespaces)
            guard !tag.isEmpty else { continue }
            applyOverride(tag, style: &style, position: &position, move: &move, duration: duration)
        }
    }

    private static func applyOverride(
        _ tag: String,
        style: inout SubtitleStyleSpec,
        position: inout CGPoint?,
        move: inout SubtitleMove?,
        duration: TimeInterval
    ) {
        if tag.hasPrefix("alpha") || tag.hasPrefix("blur") || tag.hasPrefix("fade")
            || tag.hasPrefix("fad") || tag.hasPrefix("t(") || tag.hasPrefix("org")
            || tag.hasPrefix("clip") || tag.hasPrefix("iclip") || tag.hasPrefix("p") && tag.count > 1 && tag.dropFirst().allSatisfy(\.isNumber) {
            return
        }

        // 对齐：\an1..\an9（numpad）
        if tag.hasPrefix("an") {
            if let value = Int(tag.dropFirst(2)), (1...9).contains(value) { style.alignment = value }
            return
        }
        // 旧版 \a 对齐
        if tag.hasPrefix("a"), !tag.hasPrefix("an") {
            if let value = Int(tag.dropFirst()) { style.alignment = legacyAlignment(value) }
            return
        }
        if tag.hasPrefix("pos(") {
            let numbers = numbers(in: tag)
            if numbers.count >= 2 { position = CGPoint(x: numbers[0], y: numbers[1]) }
            return
        }
        if tag.hasPrefix("move(") {
            let numbers = numbers(in: tag)
            if numbers.count >= 4 {
                let offsetStart: TimeInterval = numbers.count >= 6 ? Double(numbers[4]) / 1000 : 0
                let offsetEnd: TimeInterval = numbers.count >= 6 ? Double(numbers[5]) / 1000 : duration
                move = SubtitleMove(
                    from: CGPoint(x: numbers[0], y: numbers[1]),
                    to: CGPoint(x: numbers[2], y: numbers[3]),
                    startOffset: max(0, min(offsetStart, duration)),
                    endOffset: max(0.001, min(offsetEnd, duration))
                )
            }
            return
        }
        if tag.hasPrefix("bord") || tag.hasPrefix("xbord") || tag.hasPrefix("ybord") {
            let value = String(tag.drop { !$0.isNumber && $0 != "." && $0 != "-" })
            if let width = Double(value) { style.outlineWidth = max(0, CGFloat(width)) }
            return
        }
        if tag.hasPrefix("shad") || tag.hasPrefix("xshad") || tag.hasPrefix("yshad") {
            let value = String(tag.drop { !$0.isNumber && $0 != "." && $0 != "-" })
            if let shadow = Double(value) { style.shadow = max(0, CGFloat(shadow)) }
            return
        }
        if tag.hasPrefix("fn") {
            let name = String(tag.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { style.fontName = name }
            return
        }
        if tag.hasPrefix("fs") {
            let value = String(tag.dropFirst(2))
            if let size = Double(value), size > 0 { style.fontSize = CGFloat(size) }
            return
        }
        if tag.hasPrefix("1c") {
            if let color = assColor(String(tag.dropFirst(2))) { style.primaryColor = color }
            return
        }
        // \3c = 描边色（弹幕常用它把描边压成纯黑/纯白）
        if tag.hasPrefix("3c") {
            if let color = assColor(String(tag.dropFirst(2))) { style.outlineColor = color }
            return
        }
        if tag.hasPrefix("c") {
            if let color = assColor(String(tag.dropFirst())) { style.primaryColor = color }
            return
        }
        if tag.hasPrefix("b") && !tag.hasPrefix("bord") {
            let value = String(tag.dropFirst())
            if value.isEmpty { style.bold = true }
            else if let weight = Int(value) { style.bold = weight != 0 }
            return
        }
        if tag.hasPrefix("i") {
            let value = String(tag.dropFirst())
            if value.isEmpty { style.italic = true }
            else if let flag = Int(value) { style.italic = flag != 0 }
            return
        }
        // 其余（\fscx/\fscy/\q/\u/\s…）忽略
    }

    /// SSA 旧版对齐值 → numpad 对齐
    private static func legacyAlignment(_ value: Int) -> Int {
        switch value {
        case 1: return 1
        case 2: return 2
        case 3: return 3
        case 5: return 7
        case 6: return 8
        case 7: return 9
        case 9: return 4
        case 10: return 5
        case 11: return 6
        default: return 2
        }
    }

    // MARK: - 工具

    /// 提取标签括号内的数字（`pos(1,2)` / `move(1,2,3,4,0,500)`，支持负坐标）
    private static func numbers(in tag: String) -> [CGFloat] {
        var values: [CGFloat] = []
        var current = ""
        for character in tag {
            if character.isNumber || character == "." || (character == "-" && current.isEmpty) {
                current.append(character)
            } else if !current.isEmpty {
                if let value = Double(current) { values.append(CGFloat(value)) }
                current = ""
            }
        }
        if !current.isEmpty, let value = Double(current) { values.append(CGFloat(value)) }
        return values
    }

    /// ASS 颜色 `&HAABBGGRR` / `&HBBGGRR`（AA=0 不透明）
    static func assColor(_ raw: String?) -> UIColor? {
        guard var text = raw?.uppercased().trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "&", with: "")
        if text.hasPrefix("H") { text.removeFirst() }
        guard !text.isEmpty, text.allSatisfy(\.isHexDigit), let value = UInt32(text, radix: 16) else { return nil }

        let a: Double
        let b: Double
        let g: Double
        let r: Double
        if text.count > 6 {
            a = Double((value >> 24) & 0xFF)
            b = Double((value >> 16) & 0xFF)
            g = Double((value >> 8) & 0xFF)
            r = Double(value & 0xFF)
        } else {
            a = 0
            b = Double((value >> 16) & 0xFF)
            g = Double((value >> 8) & 0xFF)
            r = Double(value & 0xFF)
        }
        return UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1 - a / 255)
    }

    /// 逗号分列；limit 给定时仅前 limit-1 个逗号参与分割（文本字段可含逗号）
    static func splitFields(_ raw: String, limit: Int?) -> [String] {
        var result: [String] = []
        var current = ""
        for character in raw {
            if character == "," {
                if let limit, result.count >= limit - 1 {
                    current.append(character)
                } else {
                    result.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        result.append(current)
        if let limit, result.count > limit { result = Array(result.prefix(limit)) }
        return result.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// `h:mm:ss.cc` / `h:mm:ss,cc`
    static func parseTime(_ raw: String?) -> TimeInterval? {
        guard let raw else { return nil }
        let normalized = raw
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        let parts = normalized.components(separatedBy: ":")
        guard parts.count >= 2 else { return nil }
        let seconds = Double(parts[parts.count - 1]) ?? 0
        let minutes = Double(parts[parts.count - 2]) ?? 0
        let hours = parts.count >= 3 ? (Double(parts[parts.count - 3]) ?? 0) : 0
        return hours * 3600 + minutes * 60 + seconds
    }
}
