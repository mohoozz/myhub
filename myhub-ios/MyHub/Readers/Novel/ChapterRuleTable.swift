import Foundation

/// txt 分章规则表（移植/归纳自 Legado 默认目录规则与 calibre 常见章节标记）。
///
/// 说明：规则正文按「Legado 默认规则的写法风格」重写，并补充 calibre 常用的西文标记，
/// **不是逐字拷贝**（其规则文件仅存在于 App 资产中，无法随包分发）。
///
/// 设计要点：
/// - **数据驱动**：一行一条规则（`pattern` + `firstChars` 预筛集 + 说明），便于按书增删；
/// - **两级匹配**：先用 `firstChars` 做 O(1) 首字符预筛（正文行绝大多数被直接跳过），
///   只对候选行跑正则。否则「N 条规则 × 数十万行」在 20MB 文本上会退化成数十秒；
/// - **选规则而非并集**：每条规则各自收集候选章节，扫描结束后按 Legado 的校验思路
///   （条数、相邻间隔、平均章长、标题重复度）过滤，再取「通过校验且章节数最多」的一条。
///   章节数最多的通常就是真正的目标规则，而正文里偶然出现的「第一章」数量远少于真规则，
///   自然落选；同时避免了「多规则取并集」把书切成碎片的旧问题；
/// - **兜底**：无规则通过校验时沿用首条规则的候选（等价历史行为），仍为空则整本单章。
enum ChapterRuleTable {

    struct Rule {
        let id: String
        let name: String
        /// 规则正则（与行文本做 `firstMatch`，规则内自带 `^`/`$` 锚定）
        let pattern: String
        /// 首字符预筛集（nil = 不做预筛，所有候选行都要跑正则）。
        /// 必须覆盖规则可能匹配的全部首字符，宁多勿少：漏字符会导致章节漏检。
        let firstChars: String?
        let regex: NSRegularExpression?

        init(id: String, name: String, pattern: String, firstChars: String?) {
            self.id = id
            self.name = name
            self.pattern = pattern
            self.firstChars = firstChars
            self.regex = try? NSRegularExpression(pattern: pattern)
        }

        /// 首字符预筛：命中才值得跑正则
        func mayMatch(_ text: String) -> Bool {
            guard let firstChars else { return true }
            guard let first = text.first else { return false }
            return firstChars.contains(first)
        }

        func firstMatch(in text: String, range: NSRange) -> Bool {
            regex?.firstMatch(in: text, options: [], range: range) != nil
        }
    }

    /// 规则表：**顺序即可信度**（越靠前越可信，章节数相同时优先取胜）。
    /// 历史内置的 3 条排在最前，保证已索引书籍的分章结果不会因本次改动大幅变化。
    static let rules: [Rule] = [
        // MARK: 中文（历史内置，优先级最高）
        Rule(
            id: "zh_di_zhang",
            name: "第x章/节/回/卷（历史内置）",
            pattern: #"^第[0-9０-９零〇一二三四五六七八九十百千万两壹贰叁肆伍陆柒捌玖拾佰仟]+[章节回卷集部篇][^\n]{0,38}$"#,
            firstChars: "第"
        ),
        Rule(
            id: "zh_preamble",
            name: "楔子/序章/番外（历史内置）",
            pattern: #"^(楔子|序章|序言|前言|引子|终章|尾声|后记|番外篇?)([^\n]{0,30})?$"#,
            firstChars: "楔序前引终尾后番"
        ),
        Rule(
            id: "en_chapter",
            name: "Chapter n（历史内置）",
            pattern: #"^(Chapter|CHAPTER|chapter)\s+[0-9０-９IVXLCivxlc]+[^\n]{0,38}$"#,
            firstChars: "cC"
        ),

        // MARK: 中文扩展（Legado 默认规则风格）
        Rule(
            id: "zh_di_zhang_loose",
            name: "第 x 章（允许空格/全角数字/较长标题）",
            pattern: #"^第\s{0,3}[0-9０-９零〇一二三四五六七八九十百千万两壹贰叁肆伍陆柒捌玖拾佰仟]{1,12}\s{0,3}[章节回卷集部篇幕话話](\s{0,3}[^\n]{0,40})?$"#,
            firstChars: "第"
        ),
        Rule(
            id: "zh_di_zhang_bare",
            name: "无「第」字（如「一章 初入宗门」「12、惊变」）",
            pattern: #"^[0-9０-９零〇一二三四五六七八九十百千万两壹贰叁肆伍陆柒捌玖拾佰仟]{1,12}\s{0,3}[章节回卷集部篇幕话話](\s{0,3}[^\n]{0,40})?$"#,
            firstChars: "0123456789０１２３４５６７８９零〇一二三四五六七八九十百千万两壹贰叁肆伍陆柒捌玖拾佰仟"
        ),
        Rule(
            id: "zh_preamble_ext",
            name: "卷首/卷尾/附录/感言等",
            pattern: #"^(楔子|序章|序言|序|前言|引子|引语|卷首语|终章|尾声|后记|番外|外传|附录|完本感言|上架感言|作者的话|正文)(\s{0,3}[^\n]{0,30})?$"#,
            firstChars: "楔序前引卷终尾后番外附完上作正"
        ),
        Rule(
            id: "zh_volume_word",
            name: "上/中/下卷·终卷·第x卷",
            pattern: #"^(上|中|下|终|第[一二三四五六七八九十])(卷|部|篇|册)(\s{0,3}[^\n]{0,30})?$"#,
            firstChars: "上中下终第"
        ),

        // MARK: 西文（calibre 常见章节标记）
        Rule(
            id: "en_chapter_loose",
            name: "Chapter/Ch./Section/Part/Book n（数字·罗马数字·英文数词）",
            pattern: #"(?i)^(chapter|chap\.?|ch\.?|section|part|book|volume|vol\.?|act|scene)\s{0,3}([0-9]{1,4}|[ivxlcdm]{1,8}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|hundred)(\s{0,3}[[:punct:]]?\s{0,3}[^\n]{0,40})?$"#,
            firstChars: "cCsSpPbBvVaA"
        ),
        Rule(
            id: "en_title_word",
            name: "Prologue/Epilogue/Interlude/Appendix 等",
            pattern: #"(?i)^(prologue|epilogue|foreword|preface|afterword|interlude|appendix|introduction|conclusion)(\s{0,3}[[:punct:]]?\s{0,3}[^\n]{0,30})?$"#,
            firstChars: "pPeEfFaAiIcC"
        ),
        Rule(
            id: "en_roman_alone",
            name: "罗马数字独占一行（I / XII.）",
            pattern: #"^[IVXLCDM]{1,7}\.?$"#,
            firstChars: "IVXLCDM"
        ),
        Rule(
            id: "en_number_alone",
            name: "纯数字独占一行（12 / 12. / 12、）",
            pattern: #"^[0-9]{1,4}[\.、]?$"#,
            firstChars: "0123456789"
        ),
    ]

    /// 单条规则的候选上限：异常规则（如纯数字行）可能命中十几万行，超过即丢弃尾部，避免内存失控
    static let maxCandidates = 20_000

    /// 候选章节是否可信（Legado 校验思路的轻量实现）：任一不满足即认为该规则误报过多
    static func isPlausible(_ chapters: [ChapterInfo], fileSize: Int64) -> Bool {
        guard chapters.count >= 2 else { return false }
        var lastOffset: Int64 = -1
        for chapter in chapters {
            guard chapter.startOffset > lastOffset else { return false }
            // 相邻章节间隔过小 = 同一行附近连续命中（正则会话误报）
            if lastOffset >= 0, chapter.startOffset - lastOffset < 32 { return false }
            lastOffset = chapter.startOffset
        }
        // 平均章长过小 = 把正文/列表行都当成了标题
        guard Double(fileSize) / Double(chapters.count) >= 64 else { return false }
        let distinct = Set(chapters.map(\.title)).count
        if chapters.count >= 8, Double(distinct) / Double(chapters.count) < 0.5 { return false }
        if distinct == 1, chapters.count > 3 { return false }
        return true
    }

    /// 规则选择：通过校验者中取章节数最多的；并列时按规则表顺序（越靠前越可信）。
    /// 全部不通过校验时返回 nil，由调用方退回首条规则的候选 / 整本单章。
    static func selectBest(
        candidatesByRule: [String: [ChapterInfo]], fileSize: Int64
    ) -> (rule: Rule, chapters: [ChapterInfo])? {
        var best: (rule: Rule, chapters: [ChapterInfo])?
        for rule in rules {
            guard let chapters = candidatesByRule[rule.id], isPlausible(chapters, fileSize: fileSize) else {
                continue
            }
            if let current = best, chapters.count <= current.chapters.count { continue }
            best = (rule, chapters)
        }
        return best
    }
}
