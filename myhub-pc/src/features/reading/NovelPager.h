#pragma once

#include <QSet>
#include <QString>
#include <QStringList>
#include <QVector>

namespace myhub {

/**
 * 行级分页（§5.1「翻页模式」/ §4.3）。
 *
 * 分工：`QTextLayout` 只负责**折行**（一行能放多少字、在哪儿断开），
 * 页码由这里按行高自己累加切分 —— 于是**页边界只能落在行边界上**，
 * 不可能出现「半个字被切到下一页」，也不需要给 QML 做任何二次测量。
 *
 * 输出的页面内容交给 QML 用「固定行高的单块 Text」画：
 * 行由这里断开（`Text.NoWrap`），行距由 `lineHeight()` 指定（`Text.FixedHeight`），
 * 所以 C++ 量到的行距/行数与屏幕上看到的一模一样，不存在「量一套、画一套」的漂移。
 *
 * 两条纪律：
 *   · **页码与行号不进持久化** —— 换字号/窗口宽度会重排（预研实测 612 个锚点里
 *     1193 次落到不同页），进度只认 `{章号, 段落下标}`，页码每次现算；
 *   · 分页是纯函数式重算（`relayout()` 一次 10 万字约 34ms，见 research/README.md S5），
 *     排版参数与视口变化时整体重排，不做增量。
 */
class NovelPager
{
public:
    /// 一页：文字页 = 若干行；插图页 = 单独一张图（行区间为空）
    struct Page
    {
        int lineBegin = 0;
        int lineCount = 0;
        /// ≥0 表示整页插图，值是段落下标；-1 是文字页
        int imageParagraph = -1;
    };

    /// 一行：段落下标 + 段内 UTF-16 区间（`QString::mid` 直接切）
    struct Line
    {
        int paragraph = 0;
        int start = 0;
        int length = 0;
    };

    /// 段落与插图集合（插图段落按「整页插图」处理，不参与折行）
    void setText(const QStringList &paragraphs, const QSet<int> &imageParagraphs);
    /**
     * 章名段落（只认第 0 段；-1 = 这一章没有可识别的章名段）。
     *
     * 章名由版式单独放大加粗画在「标题带」上，正文里不再重复折行 ——
     * epub 的 `<h1>` 本来就落在第 0 段，不摘掉的话页眉与正文各出现一次。
     * 分页器负责为标题带**预留两行高**（`titleReserve()`），QML 只按这个高度摆文字。
     */
    void setTitleParagraph(int paragraph);
    /// 正文字体族名列表 + 像素字号 + 行距倍数（与 QML 侧 `font.family/pixelSize` 同源）
    void setTypography(const QStringList &fontFamilies, int pixelSize, double lineSpacing);
    /// 正文可视区尺寸（已扣掉页眉、页脚与内边距）
    void setViewport(int width, int height);

    bool dirty() const { return m_dirty; }
    /// 全量重排；参数没变时是空转
    void relayout();

    int pageCount() const { return static_cast<int>(m_pages.size()); }
    /// 单行行距（px）：QML 用 `lineHeightMode: Text.FixedHeight` 对齐
    int lineHeight() const { return m_lineHeight; }

    QStringList linesOf(int page) const;
    int lineCountOf(int page) const;
    /// 插图页的段落下标；-1 = 文字页
    int imageParagraphOf(int page) const;
    /// 这一页从哪一段开始（空页返回 -1）：翻页时用它上报进度
    int firstParagraphOf(int page) const;
    /// 段落 → 页码；越界或未参与排版返回 -1
    int pageOfParagraph(int paragraph) const;
    /**
     * 段落内字符偏移 → 页码（**原始文案坐标**，不含首行缩进）。
     *
     * 长段落会跨好几页，只记段落下标的话，停在第 3 页也会被拉回第 1 页；
     * 有了段内偏移，重排（改字号/窗口宽度）后仍能落回读到的那个位置。
     * 找不到（段落未参与排版）返回 -1，调用方退回 `pageOfParagraph()`。
     */
    int pageOfPosition(int paragraph, int offset) const;
    /// 页码 → 该页首行的 `(段落, 段内偏移)`；插图页偏移为 0，空页段落为 -1
    void positionOfPage(int page, int *paragraph, int *offset) const;

    /// 标题带落在哪一页（-1 = 这一章没有标题带）
    int titlePage() const { return m_titlePage; }
    /// 标题带占用的高度（px）：本章首个文字页顶部预留这么多
    int titleReserve() const { return m_titleReserve; }

private:
    void markDirty();
    /// 行号 → 页码；越界返回 -1
    int pageOfLine(int lineIndex) const;

    QStringList m_paragraphs;
    /// 缩进后的正文副本：分页与取行都基于它，保证「量到的字」与「画出来的字」同一份
    QStringList m_indented;
    QSet<int> m_imageParagraphs;
    int m_titleParagraph = -1;
    QVector<Line> m_lines;
    QVector<Page> m_pages;
    int m_titlePage = -1;
    int m_titleReserve = 0;
    /// 段落 → 页码（-1 = 未参与排版）
    QVector<int> m_paraPage;

    QStringList m_families;
    int m_pixelSize = 17;
    double m_lineSpacing = 1.6;
    int m_width = 0;
    int m_height = 0;
    int m_lineHeight = 0;
    bool m_dirty = true;
};

} // namespace myhub
