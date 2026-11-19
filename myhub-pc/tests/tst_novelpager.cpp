// 行级分页（§5.1）：折行归 QTextLayout，切页归行高累加。
// 这里守的是四条底线：一个字都不能丢、一行都不能超出宽度、一页都不能超出高度、
// 段落一定能找回它在哪一页（翻页模式的进度就靠这条往返）。

#include "NovelPager.h"

#include <QFont>
#include <QTest>
#include <QTextLayout>
#include <QTextOption>

using myhub::NovelPager;

namespace {

constexpr int kFontSize = 17;
constexpr int kWidth = 400;
constexpr int kHeight = 600;

/// 两个全角空格：与 NovelPager 的首行缩进必须一致，否则「不丢字」的比对会假失败
QString indented(const QString &text)
{
    return text.isEmpty() ? text : QStringLiteral("\u3000\u3000") + text;
}

/// 造一段够长的中文正文（不带空格：换行点丢空格是排版惯例，别让它干扰「不丢字」的断言）
QString paragraphOf(int seed, int chars)
{
    static const QStringList words = {
        QStringLiteral("他站在门口，看了一会儿雨。"),
        QStringLiteral("屋檐下的水连成一条线，把台阶洗得发亮。"),
        QStringLiteral("远处有人推着自行车走过，车铃响了两声就停了。"),
        QStringLiteral("“今天大概不会晴了。”她说完，把伞递了过来。"),
        QStringLiteral("风从巷子深处灌进来，卷起地上的一层薄薄的尘土。"),
    };
    QString text;
    int i = seed;
    while (text.size() < chars) {
        text += words.at(i % words.size());
        ++i;
    }
    return text.left(chars);
}

/// 单独量一行的自然宽度（按 pager 的字体与折行策略铺开）
double naturalWidthOf(const QString &lineText, int pixelSize = kFontSize)
{
    QFont font;
    font.setPixelSize(pixelSize);
    QTextLayout layout(lineText, font);
    QTextOption option;
    option.setWrapMode(QTextOption::WrapAtWordBoundaryOrAnywhere);
    layout.setTextOption(option);
    layout.beginLayout();
    double width = 0;
    QTextLine line = layout.createLine();
    if (line.isValid()) {
        line.setLineWidth(1e6);
        width = line.naturalTextWidth();
    }
    layout.endLayout();
    return width;
}

} // namespace

class TestNovelPager : public QObject
{
    Q_OBJECT

private slots:
    void refusesToPaginateBeforeViewport();
    void keepsEveryCharacterInsideTheWidth();
    void neverExceedsPageHeight();
    void keepsParagraphToPageMappingMonotonic();
    void givesEachIllustrationItsOwnPage();
    void keepsEmptyChapterAsOnePage();
    void smallerFontFitsMoreLinesPerPage();
    void locatesPageByParagraphOffset();
    void reservesTitleBandOnFirstPage();
};

void TestNovelPager::refusesToPaginateBeforeViewport()
{
    NovelPager pager;
    pager.setText({QStringLiteral("正文")}, {});
    // 宽度未知时不产出「1px 宽」的假行：页数保持 0，等 setViewport 再来一次
    pager.relayout();
    QCOMPARE(pager.pageCount(), 0);
    QVERIFY(pager.dirty());
}

void TestNovelPager::keepsEveryCharacterInsideTheWidth()
{
    const QStringList paragraphs = {
        paragraphOf(0, 900),
        QStringLiteral("短的一段。"),
        QString(), // 空段落也要占一行
        paragraphOf(3, 1200),
    };

    NovelPager pager;
    pager.setText(paragraphs, {});
    pager.setViewport(kWidth, kHeight);
    pager.relayout();

    QVERIFY(!pager.dirty());
    QVERIFY(pager.pageCount() > 1);

    QString joined;
    for (int page = 0; page < pager.pageCount(); ++page) {
        const QStringList lines = pager.linesOf(page);
        QCOMPARE(lines.size(), pager.lineCountOf(page));
        for (const QString &line : lines) {
            QVERIFY2(
                naturalWidthOf(line) <= kWidth + 0.5,
                qPrintable(
                    QStringLiteral("行宽溢出：%1px → %2").arg(naturalWidthOf(line)).arg(line)));
            joined += line;
        }
    }

    QString expected;
    for (const QString &paragraph : paragraphs)
        expected += indented(paragraph);
    QCOMPARE(joined, expected);

    // 每个段落的第一行都带缩进（缩进必须是折行前的文本，才量得准）
    const QStringList firstPage = pager.linesOf(0);
    QVERIFY(!firstPage.isEmpty());
    QVERIFY(firstPage.first().startsWith(QStringLiteral("\u3000\u3000")));
}

void TestNovelPager::neverExceedsPageHeight()
{
    const QStringList paragraphs = {paragraphOf(1, 2000), paragraphOf(2, 400),
                                    paragraphOf(4, 1500)};

    NovelPager pager;
    pager.setText(paragraphs, {});
    pager.setViewport(kWidth, kHeight);
    pager.relayout();

    QVERIFY(pager.pageCount() > 1);
    QVERIFY(pager.lineHeight() > 0);
    for (int page = 0; page < pager.pageCount(); ++page) {
        QVERIFY2(pager.lineCountOf(page) > 0, "文字页不该是空的");
        QVERIFY(pager.lineCountOf(page) * pager.lineHeight() <= kHeight);
        // 页里至少要塞得下一行，不能出现「一页零行」
        QVERIFY(pager.lineCountOf(page) <= kHeight / pager.lineHeight());
    }
}

void TestNovelPager::keepsParagraphToPageMappingMonotonic()
{
    const QStringList paragraphs = {
        paragraphOf(0, 300), QStringLiteral("二。"), paragraphOf(2, 800),
        paragraphOf(3, 50),  QStringLiteral("五。"), paragraphOf(5, 1400),
    };

    NovelPager pager;
    pager.setText(paragraphs, {});
    pager.setViewport(kWidth, kHeight);
    pager.relayout();

    int previous = -1;
    for (int p = 0; p < paragraphs.size(); ++p) {
        const int page = pager.pageOfParagraph(p);
        QVERIFY2(page >= 0, qPrintable(QStringLiteral("段落 %1 没有落到任何页").arg(p)));
        QVERIFY(page >= previous); // 段落顺序不能被打乱
        previous = page;
        // 这一页的首段不能晚于 p：翻页上报进度的前提
        QVERIFY(pager.firstParagraphOf(page) <= p);
    }

    // 每页的首段不能倒退；等于是合法的 —— 一个长段落跨页时，
    // 后一页的首段就是同一个段落（这正是「页边界只落在行边界」的表现）
    QCOMPARE(pager.firstParagraphOf(0), 0);
    int last = -1;
    for (int page = 0; page < pager.pageCount(); ++page) {
        const int first = pager.firstParagraphOf(page);
        QVERIFY(first >= 0);
        QVERIFY(first >= last);
        last = first;
    }
}

void TestNovelPager::givesEachIllustrationItsOwnPage()
{
    const QStringList paragraphs = {
        QStringLiteral("图前。"),
        QStringLiteral("\u0001img\u0001OEBPS/img/a.png"),
        QStringLiteral("图后。"),
        QStringLiteral("\u0001img\u0001OEBPS/img/b.png"),
    };

    NovelPager pager;
    pager.setText(paragraphs, {1, 3});
    pager.setViewport(kWidth, kHeight);
    pager.relayout();

    QVERIFY(pager.pageCount() >= 4); // 两页文字 + 两页图（文字各占一页）

    int imagePages = 0;
    for (int page = 0; page < pager.pageCount(); ++page) {
        const int image = pager.imageParagraphOf(page);
        if (image < 0) {
            QVERIFY(pager.lineCountOf(page) > 0);
            continue;
        }
        ++imagePages;
        QVERIFY(image == 1 || image == 3);
        // 整页插图：这一页不能有文字行，否则 QML 会「图 + 字」叠着画
        QCOMPARE(pager.lineCountOf(page), 0);
        QVERIFY(pager.linesOf(page).isEmpty());
        QCOMPARE(pager.pageOfParagraph(image), page);
    }
    QCOMPARE(imagePages, 2);

    // 图后那一段必须另起一页，不能接着图的空白往下排
    const int afterFirstImage = pager.pageOfParagraph(1) + 1;
    QVERIFY(afterFirstImage < pager.pageCount());
    QCOMPARE(pager.firstParagraphOf(afterFirstImage), 2);
}

void TestNovelPager::keepsEmptyChapterAsOnePage()
{
    NovelPager pager;
    pager.setText({}, {});
    pager.setViewport(kWidth, kHeight);
    pager.relayout();

    // 空章也给一页：QML 不必为 0 页写特例，页码永远 ≥ 1
    QCOMPARE(pager.pageCount(), 1);
    QCOMPARE(pager.lineCountOf(0), 0);
    QVERIFY(pager.linesOf(0).isEmpty());
    QCOMPARE(pager.firstParagraphOf(0), -1);
}

void TestNovelPager::smallerFontFitsMoreLinesPerPage()
{
    const QStringList paragraphs = {paragraphOf(7, 3000)};

    NovelPager big;
    big.setText(paragraphs, {});
    big.setViewport(kWidth, kHeight);
    big.relayout();

    NovelPager small;
    small.setText(paragraphs, {});
    small.setTypography({}, 12, 1.6);
    small.setViewport(kWidth, kHeight);
    small.relayout();

    QVERIFY(small.lineHeight() < big.lineHeight());
    QVERIFY(small.lineCountOf(0) > big.lineCountOf(0));
    // 字小了，整章需要的页数变少
    QVERIFY(small.pageCount() < big.pageCount());
}

void TestNovelPager::locatesPageByParagraphOffset()
{
    // 一段话横跨好几页：这是「段内偏移」唯一能体现价值的地方
    const QString longText = paragraphOf(9, 3000);
    const QStringList paragraphs = {longText, QStringLiteral("下一段。")};

    NovelPager pager;
    pager.setText(paragraphs, {});
    pager.setViewport(kWidth, kHeight);
    pager.relayout();

    QVERIFY(pager.pageCount() >= 4);
    const int firstPage = pager.pageOfPosition(0, 0);
    const int lastPage = pager.pageOfPosition(0, static_cast<int>(longText.size()) - 1);
    QCOMPARE(firstPage, 0);
    QVERIFY2(lastPage > firstPage, "长段落没跨页，这个用例就证明不了什么");

    // 段内偏移越大页越靠后（不能回头）
    int previous = firstPage;
    for (int offset = 0; offset < longText.size(); offset += 97) {
        const int page = pager.pageOfPosition(0, offset);
        QVERIFY(page >= previous);
        previous = page;
    }
    QVERIFY(previous <= lastPage);
    QCOMPARE(pager.pageOfPosition(0, static_cast<int>(longText.size()) - 1), lastPage);

    // 缩进不属于原文：段首偏移 0 必须落在第一页，且换算不把缩进算进去
    int paragraph = -1;
    int offset = -1;
    pager.positionOfPage(firstPage, &paragraph, &offset);
    QCOMPARE(paragraph, 0);
    QCOMPARE(offset, 0);

    // 页 → 首行偏移 → 页：必须回到同一页（重排后的定位就靠这条往返）
    for (int page = 0; page < pager.pageCount(); ++page) {
        if (pager.imageParagraphOf(page) >= 0)
            continue;
        int p = -1;
        int o = -1;
        pager.positionOfPage(page, &p, &o);
        QVERIFY(p >= 0);
        QVERIFY(o >= 0);
        QCOMPARE(pager.pageOfPosition(p, o), page);
    }

    // 越界偏移夹到段内，不能算出 -1；不存在的段落才返回 -1
    QVERIFY(pager.pageOfPosition(0, longText.size() + 500) >= 0);
    QVERIFY(pager.pageOfPosition(0, -10) >= 0);
    QCOMPARE(pager.pageOfPosition(99, 0), -1);
}

void TestNovelPager::reservesTitleBandOnFirstPage()
{
    QStringList paragraphs{QStringLiteral("第一章 起风了")};
    for (int i = 0; i < 40; ++i)
        paragraphs.append(paragraphOf(i, 200));

    NovelPager pager;
    pager.setTitleParagraph(0);
    pager.setText(paragraphs, {});
    pager.setViewport(kWidth, kHeight);
    pager.relayout();

    QVERIFY(pager.pageCount() >= 3);
    QCOMPARE(pager.titlePage(), 0);
    QCOMPARE(pager.titleReserve(), pager.lineHeight() * 2);

    // 章名不进正文：第一页的每一行都不该是它
    for (const QString &line : pager.linesOf(0))
        QVERIFY2(!line.contains(QStringLiteral("起风了")), qPrintable(line));

    // 但「章首」这个位置仍然落在第一页（锚点不会被当成没参与排版）
    QCOMPARE(pager.pageOfParagraph(0), 0);
    QCOMPARE(pager.pageOfPosition(0, 0), 0);
    int paragraph = -1;
    int offset = -1;
    pager.positionOfPage(0, &paragraph, &offset);
    QCOMPARE(paragraph, 1);

    // 预留是真扣掉的：第一页比后面少两行
    QCOMPARE(pager.lineCountOf(0), pager.lineCountOf(1) - 2);

    // 只有 0 段能当章名，别的下标一概不认（认错等于凭空藏掉一段正文）
    NovelPager other;
    other.setTitleParagraph(1);
    other.setText(paragraphs, {});
    other.setViewport(kWidth, kHeight);
    other.relayout();
    QCOMPARE(other.titleReserve(), 0);
    QCOMPARE(other.titlePage(), -1);
    QCOMPARE(other.lineCountOf(0), pager.lineCountOf(1));
}

QTEST_MAIN(TestNovelPager)
#include "tst_novelpager.moc"
