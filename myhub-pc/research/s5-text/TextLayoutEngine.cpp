#include "TextLayoutEngine.h"

#include "TextCorpus.h"

#include <QElapsedTimer>
#include <QFontMetricsF>
#include <QTextLayout>
#include <QTextOption>

#include <cmath>

void TextLayoutEngine::setParagraphs(const QStringList &paras)
{
    m_paras = paras;
}

void TextLayoutEngine::setTypo(const TypoConfig &cfg)
{
    m_cfg = cfg;
}

void TextLayoutEngine::relayout()
{
    QElapsedTimer timer;
    timer.start();

    m_lines.clear();
    m_pages.clear();
    m_paraLineBegin.assign(m_paras.size(), 0);
    m_paraLineCount.assign(m_paras.size(), 0);

    QFont font(m_cfg.fontFamily);
    font.setPixelSize(m_cfg.fontSize);
    const QFontMetricsF fm(font);
    const qreal lineHeight = std::ceil(fm.height() * m_cfg.lineSpacing);
    const qreal availWidth = qMax(1.0, qreal(m_cfg.viewportWidth - 2 * m_cfg.padding));
    const qreal pageHeight = qMax(1.0, qreal(m_cfg.viewportHeight - 2 * m_cfg.padding));

    qreal pageUsed = 0;

    auto startPage = [&](int lineBegin, int paragraph) {
        PageBox p;
        p.lineBegin = lineBegin;
        p.lineCount = 0;
        p.paragraphBegin = paragraph;
        p.paragraphEnd = paragraph;
        p.usedHeight = 0;
        m_pages << p;
        pageUsed = 0;
    };

    // 段间距不跨页：它只在新段落的第一行之前「消费」一次；
    // 如果这一行正好要换页，间距就地丢弃（页面顶部的段间距是视觉噪声）。
    bool pendingSpacing = false;

    // 只有「整行放不下」才换页 —— 这就是「按行边界切页、不截断行」的实现保证。
    // 预算必须把待消费的段间距一起算进去，否则会溢出页高（首版就栽在这）。
    auto appendLine = [&](int paragraph, int start, int length, qreal width) {
        const qreal spacing = pendingSpacing ? qreal(m_cfg.paragraphSpacing) : 0.0;
        if (m_pages.isEmpty() || pageUsed + spacing + lineHeight > pageHeight + 0.001) {
            startPage(int(m_lines.size()), paragraph);
        } else if (spacing > 0) {
            m_pages.last().usedHeight += spacing;
            pageUsed += spacing;
        }
        pendingSpacing = false;

        LineBox box;
        box.paragraph = paragraph;
        box.start = start;
        box.length = length;
        box.page = int(m_pages.size()) - 1;
        box.indexInPage = m_pages.last().lineCount;
        box.width = width;
        m_lines << box;

        PageBox &page = m_pages.last();
        page.lineCount++;
        page.paragraphEnd = paragraph;
        page.usedHeight += lineHeight;
        pageUsed += lineHeight;
    };

    for (int pi = 0; pi < m_paras.size(); ++pi) {
        const QString &para = m_paras.at(pi);
        m_paraLineBegin[pi] = int(m_lines.size());

        QTextLayout layout(para, font);
        QTextOption opt;
        opt.setWrapMode(QTextOption::WrapAtWordBoundaryOrAnywhere);
        layout.setTextOption(opt);
        layout.beginLayout();

        bool produced = false;
        while (true) {
            QTextLine line = layout.createLine();
            if (!line.isValid()) break;
            line.setLineWidth(availWidth);
            line.setPosition(QPointF(0, 0));
            produced = true;
            appendLine(pi, line.textStart(), line.textLength(), line.naturalTextWidth());
        }
        layout.endLayout();

        if (!produced) {
            // 空段落也要占一行，否则分页与锚点换算会错位
            appendLine(pi, 0, 0, 0);
        }

        m_paraLineCount[pi] = int(m_lines.size()) - m_paraLineBegin[pi];
        pendingSpacing = true;
    }

    m_lastMs = timer.elapsed();
}

qint64 TextLayoutEngine::layoutSingleParagraphMs(const QString &text, const TypoConfig &cfg,
                                                 int *lineCount)
{
    QElapsedTimer timer;
    timer.start();

    QFont font(cfg.fontFamily);
    font.setPixelSize(cfg.fontSize);
    const QFontMetricsF fm(font);
    const qreal lineHeight = std::ceil(fm.height() * cfg.lineSpacing);
    const qreal availWidth = qMax(1.0, qreal(cfg.viewportWidth - 2 * cfg.padding));

    QTextLayout layout(text, font);
    QTextOption opt;
    opt.setWrapMode(QTextOption::WrapAtWordBoundaryOrAnywhere);
    layout.setTextOption(opt);
    layout.beginLayout();
    int n = 0;
    qreal used = 0;
    while (true) {
        QTextLine line = layout.createLine();
        if (!line.isValid()) break;
        line.setLineWidth(availWidth);
        line.setPosition(QPointF(0, 0));
        ++n;
        used += lineHeight;
    }
    layout.endLayout();

    if (lineCount) *lineCount = n;
    Q_UNUSED(used);
    return timer.elapsed();
}

int TextLayoutEngine::lineIndexAt(int paragraph, int offset) const
{
    if (paragraph < 0 || paragraph >= m_paraLineBegin.size()) return -1;
    const int begin = m_paraLineBegin.at(paragraph);
    const int count = m_paraLineCount.at(paragraph);
    if (count <= 0) return -1;

    int lo = 0, hi = count - 1, best = 0;
    while (lo <= hi) {
        const int mid = (lo + hi) / 2;
        const LineBox &box = m_lines.at(begin + mid);
        if (box.start <= offset) {
            best = mid;
            lo = mid + 1;
        } else {
            hi = mid - 1;
        }
    }
    return begin + best;
}

bool TextLayoutEngine::anchorAt(int paragraph, int offset, Anchor *out) const
{
    if (!out) return false;
    if (paragraph < 0 || paragraph >= m_paras.size()) return false;

    const QString &para = m_paras.at(paragraph);
    int off = qBound(0, offset, int(para.size()));

    // 代理对安全：落在代理对中间时归一化到该字符起点
    if (off > 0 && off < para.size() && TextCorpus::splitsSurrogatePair(para, off))
        --off;

    const int li = lineIndexAt(paragraph, off);
    if (li < 0) return false;

    const LineBox &box = m_lines.at(li);
    out->paragraph = paragraph;
    out->offset = box.start;               // 规范化为行首偏移
    out->page = box.page;
    out->lineIndex = li;
    out->indexInPage = box.indexInPage;
    out->snippet = snippetAt(para, box.start);
    return true;
}

bool TextLayoutEngine::paragraphOffsetAtLine(int lineIndex, int *paragraph, int *offset) const
{
    if (lineIndex < 0 || lineIndex >= m_lines.size()) return false;
    const LineBox &box = m_lines.at(lineIndex);
    if (paragraph) *paragraph = box.paragraph;
    if (offset) *offset = box.start;
    return true;
}

bool TextLayoutEngine::pageForAnchor(const Anchor &a, int *page) const
{
    if (a.lineIndex < 0 || a.lineIndex >= m_lines.size()) return false;
    if (a.page < 0 || a.page >= m_pages.size()) return false;

    // 一步定位：锚点直接给出页码，且该页的行区间必须真的包含这一行
    const PageBox &p = m_pages.at(a.page);
    if (a.lineIndex < p.lineBegin || a.lineIndex >= p.lineBegin + p.lineCount)
        return false;
    if (page) *page = a.page;
    return true;
}

QString TextLayoutEngine::lineText(int lineIndex) const
{
    if (lineIndex < 0 || lineIndex >= m_lines.size()) return QString();
    const LineBox &box = m_lines.at(lineIndex);
    if (box.paragraph < 0 || box.paragraph >= m_paras.size()) return QString();
    return m_paras.at(box.paragraph).mid(box.start, box.length);
}

qreal TextLayoutEngine::lineHeightFor(const TypoConfig &cfg) const
{
    QFont font(cfg.fontFamily);
    font.setPixelSize(cfg.fontSize);
    const QFontMetricsF fm(font);
    return std::ceil(fm.height() * cfg.lineSpacing);
}

QString TextLayoutEngine::snippetAt(const QString &text, int offset, int takeUnits)
{
    if (offset < 0 || offset >= text.size()) return QString();
    QString s = text.mid(offset, takeUnits);
    if (!s.isEmpty() && s.at(s.size() - 1).isHighSurrogate())
        s.chop(1);                          // 片段不切断代理对
    return s;
}
