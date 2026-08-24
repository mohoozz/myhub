import Foundation
import CoreFoundation

/// txt 编码检测（IOS-706 / §2.5）：BOM 判定 + 无 BOM 启发式，覆盖 UTF-8 / GBK / Big5 / UTF-16 LE/BE。
/// 纯文本查看与 txt 在线编辑共用；小说阅读器（M3）将复用并补充码元对齐与缓存自愈。
enum TextEncodingDetector {
    struct Result {
        let text: String
        let encoding: String.Encoding
        let encodingName: String
    }

    static let gb18030 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
    )
    static let big5 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.big5.rawValue))
    )

    /// 检测并解码；完全失败时回退 UTF-8 有损解码
    static func decode(_ data: Data) -> Result {
        // 1. BOM 判定
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            if let text = String(data: data.dropFirst(3), encoding: .utf8) {
                return Result(text: text, encoding: .utf8, encodingName: "UTF-8 (BOM)")
            }
        }
        if data.count >= 2, data[0] == 0xFF, data[1] == 0xFE {
            if let text = String(data: data, encoding: .utf16LittleEndian) {
                return Result(text: text, encoding: .utf16LittleEndian, encodingName: "UTF-16 LE (BOM)")
            }
        }
        if data.count >= 2, data[0] == 0xFE, data[1] == 0xFF {
            if let text = String(data: data, encoding: .utf16BigEndian) {
                return Result(text: text, encoding: .utf16BigEndian, encodingName: "UTF-16 BE (BOM)")
            }
        }

        // 2. 严格 UTF-8（失败即非 UTF-8）
        if let text = String(data: data, encoding: .utf8) {
            return Result(text: text, encoding: .utf8, encodingName: "UTF-8")
        }

        // 3. 无 BOM UTF-16 启发式：采样 2KB，统计奇/偶位 0x00 占比（ASCII 为主文本特征明显）
        let sample = data.prefix(2048)
        if sample.count >= 8 {
            var evenZeros = 0
            var oddZeros = 0
            var pairs = 0
            var index = sample.startIndex
            while index + 1 < sample.endIndex {
                if sample[index] == 0 { evenZeros += 1 }
                if sample[index + 1] == 0 { oddZeros += 1 }
                pairs += 1
                index += 2
            }
            let threshold = pairs / 4   // >25% 的零字节判定为 UTF-16
            if oddZeros > threshold, evenZeros == 0,
               let text = String(data: data, encoding: .utf16LittleEndian) {
                return Result(text: text, encoding: .utf16LittleEndian, encodingName: "UTF-16 LE")
            }
            if evenZeros > threshold, oddZeros == 0,
               let text = String(data: data, encoding: .utf16BigEndian) {
                return Result(text: text, encoding: .utf16BigEndian, encodingName: "UTF-16 BE")
            }
        }

        // 4. GBK（GB18030 超集）→ Big5 启发式：谁解码出的 CJK 占比高选谁
        let gb = String(data: data, encoding: gb18030)
        let big5 = String(data: data, encoding: big5)
        if let candidate = [gb.map { ($0, gb18030, "GBK") }, big5.map { ($0, big5, "Big5") }]
            .compactMap({ $0 })
            .max(by: { cjkScore($0.0) < cjkScore($1.0) }) {
            return Result(text: candidate.0, encoding: candidate.1, encodingName: candidate.2)
        }

        // 5. 兜底：UTF-8 有损
        return Result(
            text: String(decoding: data, as: UTF8.self),
            encoding: .utf8, encodingName: "UTF-8（有损）"
        )
    }

    /// 保存编码：优先原编码（不能表示新文本时回退 UTF-8）
    static func encode(_ text: String, preferred: String.Encoding) -> Data {
        if preferred != .utf8, let data = text.data(using: preferred) {
            return data
        }
        return Data(text.utf8)
    }

    /// CJK 字符占比评分（越高说明解码越正确）
    private static func cjkScore(_ text: String) -> Int {
        var score = 0
        for scalar in text.unicodeScalars.prefix(4096) {
            if (0x4E00...0x9FFF).contains(scalar.value) { score += 2 }   // CJK 统一表意
            if scalar.value == 0xFFFD { score -= 4 }                    // 替换符
        }
        return score
    }
}
