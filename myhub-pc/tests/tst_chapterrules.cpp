// 分章规则表 + 字节级行扫描（§5.1 PC-201 / PC-202）
//
// 覆盖三层纯逻辑：
//   ChapterRules        —— 规则表自检、择优（选规则而不是取并集）、可信度校验
//   ChapterMatcher      —— BOM / 行首缩进 / 首字符预筛 / 锚定匹配
//   ChapterLineScanner  —— 任意分块下字节偏移零漂移（UTF-8 / UTF-16）
//
// 这些用例刻意用「小分块 + 掐在多字节字符中间」喂数据：
// 真实文件 512KB 一块很少正好切在汉字中间，不构造这种输入就测不出偏移漂移。

#include <QtTest>

#include "core/novel/ChapterRules.h"
#include "core/novel/ChapterScan.h"

using namespace myhub;

namespace {

/// 用 1 字节一块喂整份数据，逼出所有跨块拼接路径
QVector<QPair<qint64, qint64>> scanLines(const QByteArray &data, TextCodec::Encoding encoding,
                                         int chunkBytes, QVector<QString> *texts = nullptr)
{
    ChapterLineScanner scanner(encoding);
    QVector<QPair<qint64, qint64>> spans;
    const auto collect = [&spans, texts, encoding](const char *bytes, qint64 start, qint64 end) {
        spans.append({start, end});
        if (texts) {
            texts->append(
                TextCodec::decodeAs(QByteArray(bytes, static_cast<int>(end - start)), encoding)
                    .text);
        }
    };

    for (int offset = 0; offset < data.size(); offset += chunkBytes) {
        scanner.append(data.mid(offset, chunkBytes), collect);
    }
    scanner.finish(collect);
    return spans;
}

NovelChapter chapterAt(const QString &title, qint64 offset)
{
    NovelChapter chapter;
    chapter.title = title;
    chapter.startOffset = offset;
    chapter.ruleId = QStringLiteral("zh_di_zhang");
    return chapter;
}

int ruleIndex(const QString &id)
{
    const QVector<ChapterRule> &rules = ChapterRules::rules();
    for (int i = 0; i < rules.size(); ++i) {
        if (rules.at(i).id == id) {
            return i;
        }
    }
    return -1;
}

} // namespace

class TestChapterRules : public QObject
{
    Q_OBJECT

private slots:
    // ---- 规则表 ----
    void everyRuleIsUsable();
    void ruleIdsAreUnique();

    // ---- 择优 ----
    void selectBestPrefersMoreChapters();
    void selectBestKeepsTableOrderOnTie();
    void selectBestRejectsImplausible();
    void selectBestReportsRejectedRule();

    // ---- 可信度 ----
    void singleChapterIsNotAParsedIndex();
    void offsetsMustIncreaseWithGap();
    void tooManyRepeatedTitlesRejected();
    void numberingHelpers();

    // ---- 匹配 ----
    void matcherAcceptsChineseHeading();
    void matcherSkipsIndentAndBom();
    void matcherRejectsBodyText();
    void matcherAcceptsEnglishHeading();
    void matcherAcceptsUtf16Heading();

    // ---- 对齐 ----
    void headSkipDropsContinuationBytes();
    void tailDropIsSymmetric();
    void trimIncompleteUtf8TailKeepsWholeChars();

    // ---- 行扫描 ----
    void scannerKeepsAbsoluteOffsetsAcrossChunks();
    void scannerHandlesCrlf();
    void scannerHandlesUtf16OddChunks();
    void scannerFinishEmitsLastLineWithoutNewline();
};

void TestChapterRules::everyRuleIsUsable()
{
    const QVector<ChapterRule> &rules = ChapterRules::rules();
    QVERIFY(rules.size() >= 10);
    for (const ChapterRule &rule : rules) {
        QVERIFY2(!rule.id.isEmpty(), "规则必须有 id");
        QVERIFY2(!rule.name.isEmpty(), qPrintable(rule.id));
        QVERIFY2(rule.regex.isValid(), qPrintable(rule.id));
        QVERIFY2(!rule.pattern.isEmpty(), qPrintable(rule.id));
        // 没有首字符集就只能全量解码，20 万行 × 该规则会把索引拖成分钟级
        QVERIFY2(!rule.firstChars.isEmpty(), qPrintable(rule.id));
    }
}

void TestChapterRules::ruleIdsAreUnique()
{
    QSet<QString> ids;
    for (const ChapterRule &rule : ChapterRules::rules()) {
        QVERIFY2(!ids.contains(rule.id), qPrintable(rule.id));
        ids.insert(rule.id);
    }
}

void TestChapterRules::selectBestPrefersMoreChapters()
{
    QVector<QVector<NovelChapter>> byRule(ChapterRules::rules().size());
    const int few = ruleIndex(QStringLiteral("zh_di_zhang"));
    const int many = ruleIndex(QStringLiteral("zh_di_zhang_loose"));
    QVERIFY(few >= 0 && many >= 0);

    for (int i = 0; i < 3; ++i) {
        byRule[few].append(
            chapterAt(QStringLiteral("第%1章").arg(i), static_cast<qint64>(i) * 1000));
    }
    for (int i = 0; i < 10; ++i) {
        byRule[many].append(
            chapterAt(QStringLiteral("第%1章").arg(i), static_cast<qint64>(i) * 1000));
    }

    QString rejected;
    const ChapterRule *best = ChapterRules::selectBest(byRule, 20000, &rejected);
    QVERIFY(best != nullptr);
    QCOMPARE(best->id, QStringLiteral("zh_di_zhang_loose"));
}

void TestChapterRules::selectBestKeepsTableOrderOnTie()
{
    QVector<QVector<NovelChapter>> byRule(ChapterRules::rules().size());
    const int first = 0;
    const int second = 1;

    for (int i = 0; i < 4; ++i) {
        byRule[first].append(
            chapterAt(QStringLiteral("第%1章").arg(i), static_cast<qint64>(i) * 1000));
        byRule[second].append(
            chapterAt(QStringLiteral("第%1章 同名").arg(i), static_cast<qint64>(i) * 1000));
    }

    // 章节数并列时保留表内靠前的规则：表序即可信度（历史内置规则在前）
    const ChapterRule *best = ChapterRules::selectBest(byRule, 20000, nullptr);
    QVERIFY(best != nullptr);
    QCOMPARE(best->id, ChapterRules::rules().at(first).id);
}

void TestChapterRules::selectBestRejectsImplausible()
{
    QVector<QVector<NovelChapter>> byRule(ChapterRules::rules().size());
    const int index = ruleIndex(QStringLiteral("en_number_alone"));
    QVERIFY(index >= 0);

    // 相隔 5 字节的「纯数字行」：只可能是正文里的数据行，不是章节
    byRule[index].append(chapterAt(QStringLiteral("1"), 0));
    byRule[index].append(chapterAt(QStringLiteral("2"), 5));

    QString rejected;
    QVERIFY(ChapterRules::selectBest(byRule, 100000, &rejected) == nullptr);
    QCOMPARE(rejected, QStringLiteral("en_number_alone"));
}

void TestChapterRules::selectBestReportsRejectedRule()
{
    QVector<QVector<NovelChapter>> byRule(ChapterRules::rules().size());
    const int number = ruleIndex(QStringLiteral("en_number_alone"));
    const int good = ruleIndex(QStringLiteral("zh_di_zhang"));

    for (int i = 0; i < 50; ++i) {
        byRule[number].append(
            chapterAt(QStringLiteral("%1").arg(i), static_cast<qint64>(i) * 3)); // 太密
    }
    for (int i = 0; i < 5; ++i) {
        byRule[good].append(
            chapterAt(QStringLiteral("第%1章 标题%1").arg(i), static_cast<qint64>(i) * 2000));
    }

    QString rejected;
    const ChapterRule *best = ChapterRules::selectBest(byRule, 20000, &rejected);
    QVERIFY(best != nullptr);
    QCOMPARE(best->id, QStringLiteral("zh_di_zhang"));
    // 被否掉的是「候选最多但不可信」那条，日志靠它解释为什么没选更细的规则
    QCOMPARE(rejected, QStringLiteral("en_number_alone"));
}

void TestChapterRules::singleChapterIsNotAParsedIndex()
{
    QVector<NovelChapter> one{chapterAt(QStringLiteral("第1章"), 0)};
    QVERIFY(!ChapterRules::isPlausible(one, 100000));
    QVERIFY(!ChapterRules::isPlausible({}, 100000));
}

void TestChapterRules::offsetsMustIncreaseWithGap()
{
    const QVector<NovelChapter> ordered{
        chapterAt(QStringLiteral("第1章"), 0),
        chapterAt(QStringLiteral("第2章"), 1000),
    };
    QVERIFY(ChapterRules::isPlausible(ordered, 20000));

    // 顺序颠倒：说明规则命中顺序与文件顺序不一致（跨块拼错），不可信
    const QVector<NovelChapter> reversed{
        chapterAt(QStringLiteral("第2章"), 1000),
        chapterAt(QStringLiteral("第1章"), 0),
    };
    QVERIFY(!ChapterRules::isPlausible(reversed, 20000));

    // 相隔 1 字节：两行不可能是不同章节（行边界至少隔一个换行 + 内容）
    const QVector<NovelChapter> tooClose{
        chapterAt(QStringLiteral("第1章"), 0),
        chapterAt(QStringLiteral("第2章"), 1),
    };
    QVERIFY(!ChapterRules::isPlausible(tooClose, 20000));
}

void TestChapterRules::tooManyRepeatedTitlesRejected()
{
    QVector<NovelChapter> chapters;
    for (int i = 0; i < 10; ++i) {
        chapters.append(chapterAt(QStringLiteral("正文"), static_cast<qint64>(i) * 1000));
    }
    QVERIFY(!ChapterRules::isPlausible(chapters, 1000000));
}

void TestChapterRules::numberingHelpers()
{
    QVERIFY(ChapterRules::isNumberedHeading(QStringLiteral("第一章 初入宗门")));
    QVERIFY(ChapterRules::isNumberedHeading(QStringLiteral("第12节 惊变")));
    QVERIFY(ChapterRules::isNumberedHeading(QStringLiteral("Chapter 3")));
    QVERIFY(!ChapterRules::isNumberedHeading(QStringLiteral("楔子")));

    QVERIFY(ChapterRules::isOpeningHeading(QStringLiteral("楔子")));
    QVERIFY(ChapterRules::isOpeningHeading(QStringLiteral("尾声")));
    QVERIFY(ChapterRules::isOpeningHeading(QStringLiteral("Prologue")));
    QVERIFY(!ChapterRules::isOpeningHeading(QStringLiteral("第一章")));
}

void TestChapterRules::matcherAcceptsChineseHeading()
{
    ChapterMatcher matcher(TextCodec::Utf8);
    const QByteArray line = QStringLiteral("第一章 初入宗门").toUtf8();
    const auto hit = matcher.match(line.constData(), line.size());
    QVERIFY(hit.has_value());
    QCOMPARE(hit->title, QStringLiteral("第一章 初入宗门"));
    QCOMPARE(hit->ruleId, QStringLiteral("zh_di_zhang"));
}

void TestChapterRules::matcherSkipsIndentAndBom()
{
    ChapterMatcher matcher(TextCodec::Utf8);

    // 全角空格缩进是中文 txt 最常见的排版，不能因此「识别不出章节」
    const QByteArray indented = QStringLiteral("　　第一章 初入宗门").toUtf8();
    const auto hitIndent = matcher.match(indented.constData(), indented.size());
    QVERIFY(hitIndent.has_value());
    QCOMPARE(hitIndent->title, QStringLiteral("第一章 初入宗门"));

    // BOM 只在文件第一行出现；命中标题里不能带 U+FEFF
    QByteArray withBom = QByteArray::fromHex("EFBBBF");
    withBom += QStringLiteral("第二章 风起").toUtf8();
    const auto hitBom = matcher.match(withBom.constData(), withBom.size());
    QVERIFY(hitBom.has_value());
    QCOMPARE(hitBom->title, QStringLiteral("第二章 风起"));
}

void TestChapterRules::matcherRejectsBodyText()
{
    ChapterMatcher matcher(TextCodec::Utf8);

    const QByteArray prose = QStringLiteral("他翻到第一章，看了很久才合上书。").toUtf8();
    QVERIFY(!matcher.match(prose.constData(), prose.size()).has_value());

    // 标题过长（正文里提到「第x章」的整句）：规则的长度上限把它挡在外面
    const QByteArray longLine =
        QStringLiteral("第一章 的内容他反复读了三遍，仍旧觉得写得太冗长太啰嗦，索性跳过不看了，"
                       "心里想着作者到底有没有认真改稿")
            .toUtf8();
    QVERIFY(!matcher.match(longLine.constData(), longLine.size()).has_value());
}

void TestChapterRules::matcherAcceptsEnglishHeading()
{
    ChapterMatcher matcher(TextCodec::Utf8);
    const QByteArray line = QByteArrayLiteral("Chapter 12: The Return");
    const auto hit = matcher.match(line.constData(), line.size());
    QVERIFY(hit.has_value());
    QVERIFY(hit->title.startsWith(QStringLiteral("Chapter 12")));
}

void TestChapterRules::matcherAcceptsUtf16Heading()
{
    ChapterMatcher matcher(TextCodec::Utf16LE);
    const QByteArray line =
        TextCodec::encode(QStringLiteral("第三章 雪夜"), TextCodec::Utf16LE).data;
    const auto hit = matcher.match(line.constData(), line.size());
    QVERIFY(hit.has_value());
    QCOMPARE(hit->title, QStringLiteral("第三章 雪夜"));
}

void TestChapterRules::headSkipDropsContinuationBytes()
{
    // 「第」的 UTF-8 是三字节 E7 AC AC；从第二个字节开始切 = 落在续接字节上
    const QByteArray data = QStringLiteral("第一章").toUtf8();
    QCOMPARE(ChapterTextAlign::headSkip(data, TextCodec::Utf8), 0);
    QCOMPARE(ChapterTextAlign::headSkip(data.mid(1), TextCodec::Utf8), 2);
    QCOMPARE(ChapterTextAlign::headSkip(data.mid(2), TextCodec::Utf8), 1);

    // UTF-16：单独出现的低位代理说明高位落在前一块
    const QByteArray le = TextCodec::encode(QStringLiteral("\U0001F600"), TextCodec::Utf16LE).data;
    QCOMPARE(le.size(), 4);
    QCOMPARE(ChapterTextAlign::headSkip(le, TextCodec::Utf16LE), 0);
    QCOMPARE(ChapterTextAlign::headSkip(le.mid(2), TextCodec::Utf16LE), 2);
}

void TestChapterRules::tailDropIsSymmetric()
{
    const QByteArray data = QStringLiteral("第一章").toUtf8();
    QCOMPARE(ChapterTextAlign::tailDrop(data, TextCodec::Utf8), 0);
    QCOMPARE(ChapterTextAlign::tailDrop(data.left(1), TextCodec::Utf8), 1);
    QCOMPARE(ChapterTextAlign::tailDrop(data.left(2), TextCodec::Utf8), 2);

    const QByteArray le = TextCodec::encode(QStringLiteral("\U0001F600"), TextCodec::Utf16LE).data;
    QCOMPARE(ChapterTextAlign::tailDrop(le, TextCodec::Utf16LE), 0);
    // 只剩高位代理：配不上低位，整单元都要等下一块
    QCOMPARE(ChapterTextAlign::tailDrop(le.left(2), TextCodec::Utf16LE), 2);
    // 半个代码单元
    QCOMPARE(ChapterTextAlign::tailDrop(le.left(1), TextCodec::Utf16LE), 1);
}

void TestChapterRules::trimIncompleteUtf8TailKeepsWholeChars()
{
    const QByteArray data = QStringLiteral("中文").toUtf8(); // 6 字节，每字 3 字节
    QCOMPARE(ChapterTextAlign::trimIncompleteUtf8Tail(data), data);
    QCOMPARE(ChapterTextAlign::trimIncompleteUtf8Tail(data.left(5)), data.left(3));
    QCOMPARE(ChapterTextAlign::trimIncompleteUtf8Tail(data.left(4)), data.left(3));
}

void TestChapterRules::scannerKeepsAbsoluteOffsetsAcrossChunks()
{
    const QByteArray data = QStringLiteral("第一章 甲\n正文甲\n第二章 乙\n正文乙\n").toUtf8();

    QVector<QString> texts;
    const auto spans = scanLines(data, TextCodec::Utf8, 1, &texts);

    QCOMPARE(spans.size(), 4);
    QCOMPARE(texts.join(QLatin1Char('|')), QStringLiteral("第一章 甲|正文甲|第二章 乙|正文乙"));

    // 每一行的 [start, end) 必须能直接从原始字节里切回同样的文本（偏移零漂移）
    for (int i = 0; i < spans.size(); ++i) {
        QCOMPARE(
            QString::fromUtf8(data.mid(spans.at(i).first, spans.at(i).second - spans.at(i).first)),
            texts.at(i));
    }
    // 行尾不含 \n：否则偏移会逐行累积偏移 1 字节
    QCOMPARE(data.at(spans.first().second), '\n');
}

void TestChapterRules::scannerHandlesCrlf()
{
    const QByteArray data = QByteArrayLiteral("line1\r\nline2\r\n");
    QVector<QString> texts;
    const auto spans = scanLines(data, TextCodec::Utf8, 2, &texts);
    QCOMPARE(texts.join(QLatin1Char('|')), QStringLiteral("line1|line2"));
    QCOMPARE(spans.at(1).first, qint64(7));
}

void TestChapterRules::scannerHandlesUtf16OddChunks()
{
    const QString text = QStringLiteral("第一章 甲\n正文甲\n第二章 乙\n正文乙");
    const QByteArray data = TextCodec::encode(text, TextCodec::Utf16LE).data;

    // 3 字节一块：每块末尾都会剩半个代码单元，必须留到下一块拼接
    QVector<QString> texts;
    const auto spans = scanLines(data, TextCodec::Utf16LE, 3, &texts);
    QCOMPARE(texts.join(QLatin1Char('|')), QStringLiteral("第一章 甲|正文甲|第二章 乙|正文乙"));

    for (int i = 0; i < spans.size(); ++i) {
        const QByteArray slice = data.mid(static_cast<int>(spans.at(i).first),
                                          static_cast<int>(spans.at(i).second - spans.at(i).first));
        QCOMPARE(TextCodec::decodeAs(slice, TextCodec::Utf16LE).text, texts.at(i));
    }
}

void TestChapterRules::scannerFinishEmitsLastLineWithoutNewline()
{
    const QByteArray data = QStringLiteral("只有一行").toUtf8();
    QVector<QString> texts;
    const auto spans = scanLines(data, TextCodec::Utf8, 4, &texts);
    QCOMPARE(texts.join(QLatin1Char('|')), QStringLiteral("只有一行"));
    QCOMPARE(spans.first().second, qint64(data.size()));
}

QTEST_MAIN(TestChapterRules)
#include "tst_chapterrules.moc"
