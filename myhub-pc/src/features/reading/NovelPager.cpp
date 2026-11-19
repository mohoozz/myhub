#include "NovelPager.h"

#include <QFont>
#include <QFontMetricsF>
#include <QTextLayout>
#include <QTextLine>
#include <QTextOption>

#include <cmath>

namespace myhub {

namespace {

/// 首行缩进两个全角空格：翻页模式不做段间距（屏幕滚动那套在纸上显得松散），
/// 缩进必须在**折行之前**加进去，否则量出来的行宽与画出来的不是同一份文本
QString indentOf()
{
    return QStringLiteral("\u3000\u3000");
}

/// 再扣 2px：QML 与 QTextLayout 对同一串字的宽度可能差一丝，宁可提前折一行也不要截掉半个字
constexpr qreal kWidthSlack = 2.0;

/// 首行缩进的宽度（`indentOf()` 是两个字）
constexpr int kIndentLength = 2;

} // namespace

void NovelPager::setText(const QStringList &paragraphs, const QSet<int> &imageParagraphs)
{
    // 同一章重复推（改字号 → 视口补偿 → 再推一次）就不要再折一遍：
    // 10 万字整章重排约 34ms，白做一次就是一次可见的掉帧
    if (m_paragraphs == paragraphs && m_imageParagraphs == imageParagraphs) {
        return;
    }

    m_paragraphs = paragraphs;
    m_indented.clear();
    m_indented.reserve(paragraphs.size());
    for (int i = 0; i < paragraphs.size(); ++i) {
        if (imageParagraphs.contains(i)) {
            // 插图段落不参与折行（QML 会把它画成整页图），但下标空间必须保留
            m_indented.append(QString());
            continue;
        }
        QString text = paragraphs.at(i);
        // 段落是「一行文本」的契约，真混进换行就按空格摊平，别让 QTextLayout 只排第一行
        text.replace(QLatin1Char('\n'), QLatin1Char(' '));
        text.replace(QLatin1Char('\r'), QLatin1Char(' '));
        m_indented.append(text.isEmpty() ? text : indentOf() + text);
    }

    m_imageParagraphs = imageParagraphs;
    markDirty();
}

void NovelPager::setTypography(const QStringList &fontFamilies, int pixelSize, double lineSpacing)
{
    const int size = qMax(1, pixelSize);
    const double spacing = lineSpacing > 0 ? lineSpacing : 1.0;
    if (m_families == fontFamilies && m_pixelSize == size && qFuzzyCompare(m_lineSpacing, spacing))
        return;
    m_families = fontFamilies;
    m_pixelSize = size;
    m_lineSpacing = spacing;
    markDirty();
}

void NovelPager::setTitleParagraph(int paragraph)
{
    // 只认第 0 段：章名永远在章首，放行别的下标等于把正文某一段藏起来
    const int title = paragraph == 0 ? 0 : -1;
    if (m_titleParagraph == title)
        return;
    m_titleParagraph = title;
    markDirty();
}

void NovelPager::setViewport(int width, int height)
{
    if (m_width == width && m_height == height)
        return;
    m_width = width;
    m_height = height;
    markDirty();
}

void NovelPager::markDirty()
{
    m_dirty = true;
}

void NovelPager::relayout()
{
    if (!m_dirty)
        return;

    m_lines.clear();
    m_pages.clear();
    m_titlePage = -1;
    m_titleReserve = 0;
    m_paraPage = QVector<int>(m_paragraphs.size(), -1);

    // 视口还没量出来（窗口刚开始布局）：保持 dirty，等 setViewport 再来一次，
    // 不要在这里产出一堆「宽度 1px」的假行
    if (m_width <= 0 || m_height <= 0)
        return;

    m_dirty = false;

    QFont font;
    if (!m_families.isEmpty())
        font.setFamilies(m_families);
    font.setPixelSize(qMax(1, m_pixelSize));
    const QFontMetricsF metrics(font);
    m_lineHeight = qMax(1, static_cast<int>(std::ceil(metrics.height() * m_lineSpacing)));

    const qreal availWidth = qMax(1.0, static_cast<qreal>(m_width) - kWidthSlack);
    const int availHeight = qMax(m_lineHeight, m_height);

    // 章名段不折行进页面，改由「标题带」占两行高单独画：不摘掉的话 epub 的 <h1>
    // 会在页眉和正文里各出现一次（同一个书名读两遍）
    const bool hasTitle =
        m_titleParagraph == 0 && !m_paragraphs.isEmpty() && !m_imageParagraphs.contains(0);
    if (hasTitle)
        m_titleReserve = m_lineHeight * 2;

    int pageUsed = 0;
    bool pageOpen = false;

    auto openPage = [&](int imageParagraph) {
        Page page;
        page.lineBegin = static_cast<int>(m_lines.size());
        page.imageParagraph = imageParagraph;
        m_pages.append(page);
        pageUsed = 0;
        // 标题带只在本章第一个**文字页**上预留；章首是整页插图时留给它后面的那一页
        if (imageParagraph < 0 && m_titlePage < 0 && m_titleReserve > 0) {
            m_titlePage = static_cast<int>(m_pages.size()) - 1;
            pageUsed = m_titleReserve;
        }
        // 插图页不接受后续行：这张图独占一页
        pageOpen = imageParagraph < 0;
    };

    auto appendLine = [&](int paragraph, int start, int length) {
        if (!pageOpen || pageUsed + m_lineHeight > availHeight)
            openPage(-1);
        Line line;
        line.paragraph = paragraph;
        line.start = start;
        line.length = length;
        m_lines.append(line);
        pageUsed += m_lineHeight;
        Page &page = m_pages.last();
        ++page.lineCount;
        m_paraPage[paragraph] = static_cast<int>(m_pages.size()) - 1;
    };

    for (int pi = 0; pi < m_paragraphs.size(); ++pi) {
        if (m_imageParagraphs.contains(pi)) {
            openPage(pi);
            m_paraPage[pi] = static_cast<int>(m_pages.size()) - 1;
            pageOpen = false;
            continue;
        }

        // 章名段已经由标题带承担：不排进正文，但它的下标空间照旧保留
        if (hasTitle && pi == m_titleParagraph)
            continue;

        const QString &text = m_indented.at(pi);
        QTextLayout layout(text, font);
        QTextOption option;
        // 与 QML `wrapMode: Text.Wrap` 同策略：优先词边界，长串无处可断时按字符断
        option.setWrapMode(QTextOption::WrapAtWordBoundaryOrAnywhere);
        layout.setTextOption(option);
        layout.beginLayout();

        bool produced = false;
        while (true) {
            QTextLine line = layout.createLine();
            if (!line.isValid())
                break;
            line.setLineWidth(availWidth);
            line.setPosition(QPointF(0, 0));
            appendLine(pi, line.textStart(), line.textLength());
            produced = true;
        }
        layout.endLayout();

        if (!produced) {
            // 空段落也占一行：不占的话「翻页时的首段」和页码都会整体错位
            appendLine(pi, 0, 0);
        }
    }

    if (m_pages.isEmpty())
        openPage(-1); // 空章也给一页，QML 不必为 0 页写特例

    if (hasTitle && m_titlePage >= 0) {
        // 章名段查页就落在标题带那一页：锚点停在章首时不会被当成「没参与排版」
        m_paraPage[0] = m_titlePage;
    }
}

int NovelPager::lineCountOf(int page) const
{
    if (page < 0 || page >= m_pages.size())
        return 0;
    return m_pages.at(page).lineCount;
}

int NovelPager::imageParagraphOf(int page) const
{
    if (page < 0 || page >= m_pages.size())
        return -1;
    return m_pages.at(page).imageParagraph;
}

int NovelPager::firstParagraphOf(int page) const
{
    if (page < 0 || page >= m_pages.size())
        return -1;
    const Page &p = m_pages.at(page);
    if (p.imageParagraph >= 0)
        return p.imageParagraph;
    if (p.lineCount <= 0 || p.lineBegin >= m_lines.size())
        return -1;
    return m_lines.at(p.lineBegin).paragraph;
}

int NovelPager::pageOfParagraph(int paragraph) const
{
    if (paragraph < 0 || paragraph >= m_paraPage.size())
        return -1;
    return m_paraPage.at(paragraph);
}

int NovelPager::pageOfLine(int lineIndex) const
{
    if (lineIndex < 0 || lineIndex >= m_lines.size())
        return -1;
    // 页按行号升序、且文字页的行区间连续：最后一个 `lineBegin <= 行号` 的页就是它。
    // 插图页的 lineBegin 与后一页相同（不占行），二分自然取到后者，不必特判
    int lo = 0;
    int hi = static_cast<int>(m_pages.size()) - 1;
    int best = -1;
    while (lo <= hi) {
        const int mid = lo + (hi - lo) / 2;
        if (m_pages.at(mid).lineBegin <= lineIndex) {
            best = mid;
            lo = mid + 1;
        } else {
            hi = mid - 1;
        }
    }
    if (best < 0) {
        return -1;
    }
    const Page &page = m_pages.at(best);
    if (page.imageParagraph >= 0 || page.lineCount <= 0
        || lineIndex >= page.lineBegin + page.lineCount) {
        return -1; // 落在插图页的缝里：让调用方退回段落下标
    }
    return best;
}

int NovelPager::pageOfPosition(int paragraph, int offset) const
{
    if (paragraph < 0 || paragraph >= m_paragraphs.size())
        return -1;

    // 章名段没有自己的行，它就画在标题带那一页上
    if (paragraph == m_titleParagraph && m_titlePage >= 0)
        return m_titlePage;
    if (m_imageParagraphs.contains(paragraph))
        return pageOfParagraph(paragraph);

    // 缩进只加在非空段落上：先换算到 m_indented 的坐标系，再和行首偏移比较
    const QString &raw = m_paragraphs.at(paragraph);
    const int shift = m_indented.value(paragraph).size() > raw.size() ? kIndentLength : 0;
    const int want = qMax(0, qMin(offset, static_cast<int>(raw.size()))) + shift;

    // 行表按 (段落, 行首) 升序：二分找「起点不超过 want 的最后一行」，就是落点所在行
    int lo = 0;
    int hi = static_cast<int>(m_lines.size()) - 1;
    int best = -1;
    while (lo <= hi) {
        const int mid = lo + (hi - lo) / 2;
        const Line &line = m_lines.at(mid);
        if (line.paragraph < paragraph || (line.paragraph == paragraph && line.start <= want)) {
            best = mid;
            lo = mid + 1;
        } else {
            hi = mid - 1;
        }
    }
    if (best >= 0 && m_lines.at(best).paragraph == paragraph) {
        const int page = pageOfLine(best);
        if (page >= 0) {
            return page;
        }
    }
    // 空段落、或只排出一行的极端情况：段落下标至少能给出它所在的那一页
    return pageOfParagraph(paragraph);
}

void NovelPager::positionOfPage(int page, int *paragraph, int *offset) const
{
    if (paragraph != nullptr) {
        *paragraph = -1;
    }
    if (offset != nullptr) {
        *offset = 0;
    }
    if (page < 0 || page >= m_pages.size()) {
        return;
    }

    const Page &p = m_pages.at(page);
    if (p.imageParagraph >= 0) {
        if (paragraph != nullptr) {
            *paragraph = p.imageParagraph;
        }
        return;
    }
    if (p.lineCount <= 0 || p.lineBegin >= m_lines.size()) {
        return;
    }

    const Line &line = m_lines.at(p.lineBegin);
    const QString &raw = m_paragraphs.value(line.paragraph);
    const int shift = m_indented.value(line.paragraph).size() > raw.size() ? kIndentLength : 0;
    if (paragraph != nullptr) {
        *paragraph = line.paragraph;
    }
    if (offset != nullptr) {
        // 缩进不是原文的一部分：报出去的偏移必须能被 pageOfPosition() 原样吃回去
        *offset = qMax(0, line.start - shift);
    }
}

QStringList NovelPager::linesOf(int page) const
{
    QStringList out;
    if (page < 0 || page >= m_pages.size())
        return out;

    const Page &p = m_pages.at(page);
    out.reserve(p.lineCount);
    for (int i = 0; i < p.lineCount; ++i) {
        const Line &line = m_lines.at(p.lineBegin + i);
        out.append(m_indented.at(line.paragraph).mid(line.start, line.length));
    }
    return out;
}

} // namespace myhub
