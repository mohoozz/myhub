#include "ChapterRules.h"

#include <QSet>

namespace myhub {

namespace {

ChapterRule makeRule(const char *id, const char *name, const char *pattern, const char *firstChars)
{
    ChapterRule rule;
    rule.id = QString::fromLatin1(id);
    rule.name = QString::fromUtf8(name);
    rule.pattern = QString::fromUtf8(pattern);
    rule.firstChars = QString::fromUtf8(firstChars);
    // 规则是编译期常量，写错正则在启动时就该炸出来（而不是静默变「无章节」）
    rule.regex = QRegularExpression(rule.pattern);
    Q_ASSERT_X(rule.regex.isValid(), "ChapterRules", pattern);
    return rule;
}

QVector<ChapterRule> buildRules()
{
    // 规则正文按 Legado 默认规则的写法风格重写，并补 calibre 常用的西文标记
    // （不是逐字拷贝：其规则文件只存在于 App 资产里，无法随包分发）。
    return {
        // ---- 中文（历史内置，优先级最高）----
        makeRule(
            "zh_di_zhang", "第x章/节/回/卷（历史内置）",
            R"(^第[0-9０-９零〇一二三四五六七八九十百千万两壹贰叁肆伍陆柒捌玖拾佰仟]+[章节回卷集部篇][^\n]{0,38}$)",
            "第"),
        makeRule("zh_preamble", "楔子/序章/番外（历史内置）",
                 R"(^(楔子|序章|序言|前言|引子|终章|尾声|后记|番外篇?)([^\n]{0,30})?$)",
                 "楔序前引终尾后番"),
        makeRule("en_chapter", "Chapter n（历史内置）",
                 R"(^(Chapter|CHAPTER|chapter)\s+[0-9０-９IVXLCivxlc]+[^\n]{0,38}$)", "cC"),

        // ---- 中文扩展（Legado 默认规则风格）----
        makeRule(
            "zh_di_zhang_loose", "第 x 章（允许空格/全角数字/较长标题）",
            R"(^第\s{0,3}[0-9０-９零〇一二三四五六七八九十百千万两壹贰叁肆伍陆柒捌玖拾佰仟]{1,12}\s{0,3}[章节回卷集部篇幕话話](\s{0,3}[^\n]{0,40})?$)",
            "第"),
        makeRule(
            "zh_di_zhang_bare", "无「第」字（如「一章 初入宗门」「12、惊变」）",
            R"(^[0-9０-９零〇一二三四五六七八九十百千万两壹贰叁肆伍陆柒捌玖拾佰仟]{1,12}\s{0,3}[章节回卷集部篇幕话話](\s{0,3}[^\n]{0,40})?$)",
            "0123456789０１２３４５６７８９零〇一二三四五六七八九十百千万两壹贰叁肆伍陆柒捌玖拾佰"
            "仟"),
        makeRule(
            "zh_preamble_ext", "卷首/卷尾/附录/感言等",
            R"(^(楔子|序章|序言|序|前言|引子|引语|卷首语|终章|尾声|后记|番外|外传|附录|完本感言|上架感言|作者的话|正文)(\s{0,3}[^\n]{0,30})?$)",
            "楔序前引卷终尾后番外附完上作正"),
        makeRule("zh_volume_word", "上/中/下卷·终卷·第x卷",
                 R"(^(上|中|下|终|第[一二三四五六七八九十])(卷|部|篇|册)(\s{0,3}[^\n]{0,30})?$)",
                 "上中下终第"),

        // ---- 西文（calibre 常见章节标记）----
        makeRule(
            "en_chapter_loose", "Chapter/Ch./Section/Part/Book n（数字·罗马数字·英文数词）",
            R"((?i)^(chapter|chap\.?|ch\.?|section|part|book|volume|vol\.?|act|scene)\s{0,3}([0-9]{1,4}|[ivxlcdm]{1,8}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|hundred)(\s{0,3}[[:punct:]]?\s{0,3}[^\n]{0,40})?$)",
            "cCsSpPbBvVaA"),
        makeRule(
            "en_title_word", "Prologue/Epilogue/Interlude/Appendix 等",
            R"((?i)^(prologue|epilogue|foreword|preface|afterword|interlude|appendix|introduction|conclusion)(\s{0,3}[[:punct:]]?\s{0,3}[^\n]{0,30})?$)",
            "pPeEfFaAiIcC"),
        makeRule("en_roman_alone", "罗马数字独占一行（I / XII.）", R"(^[IVXLCDM]{1,7}\.?$)",
                 "IVXLCDM"),
        makeRule("en_number_alone", "纯数字独占一行（12 / 12. / 12、）", R"(^[0-9]{1,4}[\.、]?$)",
                 "0123456789"),
    };
}

const QRegularExpression &numberedHeading()
{
    static const QRegularExpression re(QStringLiteral(
        R"(^(正文\s*)?第[0-9０-９零〇一二三四五六七八九十百千万两]+[章节回卷集部篇]|^[Cc]hapter\s+[0-9IVXLCivxlc]+)"));
    return re;
}

const QRegularExpression &openingHeading()
{
    static const QRegularExpression re(QStringLiteral(
        R"(^(楔子|序章|序言|序|前言|引子|引语|卷首语|终章|尾声|后记|番外|外传|附录|正文|Prologue|Foreword|Preface))"));
    return re;
}

} // namespace

const QVector<ChapterRule> &ChapterRules::rules()
{
    static const QVector<ChapterRule> table = buildRules();
    return table;
}

const ChapterRule *ChapterRules::find(const QString &id)
{
    for (const ChapterRule &rule : rules()) {
        if (rule.id == id) {
            return &rule;
        }
    }
    return nullptr;
}

int ChapterRules::maxCandidates()
{
    return 20000;
}

bool ChapterRules::isPlausible(const QVector<NovelChapter> &chapters, qint64 fileSize)
{
    if (chapters.size() < 2) {
        return false;
    }

    qint64 lastOffset = -1;
    for (const NovelChapter &chapter : chapters) {
        if (chapter.startOffset <= lastOffset) {
            return false;
        }
        if (lastOffset >= 0 && chapter.startOffset - lastOffset < 32) {
            return false;
        }
        lastOffset = chapter.startOffset;
    }

    if (fileSize > 0 && static_cast<double>(fileSize) / chapters.size() < 64.0) {
        return false;
    }

    QSet<QString> distinct;
    for (const NovelChapter &chapter : chapters) {
        distinct.insert(chapter.title);
    }
    if (chapters.size() >= 8 && static_cast<double>(distinct.size()) / chapters.size() < 0.5) {
        return false;
    }
    if (distinct.size() == 1 && chapters.size() > 3) {
        return false;
    }
    return true;
}

const ChapterRule *ChapterRules::selectBest(const QVector<QVector<NovelChapter>> &byRule,
                                            qint64 fileSize, QString *rejectedRuleId)
{
    const QVector<ChapterRule> &table = rules();

    // 被否掉的规则里候选最多的那条：日志里能直接看出「为什么没选更细的规则」
    int rejectedIndex = -1;
    int bestIndex = -1;
    for (int i = 0; i < byRule.size() && i < table.size(); ++i) {
        const QVector<NovelChapter> &candidates = byRule.at(i);
        if (candidates.isEmpty()) {
            continue;
        }
        if (!isPlausible(candidates, fileSize)) {
            if (rejectedIndex < 0 || candidates.size() > byRule.at(rejectedIndex).size()) {
                rejectedIndex = i;
            }
            continue;
        }
        // 取章节数最多的；严格大于才替换 → 并列时保留表里靠前的（更可信）
        if (bestIndex < 0 || candidates.size() > byRule.at(bestIndex).size()) {
            bestIndex = i;
        }
    }

    if (rejectedRuleId) {
        *rejectedRuleId = rejectedIndex >= 0 ? table.at(rejectedIndex).id : QString();
    }
    return bestIndex >= 0 ? &table.at(bestIndex) : nullptr;
}

bool ChapterRules::isNumberedHeading(const QString &title)
{
    return numberedHeading().match(title).hasMatch();
}

bool ChapterRules::isOpeningHeading(const QString &title)
{
    return openingHeading().match(title).hasMatch();
}

} // namespace myhub
