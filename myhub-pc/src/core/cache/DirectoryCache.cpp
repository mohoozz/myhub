#include "DirectoryCache.h"
#include "../utils/AppLogger.h"
#include "../utils/AppPaths.h"

#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMutex>
#include <QMutexLocker>

namespace myhub {

namespace {
constexpr auto kPartition = "directoryListings";
}

struct DirectoryCache::Private
{
    mutable QMutex mutex;
};

DirectoryCache::DirectoryCache(QObject *parent)
    : QObject(parent)
    , d(new Private)
{
    AppPaths::ensureDir(AppPaths::cachePartition(QLatin1String(kPartition)));
}

DirectoryCache::~DirectoryCache()
{
    delete d;
}

DirectoryCache &DirectoryCache::instance()
{
    static DirectoryCache s_instance;
    return s_instance;
}

QString DirectoryCache::cacheFilePath(const QString &connectionId, const QString &path) const
{
    // 稳定哈希键：跨启动有效（不得用进程内 hash，§14.2）
    const QByteArray key = (connectionId + QLatin1Char('|') + path).toUtf8();
    const QString name =
        QString::fromLatin1(QCryptographicHash::hash(key, QCryptographicHash::Sha1).toHex());
    return AppPaths::cachePartition(QLatin1String(kPartition)) + QLatin1Char('/') + name
        + QStringLiteral(".json");
}

bool DirectoryCache::load(const QString &connectionId, const QString &path,
                          FileEntryList *out) const
{
    if (!out)
        return false;

    QMutexLocker lock(&d->mutex);
    QFile f(cacheFilePath(connectionId, path));
    if (!f.open(QIODevice::ReadOnly))
        return false;

    const QJsonDocument doc = QJsonDocument::fromJson(f.readAll());
    if (!doc.isObject())
        return false;

    const QJsonObject root = doc.object();
    const QJsonArray arr = root.value(QStringLiteral("entries")).toArray();

    FileEntryList entries;
    entries.reserve(arr.size());
    // QJsonArray 迭代返回 QJsonValueConstRef，写成 const QJsonValue & 会额外拷贝
    for (const auto &v : arr) {
        const QJsonObject o = v.toObject();
        FileEntry e;
        e.name = o.value(QStringLiteral("name")).toString();
        e.path = o.value(QStringLiteral("path")).toString();
        e.isDir = o.value(QStringLiteral("isDir")).toBool();
        e.size = static_cast<qint64>(o.value(QStringLiteral("size")).toDouble());
        e.ext = o.value(QStringLiteral("ext")).toString();
        const qint64 mt = static_cast<qint64>(o.value(QStringLiteral("modTime")).toDouble());
        if (mt > 0)
            e.modTime = QDateTime::fromSecsSinceEpoch(mt);
        entries.append(e);
    }

    // 命中访问时刷新 mtime，供 LRU 淘汰参考
    f.close();
    *out = entries;
    return true;
}

void DirectoryCache::store(const QString &connectionId, const QString &path,
                           const FileEntryList &entries, bool verifiedEmpty)
{
    // 关键纪律：异常响应不得写入「空目录」缓存（PC-708 目录列举严格校验）
    if (entries.isEmpty() && !verifiedEmpty) {
        MH_WARN(Storage,
                QStringLiteral("refuse to cache empty listing for %1%2 "
                               "(not verified as truly empty)")
                    .arg(connectionId, path));
        return;
    }

    QJsonArray arr;
    for (const FileEntry &e : entries) {
        QJsonObject o;
        o.insert(QStringLiteral("name"), e.name);
        o.insert(QStringLiteral("path"), e.path);
        o.insert(QStringLiteral("isDir"), e.isDir);
        o.insert(QStringLiteral("size"), static_cast<double>(e.size));
        o.insert(QStringLiteral("ext"), e.ext);
        o.insert(QStringLiteral("modTime"),
                 e.modTime.isValid() ? static_cast<double>(e.modTime.toSecsSinceEpoch()) : 0);
        arr.append(o);
    }

    QJsonObject root;
    root.insert(QStringLiteral("connectionID"), connectionId);
    root.insert(QStringLiteral("path"), path);
    root.insert(QStringLiteral("cachedAt"),
                static_cast<double>(QDateTime::currentSecsSinceEpoch()));
    root.insert(QStringLiteral("entries"), arr);

    QMutexLocker lock(&d->mutex);
    QFile f(cacheFilePath(connectionId, path));
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return;
    f.write(QJsonDocument(root).toJson(QJsonDocument::Compact));
}

void DirectoryCache::invalidate(const QString &connectionId, const QString &path)
{
    QMutexLocker lock(&d->mutex);
    QFile::remove(cacheFilePath(connectionId, path));
}

void DirectoryCache::invalidateConnection(const QString &connectionId)
{
    // 哈希键不可逆，无法按连接精确定位；遍历读取头部字段匹配
    QMutexLocker lock(&d->mutex);
    QDir dir(AppPaths::cachePartition(QLatin1String(kPartition)));
    for (const QFileInfo &fi : dir.entryInfoList({QStringLiteral("*.json")}, QDir::Files)) {
        QFile f(fi.absoluteFilePath());
        if (!f.open(QIODevice::ReadOnly))
            continue;
        const QJsonDocument doc = QJsonDocument::fromJson(f.read(512));
        f.close();
        if (doc.isObject()
            && doc.object().value(QStringLiteral("connectionID")).toString() == connectionId) {
            QFile::remove(fi.absoluteFilePath());
        }
    }
}

void DirectoryCache::clearAll()
{
    QMutexLocker lock(&d->mutex);
    QDir dir(AppPaths::cachePartition(QLatin1String(kPartition)));
    for (const QFileInfo &fi : dir.entryInfoList({QStringLiteral("*.json")}, QDir::Files))
        QFile::remove(fi.absoluteFilePath());
}

qint64 DirectoryCache::totalBytes() const
{
    QMutexLocker lock(&d->mutex);
    qint64 total = 0;
    QDir dir(AppPaths::cachePartition(QLatin1String(kPartition)));
    for (const QFileInfo &fi : dir.entryInfoList({QStringLiteral("*.json")}, QDir::Files))
        total += fi.size();
    return total;
}

bool DirectoryCache::contains(const QString &connectionId, const QString &path) const
{
    QMutexLocker lock(&d->mutex);
    return QFile::exists(cacheFilePath(connectionId, path));
}

} // namespace myhub
