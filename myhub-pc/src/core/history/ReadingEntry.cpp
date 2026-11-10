#include "ReadingEntry.h"

#include "core/utils/MediaType.h"

#include <QDateTime>
#include <QFileInfo>
#include <QObject>
#include <QtMath>

namespace myhub {
namespace {

QString mediaKindOf(const ProgressRecord &record)
{
    if (!record.mediaType.isEmpty()) {
        return record.mediaType;
    }
    // 旧记录 / 其它模块写入的记录可能没有 mediaType，按扩展名兜底
    return MediaType::badgeId(MediaType::fromPath(record.path));
}

} // namespace

ReadingEntry ReadingEntry::fromRecord(const ProgressRecord &record, qint64 nowMs)
{
    ReadingEntry entry;
    entry.connectionId = record.connectionId;
    entry.path = record.path;
    entry.title = record.title;
    if (entry.title.isEmpty()) {
        entry.title = QFileInfo(record.path).fileName();
    }
    entry.mediaKind = mediaKindOf(record);
    entry.kindText = kindTextFor(entry.mediaKind);
    entry.finished = record.finished;
    entry.percent = record.finished ? 1.0 : qBound(0.0, record.percent, 1.0);
    entry.percentText = percentTextFor(entry.percent);
    entry.finishedText = finishedTextFor(entry.mediaKind);
    entry.updatedAt = record.updatedAt;
    entry.relativeTime = relativeTimeFor(record.updatedAt, nowMs);
    entry.resumeMs = ProgressRepository::resumePositionMs(record);
    return entry;
}

QList<ReadingEntry> ReadingEntry::fromRecords(const QList<ProgressRecord> &records, qint64 nowMs)
{
    QList<ReadingEntry> entries;
    entries.reserve(records.size());
    for (const auto &record : records) {
        entries.append(fromRecord(record, nowMs));
    }
    return entries;
}

QString ReadingEntry::kindTextFor(const QString &mediaKind)
{
    if (mediaKind == QLatin1String("video"))
        return QObject::tr("视频");
    if (mediaKind == QLatin1String("audio"))
        return QObject::tr("音频");
    if (mediaKind == QLatin1String("novel"))
        return QObject::tr("小说");
    if (mediaKind == QLatin1String("comic"))
        return QObject::tr("漫画");
    if (mediaKind == QLatin1String("image"))
        return QObject::tr("图片");
    if (mediaKind == QLatin1String("text"))
        return QObject::tr("文本");
    return QObject::tr("文件");
}

QString ReadingEntry::finishedTextFor(const QString &mediaKind)
{
    if (mediaKind == QLatin1String("video"))
        return QObject::tr("已看完");
    if (mediaKind == QLatin1String("audio"))
        return QObject::tr("已听完");
    if (mediaKind == QLatin1String("novel") || mediaKind == QLatin1String("comic")
        || mediaKind == QLatin1String("text")) {
        return QObject::tr("已读完");
    }
    return QObject::tr("已完成");
}

QString ReadingEntry::relativeTimeFor(qint64 updatedAtMs, qint64 nowMs)
{
    if (updatedAtMs <= 0) {
        return QObject::tr("未知");
    }
    if (nowMs <= updatedAtMs) {
        return QObject::tr("刚刚"); // 时钟回拨 / 未来时间都按刚刚处理
    }

    const qint64 deltaSec = (nowMs - updatedAtMs) / 1000;
    if (deltaSec < 60) {
        return QObject::tr("刚刚");
    }
    if (deltaSec < 3600) {
        return QObject::tr("%1 分钟前").arg(deltaSec / 60);
    }

    // 跨天一律按日历日判断：23:50 看的记录，次日 00:10 应该是「昨天」而不是「20 分钟前」
    const QDateTime updated = QDateTime::fromMSecsSinceEpoch(updatedAtMs);
    const QDateTime now = QDateTime::fromMSecsSinceEpoch(nowMs);
    const qint64 dayDiff = updated.date().daysTo(now.date());

    if (dayDiff <= 0) {
        return QObject::tr("%1 小时前").arg(deltaSec / 3600);
    }
    if (dayDiff == 1) {
        return QObject::tr("昨天");
    }
    if (dayDiff < 7) {
        return QObject::tr("%1 天前").arg(dayDiff);
    }
    if (dayDiff < 14) {
        return QObject::tr("上周");
    }
    if (dayDiff < 60) {
        return QObject::tr("%1 周前").arg(dayDiff / 7);
    }
    return updated.toString(QStringLiteral("yyyy/M/d"));
}

QString ReadingEntry::percentTextFor(double percent)
{
    if (qIsNaN(percent) || percent <= 0.0) {
        return QStringLiteral("0%");
    }
    const int pct = qRound(qMin(percent, 1.0) * 100.0);
    return QStringLiteral("%1%").arg(pct);
}

} // namespace myhub
