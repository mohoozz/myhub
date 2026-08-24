import Foundation
import GRDB

/// 外挂字幕轨（同目录同名 srt/ass/ssa，含 `name.zh.srt` 语言后缀约定）
struct ExternalSubtitleTrack: Equatable, Identifiable {
    var id: String { path }
    let path: String
    /// 展示名：语言后缀（`name.zh.srt` → 「zh」），无后缀为「外挂字幕」
    let displayName: String
}

/// 单条字幕 cue
struct SubtitleCue {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

/// 字幕管理（IOS-201 播放能力）：
/// - 外挂 srt/ass/ssa 自动匹配同目录同名文件（含语言后缀），启动自动加载最优匹配；
/// - 双引擎统一以 SwiftUI 浮层渲染（AVPlayer 不原生支持外挂字幕，VLC 亦保持一致体验）；
/// - 样式（AppSettings.Player.subtitleFontSize）与延迟（subtitleDelay，正数=字幕延后）可调；
/// - 内嵌轨选择走 PlayerCore（selectSubtitleTrack），与外挂互斥。
@MainActor
final class SubtitleManager: ObservableObject {
    @Published private(set) var externalTracks: [ExternalSubtitleTrack] = []
    @Published private(set) var activeExternalPath: String?
    @Published private(set) var currentText: String?

    private var cues: [SubtitleCue] = []

    // MARK: - 发现（PlayerView 打开后调用）

    /// 扫描同目录外挂字幕并自动加载最优匹配（精确同名 > 语言后缀序）
    func discover(connectionID: Int64?, mediaPath: String) async {
        reset()
        guard let connectionID,
              let connection = loadConnection(connectionID),
              let adapter = try? AdapterFactory.makeAdapter(for: connection) else { return }

        let parent = StoragePath.parent(of: mediaPath)
        guard let siblings = try? await adapter.list(parent) else { return }

        let fileName = StoragePath.fileName(of: mediaPath)
        let base = (fileName as NSString).deletingPathExtension.lowercased()
        let subtitleExts: Set<String> = ["srt", "ass", "ssa"]

        externalTracks = siblings
            .filter { !$0.isDir && subtitleExts.contains($0.ext) }
            .filter { entry in
                let stem = (entry.name as NSString).deletingPathExtension.lowercased()
                return stem == base || stem.hasPrefix(base + ".")
            }
            .sorted { lhs, rhs in
                // 精确同名优先，其余按自然序（name.srt > name.zh.srt > name.zh-hans.srt…）
                let lExact = (lhs.name as NSString).deletingPathExtension.lowercased() == base
                let rExact = (rhs.name as NSString).deletingPathExtension.lowercased() == base
                if lExact != rExact { return lExact }
                return lhs.name.naturalCompare(rhs.name) == .orderedAscending
            }
            .map { entry in
                let stem = (entry.name as NSString).deletingPathExtension
                let suffix = stem.count > base.count
                    ? String(stem.dropFirst(base.count + 1))
                    : ""
                return ExternalSubtitleTrack(
                    path: entry.path,
                    displayName: suffix.isEmpty ? "外挂字幕" : suffix
                )
            }

        // 自动匹配同名文件
        if let first = externalTracks.first {
            await select(track: first, connectionID: connectionID)
        }
    }

    // MARK: - 选择

    /// 选择外挂字幕轨（与内嵌轨互斥：调用方需同时 core.selectSubtitleTrack(nil)）
    func select(track: ExternalSubtitleTrack, connectionID: Int64?) async {
        guard activeExternalPath != track.path else { return }
        clearSelection()
        guard let connectionID,
              let connection = loadConnection(connectionID),
              let adapter = try? AdapterFactory.makeAdapter(for: connection),
              let data = try? await collect(adapter: adapter, path: track.path) else { return }

        let text = TextEncodingDetector.decode(data).text
        let ext = StoragePath.ext(of: track.path)
        let parsed: [SubtitleCue]
        switch ext {
        case "srt": parsed = Self.parseSRT(text)
        case "ass", "ssa": parsed = Self.parseASS(text)
        default: parsed = []
        }
        guard !parsed.isEmpty else { return }
        cues = parsed.sorted { $0.start < $1.start }
        activeExternalPath = track.path
    }

    func clearSelection() {
        activeExternalPath = nil
        cues = []
        currentText = nil
    }

    func reset() {
        externalTracks = []
        clearSelection()
    }

    // MARK: - 播放同步（PlayerCore.currentTime 驱动）

    /// 按当前播放位置更新浮层文本（延迟：正数 = 字幕延后 subtitleDelay 秒）
    func update(currentTime: TimeInterval) {
        guard !cues.isEmpty else {
            if currentText != nil { currentText = nil }
            return
        }
        let shifted = currentTime - AppSettings.Player.subtitleDelay
        var lo = 0
        var hi = cues.count - 1
        var found: SubtitleCue?
        while lo <= hi {
            let mid = (lo + hi) / 2
            let cue = cues[mid]
            if shifted < cue.start { hi = mid - 1 }
            else if shifted > cue.end { lo = mid + 1 }
            else { found = cue; break }
        }
        let text = found?.text
        if text != currentText { currentText = text }
    }

    // MARK: - 解析

    /// srt：`序号 + 时间轴(00:00:01,000 --> 00:00:04,000) + 文本` 块
    static func parseSRT(_ text: String) -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            var lines = block.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !lines.isEmpty else { continue }
            // 首行可能是序号
            if lines.count > 1, Int(lines[0].trimmingCharacters(in: .whitespaces)) != nil {
                lines.removeFirst()
            }
            guard let timeLine = lines.first,
                  let arrow = timeLine.range(of: "-->") else { continue }
            let startRaw = String(timeLine[..<arrow.lowerBound]).trimmingCharacters(in: .whitespaces)
            let endRaw = String(timeLine[arrow.upperBound...])
                .components(separatedBy: " ").first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard let start = parseTimestamp(startRaw), let end = parseTimestamp(endRaw) else { continue }
            let body = lines.dropFirst().joined(separator: "\n")
            guard !body.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: body))
        }
        return cues
    }

    /// ass/ssa：解析 [Events] 段 Dialogue 行（`Dialogue: Layer,Start,End,Style,...,Text`），剥离特效标签
    static func parseASS(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("dialogue:") else { continue }
            let payload = trimmed.dropFirst("dialogue:".count).trimmingCharacters(in: .whitespaces)
            // 前 9 个逗号为字段分隔，第 10 段起为文本（可含逗号）
            let parts = payload.components(separatedBy: ",")
            guard parts.count >= 10,
                  let start = parseASSTimestamp(parts[1]),
                  let end = parseASSTimestamp(parts[2]) else { continue }
            var body = parts.dropFirst(9).joined(separator: ",")
            body = body.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
            body = body.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: body))
        }
        return cues
    }

    /// `hh:mm:ss,ms` / `hh:mm:ss.ms`
    private static func parseTimestamp(_ raw: String) -> TimeInterval? {
        let normalized = raw.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.components(separatedBy: ":")
        guard parts.count == 3,
              let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    /// ass 时间 `h:mm:ss.cc`（厘秒）
    private static func parseASSTimestamp(_ raw: String) -> TimeInterval? {
        parseTimestamp(raw.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - 工具

    private func loadConnection(_ id: Int64) -> Connection? {
        guard let db = AppDatabase.shared.dbQueue else { return nil }
        return try? db.read { try Connection.fetchOne($0, id: id) }
    }

    private func collect(adapter: StorageAdapter, path: String) async throws -> Data {
        let stream = try await adapter.readStream(path, range: nil)
        var data = Data()
        for try await chunk in stream {
            data.append(chunk)
            if data.count > 8 * 1024 * 1024 { break }   // 字幕文件上限保护
        }
        return data
    }
}
