#include "StoragePath.h"

#include <QUrl>

namespace myhub {

QString StoragePath::normalize(const QString &path)
{
    if (path.isEmpty())
        return QStringLiteral("/");

    QString s = path;
    s.replace(QLatin1Char('\\'), QLatin1Char('/'));

    const QStringList raw = s.split(QLatin1Char('/'), Qt::SkipEmptyParts);
    QStringList out;
    out.reserve(raw.size());

    for (const QString &part : raw) {
        if (part == QLatin1String("."))
            continue;
        if (part == QLatin1String("..")) {
            if (!out.isEmpty())
                out.removeLast();
            continue;
        }
        out << part;
    }

    if (out.isEmpty())
        return QStringLiteral("/");
    return QLatin1Char('/') + out.join(QLatin1Char('/'));
}

QString StoragePath::join(const QString &base, const QString &child)
{
    if (child.startsWith(QLatin1Char('/')))
        return normalize(child);
    return normalize(base + QLatin1Char('/') + child);
}

QString StoragePath::fileName(const QString &path)
{
    const QString s = normalize(path);
    if (isRoot(s))
        return QString();
    return s.mid(s.lastIndexOf(QLatin1Char('/')) + 1);
}

QString StoragePath::baseName(const QString &path)
{
    // 不加 const：下面 return 时才能走移动构造
    QString name = fileName(path);
    const int dot = name.lastIndexOf(QLatin1Char('.'));
    // 前导点视为隐藏文件而非扩展名分隔
    if (dot <= 0)
        return name;
    return name.left(dot);
}

QString StoragePath::parent(const QString &path)
{
    const QString s = normalize(path);
    if (isRoot(s))
        return QStringLiteral("/");
    const int slash = s.lastIndexOf(QLatin1Char('/'));
    if (slash <= 0)
        return QStringLiteral("/");
    return s.left(slash);
}

QString StoragePath::extension(const QString &path)
{
    const QString name = fileName(path);
    const int dot = name.lastIndexOf(QLatin1Char('.'));
    if (dot <= 0 || dot == name.size() - 1)
        return QString();
    return name.mid(dot + 1).toLower();
}

bool StoragePath::isRoot(const QString &path)
{
    const QString s = normalize(path);
    return s == QLatin1String("/");
}

QStringList StoragePath::segments(const QString &path)
{
    return normalize(path).split(QLatin1Char('/'), Qt::SkipEmptyParts);
}

bool StoragePath::isDescendantOf(const QString &path, const QString &ancestor)
{
    const QString p = normalize(path);
    const QString a = normalize(ancestor);
    if (p == a)
        return true;
    if (isRoot(a))
        return true;
    return p.startsWith(a + QLatin1Char('/'));
}

QString StoragePath::percentEncoded(const QString &path)
{
    const QStringList parts = segments(path);
    QStringList encoded;
    encoded.reserve(parts.size());
    for (const QString &part : parts) {
        encoded << QString::fromUtf8(
            QUrl::toPercentEncoding(part, QByteArray(), QByteArrayLiteral("/")));
    }
    if (encoded.isEmpty())
        return QStringLiteral("/");
    return QLatin1Char('/') + encoded.join(QLatin1Char('/'));
}

} // namespace myhub
