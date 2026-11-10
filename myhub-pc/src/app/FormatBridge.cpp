#include "FormatBridge.h"

#include <QChar>
#include <QtGlobal>

namespace myhub {

FormatBridge *FormatBridge::create(QQmlEngine *, QJSEngine *)
{
    return new FormatBridge(nullptr);
}

FormatBridge::FormatBridge(QObject *parent)
    : QObject(parent)
{}

QString FormatBridge::duration(qint64 milliseconds) const
{
    if (milliseconds < 0) {
        return QStringLiteral("--:--");
    }
    const qint64 totalSeconds = milliseconds / 1000;
    const qint64 hours = totalSeconds / 3600;
    const qint64 minutes = (totalSeconds % 3600) / 60;
    const qint64 seconds = totalSeconds % 60;

    if (hours > 0) {
        return QStringLiteral("%1:%2:%3")
            .arg(hours)
            .arg(minutes, 2, 10, QChar(u'0'))
            .arg(seconds, 2, 10, QChar(u'0'));
    }
    return QStringLiteral("%1:%2").arg(minutes).arg(seconds, 2, 10, QChar(u'0'));
}

QString FormatBridge::fileSize(qint64 bytes) const
{
    if (bytes < 0) {
        return QStringLiteral("--");
    }
    constexpr qint64 kb = 1024;
    constexpr qint64 mb = kb * 1024;
    constexpr qint64 gb = mb * 1024;

    if (bytes >= gb) {
        return QStringLiteral("%1 GB").arg(static_cast<double>(bytes) / gb, 0, 'f', 2);
    }
    if (bytes >= mb) {
        return QStringLiteral("%1 MB").arg(static_cast<double>(bytes) / mb, 0, 'f', 1);
    }
    if (bytes >= kb) {
        return QStringLiteral("%1 KB").arg(static_cast<double>(bytes) / kb, 0, 'f', 1);
    }
    return QStringLiteral("%1 B").arg(bytes);
}

} // namespace myhub
