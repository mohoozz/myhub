#include "NetworkHeuristics.h"

#include <QHostAddress>
#include <QObject>
#include <QUrl>

namespace myhub {

QString NetworkHeuristics::hostOf(const QString &url)
{
    if (url.isEmpty())
        return {};

    QUrl u(url);
    if (!u.host().isEmpty())
        return u.host();

    // 容错：用户可能只填了 "nas:5005" 或 "192.168.1.2"
    QString s = url;
    const int schemeSep = s.indexOf(QStringLiteral("://"));
    if (schemeSep >= 0)
        s = s.mid(schemeSep + 3);
    const int slash = s.indexOf(QLatin1Char('/'));
    if (slash >= 0)
        s = s.left(slash);
    const int colon = s.lastIndexOf(QLatin1Char(':'));
    // 排除 IPv6 字面量里的冒号
    if (colon >= 0 && !s.contains(QLatin1Char('[')))
        s = s.left(colon);
    return s;
}

bool NetworkHeuristics::isPrivateHost(const QString &hostOrUrl)
{
    const QString host = hostOf(hostOrUrl).toLower();
    if (host.isEmpty())
        return false;

    if (host == QLatin1String("localhost"))
        return true;

    // IP 字面量：用 QHostAddress 判定私有段
    QHostAddress addr(host);
    if (!addr.isNull()) {
        if (addr.isLoopback() || addr.isLinkLocal() || addr.isSiteLocal())
            return true;
        // QHostAddress::isSiteLocal 覆盖 IPv6 fec0::/10 与 IPv4 私有段；
        // 为稳妥起见再显式判 IPv4 私有段
        bool ok = false;
        const quint32 v4 = addr.toIPv4Address(&ok);
        if (ok) {
            const quint8 a = (v4 >> 24) & 0xFF;
            const quint8 b = (v4 >> 16) & 0xFF;
            if (a == 10)
                return true; // 10.0.0.0/8
            if (a == 127)
                return true; // 127.0.0.0/8
            if (a == 172 && b >= 16 && b <= 31)
                return true; // 172.16.0.0/12
            if (a == 192 && b == 168)
                return true; // 192.168.0.0/16
            if (a == 169 && b == 254)
                return true; // 169.254.0.0/16
        }
        return false;
    }

    // 域名后缀
    if (host.endsWith(QLatin1String(".local")) || host.endsWith(QLatin1String(".lan")))
        return true;

    // 无点主机名（单段，如 "nas"）通常是局域网内的 NetBIOS / mDNS 名
    if (!host.contains(QLatin1Char('.')))
        return true;

    return false;
}

NetworkHeuristics::Scope NetworkHeuristics::scopeOf(const QString &url)
{
    if (url.isEmpty())
        return Unknown;
    return isPrivateHost(url) ? Internal : External;
}

QString NetworkHeuristics::scopeName(Scope s)
{
    switch (s) {
    case Internal:
        return QStringLiteral("internal");
    case External:
        return QStringLiteral("external");
    case Unknown:
        break;
    }
    return QStringLiteral("unknown");
}

QString NetworkHeuristics::scopeDisplayText(Scope s)
{
    switch (s) {
    case Internal:
        return QObject::tr("内网可达");
    case External:
        return QObject::tr("外网可达");
    case Unknown:
        break;
    }
    return QObject::tr("已连接");
}

} // namespace myhub
