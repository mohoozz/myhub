#pragma once

#include "core/text/TextCodec.h"

#include <QMetaType>
#include <QString>
#include <QVector>

namespace myhub {

/// 目录里的一章。
struct NovelChapter
{
    QString title;          ///< 章名（已去首尾空白与 BOM）
    qint64 startOffset = 0; ///< 起始**字节**偏移（章名行首）
    QString ruleId;         ///< 命中规则 id（排查用，不参与展示）
};

/**
 * 一本 txt 的分章结果（§5.1 PC-201）。
 *
 * 只记录**章节起点**：章内容区间 = 本章起点 → 下一章起点（末章 → 文件尾），
 * 所以任何一章都能单独 Range 读出来，不需要整本载入内存，也不需要二分统计字数。
 *
 * 偏移一律是**原始文件字节偏移**，不是字符下标，也不是解码后的字符串位置：
 * 解码会因非法字节/UTF-16 代理对丢失「字符 → 字节」映射，一旦用字符下标去
 * seek 就会越读越偏（这正是需求文档 §2.5 强调「码元对齐」的原因）。
 */
class NovelIndex
{
public:
    NovelIndex() = default;

    TextCodec::Encoding encoding = TextCodec::Unknown;
    QVector<NovelChapter> chapters;
    qint64 fileSize = 0;
    qint64 modTime = 0;     ///< 文件修改时间（ms）；与 fileSize 一起构成缓存指纹
    QString ruleId;         ///< 最终采用的分章规则
    QString rejectedRuleId; ///< 择优时被判为「假命中」的规则（只用于日志排查）

    /**
     * 「整本单章」索引：没识别出章节、或用户手动切到整本模式时用。
     *
     * 有它做兜底，阅读器永远只处理「有目录」这一种情况，不用到处判空。
     */
    static NovelIndex singleChapter(qint64 fileSize, TextCodec::Encoding encoding);

    bool isValid() const { return !chapters.isEmpty(); }
    int count() const { return static_cast<int>(chapters.size()); }

    /// 字节偏移落在第几章（首章之前归 0；无章返回 -1）
    int chapterAt(qint64 byteOffset) const;

    /// 章起始偏移；下标越界返回 -1
    qint64 chapterStart(int index) const;

    /**
     * 章结束偏移（不含）。
     * 末章到文件尾；如果索引记下的 fileSize 比重算的还小，以较大者为准（防止截断显示）。
     */
    qint64 chapterEnd(int index) const;

    /// 章名；越界返回空
    QString chapterTitle(int index) const;

    /// 文件是否仍是索引建立时的那一份（大小一致 + 修改时间一致）
    bool matchesFile(qint64 size, qint64 modTimeMs) const;

    /// 该偏移在全文中的百分比（0..1）；文件长度未知时返回 0
    double percentAt(qint64 byteOffset) const;
};

} // namespace myhub

Q_DECLARE_METATYPE(myhub::NovelIndex)
