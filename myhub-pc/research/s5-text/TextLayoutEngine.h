#pragma once

#include <QFont>
#include <QString>
#include <QStringList>
#include <QVector>

// 排版配置：只影响「怎么显示」，绝不允许影响锚点（锚点里不含页码/行号）
struct TypoConfig {
    int fontSize = 18;
    qreal lineSpacing = 1.6;
    int viewportWidth = 760;
    int viewportHeight = 980;
    int padding = 24;
    int paragraphSpacing = 8;
    QString fontFamily = QStringLiteral("Microsoft YaHei");
};

// 一行：段落序 + 段内 UTF-16 区间（这是「不截断行」可被逐字节验证的关键）
struct LineBox {
    int paragraph = -1;
    int start = 0;
    int length = 0;
    int page = 0;
    int indexInPage = 0;
    qreal width = 0;
};

struct PageBox {
    int lineBegin = 0;
    int lineCount = 0;
    int paragraphBegin = 0;
    int paragraphEnd = 0;
    qreal usedHeight = 0;
};

// 与需求文档 §2.3「锚点」结构对齐：段序 + 段内偏移（UTF-16）+ 片段兜底。
// page/line 是换算产物，只用于本次会话定位，不参与持久化。
struct Anchor {
    int paragraph = 0;
    int offset = 0;          // 规范化为该行行首的段内偏移
    QString snippet;         // 重定位兜底
    int page = 0;
    int lineIndex = 0;       // 全局行号
    int indexInPage = 0;
};

class TextLayoutEngine {
public:
    void setParagraphs(const QStringList &paras);
    void setTypo(const TypoConfig &cfg);
    const TypoConfig &typo() const { return m_cfg; }

    // 全量重排：按行边界切页（不截断行）
    void relayout();
    qint64 lastLayoutMs() const { return m_lastMs; }

    int pageCount() const { return int(m_pages.size()); }
    int lineCount() const { return int(m_lines.size()); }
    const QVector<LineBox> &lines() const { return m_lines; }
    const QVector<PageBox> &pages() const { return m_pages; }
    const QStringList &paragraphs() const { return m_paras; }

    // 单段落最坏情况的独立耗时（整章无换行时用）
    static qint64 layoutSingleParagraphMs(const QString &text, const TypoConfig &cfg,
                                          int *lineCount);

    // ---- 锚点换算 ----
    // 正向：段内偏移 -> 该偏移所在行（含页码/页内行号）
    bool anchorAt(int paragraph, int offset, Anchor *out) const;
    // 反向：全局行号 -> 段序 + 行首段内偏移
    bool paragraphOffsetAtLine(int lineIndex, int *paragraph, int *offset) const;
    // 定位：锚点直接给出页码（一步定位），并校验该页确实包含此偏移
    bool pageForAnchor(const Anchor &a, int *page) const;

    QString lineText(int lineIndex) const;
    static QString snippetAt(const QString &text, int offset, int takeUnits = 12);

    int paraLineBegin(int paragraph) const
    {
        return (paragraph >= 0 && paragraph < m_paraLineBegin.size())
                   ? m_paraLineBegin.at(paragraph) : -1;
    }
    int paraLineCount(int paragraph) const
    {
        return (paragraph >= 0 && paragraph < m_paraLineCount.size())
                   ? m_paraLineCount.at(paragraph) : 0;
    }
    qreal lineHeightFor(const TypoConfig &cfg) const;

private:
    int lineIndexAt(int paragraph, int offset) const;   // 二分
    QStringList m_paras;
    TypoConfig m_cfg;
    QVector<LineBox> m_lines;
    QVector<PageBox> m_pages;
    QVector<int> m_paraLineBegin;
    QVector<int> m_paraLineCount;
    qint64 m_lastMs = 0;
};
