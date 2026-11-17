import Foundation

/// 删除时的「关联文件」判定（设置 → 文件操作「删除时移除同名文件」；
/// 浏览页删除与阅读页「删除源文件」共用同一口径，避免两处规则漂移）。
///
/// 两组规则：
/// 1. **主名精确相同**：`movie.mkv` → `movie.srt` / `movie.jpg` / `movie.nfo`
///    （只认文件；主名区分大小写，扩展名不区分大小写且必须不同——`movie.MKV` 视为同类型，不会互相牵连）
/// 2. **语言后缀字幕**：`movie.mkv` → `movie.zh.srt` / `movie.en.ass` / `movie.zh-Hans.srt`
///    （此前主名不同 → 不被联动删除，删掉视频后语言后缀字幕残留）
///
/// 语言后缀规则会**多删文件**，因此逐条收紧：
/// - 只对字幕扩展名生效：`movie.part2.rar` 这类分卷包不会被牵连；
/// - 后缀 1~2 段，每段 2~12 位字母/数字/`-`/`_`（`zh`、`en-US`、`zh_Hans`、`chs`），
///   或常见中文标签（中字/简中/繁中/中英/双语…）；
/// - 分卷/分片语义（`part1`/`cd2`/`disc1`/`vol3`/`dvd1`）不算语言标签——它们通常不是「同一个文件的字幕」。
enum CompanionFiles {
    /// 参与语言后缀规则的字幕扩展名（与播放器外挂字幕识别保持一致）
    static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "idx", "smi", "lrc"]

    /// 中文语言标签的常见写法（B 站 / 字幕组 / 播放器导出的命名习惯）
    private static let chineseLanguageLabels: Set<String> = [
        "中字", "中文", "简中", "繁中", "简体", "繁体", "中英", "双语", "字幕", "英文", "日文"
    ]

    /// 分卷/分片前缀：其后全是数字时不当作语言标签
    private static let volumePrefixes = ["part", "cd", "disc", "disk", "vol", "dvd", "v"]

    /// 与 `entry` 同目录、可随它一起删除的关联文件。
    ///
    /// 只比对传入的目录列表，不额外发起请求（浏览页传当前 `entries`，阅读页传预取的目录列表）。
    static func sameStemSiblings(of entry: FileEntry, in listing: [FileEntry]) -> [FileEntry] {
        guard !entry.isDir else { return [] }
        let sourceName = entry.name as NSString
        let sourceExt = sourceName.pathExtension
        let sourceStem = sourceName.deletingPathExtension
        guard !sourceExt.isEmpty, !sourceStem.isEmpty else { return [] }
        let directory = StoragePath.parent(of: entry.path)
        return listing.filter {
            isCompanion(
                $0, of: entry,
                directory: directory, sourceStem: sourceStem, sourceExt: sourceExt
            )
        }
    }

    /// 单个候选的判定（`sameStemSiblings` 的过滤体，拆开便于阅读）
    private static func isCompanion(
        _ candidate: FileEntry,
        of entry: FileEntry,
        directory: String,
        sourceStem: String,
        sourceExt: String
    ) -> Bool {
        guard !candidate.isDir, !candidate.path.hasSuffix("/") else { return false }
        guard candidate.path != entry.path else { return false }
        guard StoragePath.parent(of: candidate.path) == directory else { return false }
        let candidateName = candidate.name as NSString
        let candidateExt = candidateName.pathExtension
        guard !candidateExt.isEmpty, candidateExt.lowercased() != sourceExt.lowercased() else { return false }
        let candidateStem = candidateName.deletingPathExtension
        if candidateStem == sourceStem { return true }   // 规则 1：主名精确相同
        // 规则 2：语言后缀字幕（主名不同，仅字幕类型参与）
        guard subtitleExtensions.contains(candidateExt.lowercased()) else { return false }
        return languageLabel(in: candidateStem, after: sourceStem) != nil
    }

    /// `candidateStem` 是否为「源主名 + 语言标签」，是则返回标签串（`zh` / `zh-Hans.CN`），否则 nil
    static func languageLabel(in candidateStem: String, after sourceStem: String) -> String? {
        let prefix = sourceStem + "."
        guard candidateStem.count > prefix.count, candidateStem.hasPrefix(prefix) else { return nil }
        let suffix = String(candidateStem.dropFirst(prefix.count))
        let segments = suffix.components(separatedBy: ".")
        guard (1...2).contains(segments.count), segments.allSatisfy(isLanguageSegment) else { return nil }
        return suffix
    }

    private static func isLanguageSegment(_ segment: String) -> Bool {
        guard !segment.isEmpty else { return false }
        let lowered = segment.lowercased()
        if chineseLanguageLabels.contains(lowered) { return true }
        guard (2...12).contains(segment.count) else { return false }
        guard segment.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return false
        }
        // 分卷/分片：part1 / cd2 / disc1 / vol3 / dvd1 / v2（排除；vi、zh 等语言码不受影响）
        for prefix in volumePrefixes where lowered.hasPrefix(prefix) {
            let rest = lowered.dropFirst(prefix.count)
            if !rest.isEmpty, rest.allSatisfy(\.isNumber) { return false }
        }
        return true
    }
}
