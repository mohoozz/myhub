#include "TrashStore.h"
#include "../storage/StoragePath.h"

#include <QJsonDocument>
#include <QJsonObject>

namespace myhub {

namespace {

constexpr auto kTrashDir = "/.trash";
constexpr auto kMetaSuffix = ".meta.json";
constexpr auto kOriginalPathKey = "originalPath";
constexpr auto kDeletedAtKey = "deletedAt";
constexpr auto kConnectionIdKey = "connectionId";

} // namespace

QString TrashStore::trashDir()
{
    return QString::fromLatin1(kTrashDir);
}

QString TrashStore::entryPath(const QString &trashName)
{
    return StoragePath::join(trashDir(), trashName);
}

QString TrashStore::metaPath(const QString &trashName)
{
    return StoragePath::join(trashDir(), trashName + QString::fromLatin1(kMetaSuffix));
}

QString TrashStore::candidateName(const QString &originalName, int attempt)
{
    if (attempt <= 0 || originalName.isEmpty())
        return originalName;

    // 序号插在扩展名之前：`a.mp4` → `a (1).mp4`，扩展名不参与排序也只影响展示
    const QString base = StoragePath::baseName(originalName);
    const QString ext = StoragePath::extension(originalName);
    const QString numbered = QStringLiteral("%1 (%2)").arg(base).arg(attempt);
    return ext.isEmpty() ? numbered : numbered + QLatin1Char('.') + ext;
}

bool TrashStore::isMetaName(const QString &name)
{
    return name.endsWith(QString::fromLatin1(kMetaSuffix), Qt::CaseInsensitive);
}

bool TrashStore::isTrashDir(const QString &path)
{
    return StoragePath::normalize(path) == trashDir();
}

QByteArray TrashStore::encodeMeta(const Meta &meta)
{
    QJsonObject obj;
    obj.insert(QString::fromLatin1(kConnectionIdKey), meta.connectionId);
    obj.insert(QString::fromLatin1(kOriginalPathKey), meta.originalPath);
    obj.insert(QString::fromLatin1(kDeletedAtKey), meta.deletedAtMs);
    return QJsonDocument(obj).toJson(QJsonDocument::Compact);
}

TrashStore::Meta TrashStore::decodeMeta(const QByteArray &json)
{
    Meta meta;
    const QJsonDocument doc = QJsonDocument::fromJson(json);
    if (!doc.isObject())
        return meta;

    const QJsonObject obj = doc.object();
    meta.connectionId = obj.value(QString::fromLatin1(kConnectionIdKey)).toString();
    meta.originalPath = obj.value(QString::fromLatin1(kOriginalPathKey)).toString();
    meta.deletedAtMs =
        static_cast<qint64>(obj.value(QString::fromLatin1(kDeletedAtKey)).toDouble());
    return meta;
}

} // namespace myhub
