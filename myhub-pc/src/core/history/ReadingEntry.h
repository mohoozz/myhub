#pragma once

#include "core/history/ProgressRepository.h"

#include <QList>
#include <QString>

namespace myhub {

/**
 * 「正在阅读」首页的一行（PC-209）。
 *
 * 只做**展示口径**的唯一化：百分比文案、已看完/已听完/已读完的区分、
 * 相对时间（刚刚 / 12 分钟前 / 昨天 / 上周）都在这里定，UI 不得各写一套。
 * 放在 core 层是为了能被 QTest 直接覆盖（相对时间的分支很多，靠肉眼看界面测不出来）。
 */
struct ReadingEntry
{
    QString connectionId;
    QString path;
    QString title;
    QString mediaKind;    ///< video / audio / novel / comic / image / text
    QString kindText;     ///< 视频 / 音频 / 小说 / 漫画 / 图片 / 文本
    QString percentText;  ///< "65%"；已读完的记录恒为 "100%"
    QString finishedText; ///< 已看完 / 已听完 / 已读完
    QString relativeTime; ///< 刚刚 / 12 分钟前 / 昨天 / 上周 / 2026/9/1
    double percent = 0.0; ///< 0~1，已读完恒为 1.0
    bool finished = false;
    qint64 updatedAt = 0;
    qint64 resumeMs = 0; ///< 续播起点；已读完或接近结尾为 0

    /// 单条记录 → 展示行（`nowMs` 便于单测固定「现在」）
    static ReadingEntry fromRecord(const ProgressRecord &record, qint64 nowMs);

    /// 批量转换，保持入参顺序（调用方负责按 updatedAt 倒序查询）
    static QList<ReadingEntry> fromRecords(const QList<ProgressRecord> &records, qint64 nowMs);

    /// 类型徽标文案
    static QString kindTextFor(const QString &mediaKind);

    /// 完成态文案：视频「已看完」、音频「已听完」、书/漫画「已读完」
    static QString finishedTextFor(const QString &mediaKind);

    /// 相对时间（1 分钟内「刚刚」，7 天以上「上周 / N 周前 / 具体日期」）
    static QString relativeTimeFor(qint64 updatedAtMs, qint64 nowMs);

    /// 百分比文案；越界与 NaN 一律收敛到 0%~100%
    static QString percentTextFor(double percent);
};

} // namespace myhub
