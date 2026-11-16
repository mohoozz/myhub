#pragma once

#include "core/novel/NovelIndex.h"
#include "core/storage/StorageError.h"
#include "core/stream/RangeSource.h"

#include <QByteArray>
#include <QString>
#include <QStringList>
#include <QVector>

#include <functional>

namespace myhub {

/// 正文的一行。带**绝对字节偏移**：锚点、进度、书签都用它，不用字符下标
struct TxtLine
{
    QString text;
    qint64 start = 0; ///< 行首字节偏移
    qint64 end = 0;   ///< 行尾字节偏移（不含换行）
};

struct TxtChapterText
{
    QString title;
    TextCodec::Encoding encoding = TextCodec::Unknown;
    QVector<TxtLine> lines;
    qint64 start = 0; ///< 章节起始字节偏移
    qint64 end = 0;   ///< 章节结束字节偏移（不含）
    /// 正文从第几行开始：首行就是章名时不重复显示（0 或 1）
    int firstBodyLine = 0;
    /// 超过单章上限被截断（只读了前 maxBytes）
    bool truncated = false;

    bool isEmpty() const { return lines.isEmpty(); }
    /// 正文纯文本（不含章名行），主要用于复制/搜索/测试
    QString bodyText() const;

    /// 正文段落数（不含章名行）
    int paragraphCount() const;
    /// 正文段落文本，阅读器直接按段渲染（一段一个 item，ListView 可回收）
    QStringList paragraphs() const;

    /**
     * 字节偏移 → 段落下标（0 起，段落 = 正文行）。
     *
     * 锚点按需求（§5.1 PC-203）存**全局字节偏移**，但界面滚动只认段落序号。
     * 换算是本类的职责：两边的单位（字节 / 段落）都来自同一张行表，
     * 分开算必然会因为首行去重、空行裁剪而错位。
     *
     * 段落级精度已经满足「一步定位」：正文一段通常就是视觉上的一两行。
     */
    int paragraphAtByte(qint64 offset) const;

    /// 段落下标 → 段首字节偏移；越界返回 -1
    qint64 byteAtParagraph(int index) const;
};

/**
 * 按章 Range 加载（§5.1 PC-203「按章加载」、PC-108 纯文本查看器）。
 *
 * 关键点：**只读这一章的字节区间**，不整本读入。20MB 的书翻到第 300 章，
 * 也只会发出一次「第 300 章的区间」请求；远端因此可以只做一次 Range 请求。
 *
 * 行切分与分章索引共用同一套字节级扫描器（`ChapterLineScanner`），
 * 保证「索引里的章边界」与「正文里的行边界」永远一致。
 */
class TxtChapterLoader
{
public:
    /**
     * 把一段字节切成行（纯函数，便于单测）。
     *
     * @param baseOffset data[0] 在文件里的绝对偏移，行偏移 = baseOffset + 相对位置
     */
    static QVector<TxtLine> parseLines(const QByteArray &data, qint64 baseOffset,
                                       TextCodec::Encoding encoding);

    /// 解析成一章（含章名行判定）
    static TxtChapterText parseChapter(const QByteArray &data, qint64 baseOffset,
                                       TextCodec::Encoding encoding, const QString &title);

    /**
     * 异步加载第 `chapter` 章。
     *
     * @param maxBytes 单章上限（默认 4MB）。超长章节只读前 maxBytes，并置 truncated
     *                 —— 一章 20MB 的 txt 是真实存在的（作者不换行的整卷），
     *                 不加保险一次读进来会把内存打爆。
     */
    static void load(RangeSource *source, const NovelIndex &index, int chapter,
                     std::function<void(TxtChapterText, StorageError)> callback,
                     qint64 maxBytes = 4 * 1024 * 1024);
};

} // namespace myhub
