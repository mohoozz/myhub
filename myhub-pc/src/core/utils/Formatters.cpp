#include "Formatters.h"

#include <QObject>
#include <cmath>

namespace myhub {

QString Formatters::fileSize(qint64 bytes)
{
    if (bytes < 0)
        return QString();
    if (bytes < 1024)
        return QObject::tr("%1 B").arg(bytes);

    constexpr double kb = 1024.0;
    const double v = static_cast<double>(bytes);
    if (v < kb * 1024)
        return QObject::tr("%1 KB").arg(v / kb, 0, 'f', v < kb * 10 ? 1 : 0);
    if (v < kb * 1024 * 1024)
        return QObject::tr("%1 MB").arg(v / (kb * kb), 0, 'f', 1);
    return QObject::tr("%1 GB").arg(v / (kb * kb * kb), 0, 'f', 2);
}

QString Formatters::duration(qint64 seconds)
{
    if (seconds < 0)
        return QStringLiteral("--:--");
    const qint64 h = seconds / 3600;
    const qint64 m = (seconds % 3600) / 60;
    const qint64 s = seconds % 60;
    if (h > 0) {
        return QStringLiteral("%1:%2:%3")
            .arg(h)
            .arg(m, 2, 10, QLatin1Char('0'))
            .arg(s, 2, 10, QLatin1Char('0'));
    }
    return QStringLiteral("%1:%2").arg(m, 2, 10, QLatin1Char('0')).arg(s, 2, 10, QLatin1Char('0'));
}

QString Formatters::relativeTime(const QDateTime &time)
{
    if (!time.isValid())
        return QString();

    const QDateTime now = QDateTime::currentDateTime();
    const qint64 secs = time.secsTo(now);

    if (secs < 60)
        return QObject::tr("刚刚");
    if (secs < 3600)
        return QObject::tr("%1 分钟前").arg(secs / 60);
    if (secs < 86400 && time.date() == now.date())
        return QObject::tr("%1 小时前").arg(secs / 3600);
    if (time.date().daysTo(now.date()) == 1)
        return QObject::tr("昨天");
    if (time.date().daysTo(now.date()) < 7)
        return QObject::tr("%1 天前").arg(time.date().daysTo(now.date()));
    if (time.date().year() == now.date().year())
        return time.toString(QObject::tr("M月d日"));
    return time.toString(QStringLiteral("yyyy-MM-dd"));
}

QString Formatters::absoluteTime(const QDateTime &time)
{
    if (!time.isValid())
        return QString();
    return time.toString(QStringLiteral("yyyy-MM-dd HH:mm"));
}

QString Formatters::percent(double ratio)
{
    const int p = static_cast<int>(std::lround(qBound(0.0, ratio, 1.0) * 100.0));
    return QStringLiteral("%1%").arg(p);
}

} // namespace myhub
