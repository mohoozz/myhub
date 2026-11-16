import Foundation
import GRDB

/// 外挂字幕轨（同目录同名 srt/ass/ssa，含 `name.zh.srt` 语言后缀约定）
struct ExternalSubtitleTrack: Equatable, Identifiable {
    var id: String { path }
    let path: String
    /// 展示名：语言后缀（`name.zh.srt` → 「zh」），无后缀为「外挂字幕」
    let displayName: String
}

/// 字幕管理（IOS-201 播放能力）：
/// - 外挂 srt/ass/ssa 自动匹配同目录同名文件（含语言后缀），启动自动加载最优匹配；
/// - 双引擎统一以 `SubtitleRenderView` 浮层渲染（AVPlayer 不原生支持外挂字幕，VLC 亦保持一致体验）；
/// - ASS 保留样式/位置/滚动动画（B 站弹幕 ASS 不再只能挤在底部），SRT 走底部居中默认样式；
/// - 样式（AppSettings.Player.subtitleFontSize）与延迟（subtitleDelay，正数=字幕延后）可调；
/// - 内嵌轨选择走 PlayerCore（selectSubtitleTrack），与外挂互斥。
@MainActor
final class SubtitleManager: ObservableObject {
    @Published private(set) var externalTracks: [ExternalSubtitleTrack] = []
    @Published private(set) var activeExternalPath: String?
    @Published private(set) var timeline: SubtitleTimeline = .empty

    private var cues: [SubtitleCue] = []
    /// ASS 脚本分辨率（PlayRes，映射到视频显示区域的基准）
    private var scriptSize: CGSize?

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
        let parsed = await Self.parse(ext: ext, text: text)
        guard !parsed.isEmpty else { return }
        var resolved = parsed
        resolved.cues = parsed.cues.sorted { $0.start < $1.start }
        cues = resolved.cues
        scriptSize = resolved.scriptSize
        timeline = resolved
        activeExternalPath = track.path
    }

    func clearSelection() {
        activeExternalPath = nil
        cues = []
        scriptSize = nil
        timeline = .empty
    }

    func reset() {
        externalTracks = []
        clearSelection()
    }

    // MARK: - 解析

    /// 后台解析：B 站弹幕 ASS 可达数万条事件，主线程解析会卡住播放页
    private static func parse(ext: String, text: String) async -> SubtitleTimeline {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let timeline: SubtitleTimeline
                switch ext {
                case "srt": timeline = parseSRT(text)
                case "ass", "ssa": timeline = ASSParser.parse(text)
                default: timeline = .empty
                }
                continuation.resume(returning: timeline)
            }
        }
    }

    /// srt：`序号 + 时间轴(00:00:01,000 --> 00:00:04,000) + 文本` 块（底部居中，字号取播放器设置）
    nonisolated static func parseSRT(_ text: String) -> SubtitleTimeline {
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
            guard let start = ASSParser.parseTime(startRaw), let end = ASSParser.parseTime(endRaw) else { continue }
            let body = lines.dropFirst().joined(separator: "\n")
            guard !body.isEmpty else { continue }
            var style = SubtitleStyleSpec()
            style.alignment = 2
            cues.append(SubtitleCue(
                id: cues.count, start: start, end: end, text: body, style: style, position: nil, move: nil
            ))
        }
        return SubtitleTimeline(cues: cues, scriptSize: nil)
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
            // 显式响应取消：切换视频 / 退出播放器时停止字幕下载（TODO 372 同类检查）
            try Task.checkCancellation()
            data.append(chunk)
            if data.count > 8 * 1024 * 1024 { break }   // 字幕文件上限保护
        }
        return data
    }
}
