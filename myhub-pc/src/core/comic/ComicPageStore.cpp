#include "ComicPageStore.h"

#include "core/database/AppDatabase.h"
#include "core/utils/AppLogger.h"

#include <QDateTime>
#include <QJsonArray>
#include <QJsonDocument>
#include <QUuid>

namespace myhub {
namespace {

constexpr auto kSelectColumns = "SELECT pagesJSON, fileSize, modTime FROM comicPages";

/// 行 → ComicPageList；JSON 坏了就当没有这一行
bool rowToPages(const QVariantMap &row, ComicPageList *out)
{
    ComicPageList pages;
    pages.fileSize = row.value(QStringLiteral("fileSize")).toLongLong();
    pages.modTime = row.value(QStringLiteral("modTime")).toLongLong();
    if (!ComicPageStore::decode(row.value(QStringLiteral("pagesJSON")).toString(), &pages.pages)) {
        return false;
    }
    *out = pages;
    return true;
}

} // namespace

bool ComicPageList::matchesFile(qint64 size, qint64 modTimeMs) const
{
    if (!isValid() || fileSize <= 0) {
        return false;
    }
    if (fileSize != size) {
        return false;
    }
    // 修改时间精度在不同文件系统上差异很大（FAT 2 秒、SMB 甚至丢秒），
    // 只认「都拿到且相差不超过 2 秒」，与 `NovelIndex::matchesFile` 同一口径
    if (modTime <= 0 || modTimeMs <= 0) {
        return true;
    }
    return qAbs(modTime - modTimeMs) <= 2000;
}

bool ComicPageStore::load(const QString &connectionId, const QString &path, qint64 fileSize,
                          qint64 modTimeMs, ComicPageList *out)
{
    ComicPageList cached;
    if (!find(connectionId, path, &cached)) {
        return false;
    }
    if (!cached.matchesFile(fileSize, modTimeMs)) {
        MH_INFO(ComicReader,
                QStringLiteral("页名清单指纹不符，将重新列举：%1（缓存 %2 字节 → 实际 %3 字节）")
                    .arg(path)
                    .arg(cached.fileSize)
                    .arg(fileSize));
        return false;
    }
    if (out) {
        *out = cached;
    }
    return true;
}

bool ComicPageStore::find(const QString &connectionId, const QString &path, ComicPageList *out)
{
    if (connectionId.isEmpty() || path.isEmpty()) {
        return false;
    }
    auto &db = AppDatabase::instance();
    if (!db.isOpen()) {
        return false;
    }
    const auto rows = db.query(QStringLiteral("%1 WHERE connectionID = ? AND filePath = ?")
                                   .arg(QLatin1String(kSelectColumns)),
                               {connectionId, path});
    if (rows.isEmpty()) {
        return false;
    }
    ComicPageList cached;
    if (!rowToPages(rows.first(), &cached)) {
        return false;
    }
    if (out) {
        *out = cached;
    }
    return true;
}

bool ComicPageStore::save(const QString &connectionId, const QString &path,
                          const QStringList &pages, qint64 fileSize, qint64 modTimeMs)
{
    if (connectionId.isEmpty() || path.isEmpty() || pages.isEmpty()) {
        return false;
    }
    auto &db = AppDatabase::instance();
    if (!db.isOpen()) {
        MH_DEBUG(ComicReader, QStringLiteral("页名清单落库早于数据库就绪，已跳过：%1").arg(path));
        return false;
    }

    const bool ok = db.execute(
        QStringLiteral("INSERT INTO comicPages "
                       "(id, connectionID, filePath, pagesJSON, fileSize, modTime, updatedAt) "
                       "VALUES (?, ?, ?, ?, ?, ?, ?) "
                       "ON CONFLICT(connectionID, filePath) DO UPDATE SET "
                       " pagesJSON = excluded.pagesJSON, fileSize = excluded.fileSize, "
                       " modTime = excluded.modTime, updatedAt = excluded.updatedAt"),
        {QUuid::createUuid().toString(QUuid::WithoutBraces), connectionId, path, encode(pages),
         fileSize, modTimeMs, QDateTime::currentMSecsSinceEpoch()});

    if (!ok) {
        MH_WARN(ComicReader,
                QStringLiteral("页名清单落库失败：%1（%2）").arg(path, db.lastError()));
        return false;
    }
    return true;
}

bool ComicPageStore::remove(const QString &connectionId, const QString &path)
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen() || connectionId.isEmpty() || path.isEmpty()) {
        return false;
    }
    return db.execute(
        QStringLiteral("DELETE FROM comicPages WHERE connectionID = ? AND filePath = ?"),
        {connectionId, path});
}

int ComicPageStore::removeSubtree(const QString &connectionId, const QString &path)
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen() || connectionId.isEmpty() || path.isEmpty()) {
        return 0;
    }

    // 与 `NovelIndexStore::removeSubtree` 同理：路径里可能含 % 与 _，
    // 与其给 LIKE 拼 ESCAPE，不如取回本连接的路径在内存里判前缀
    const QString prefix = path + QLatin1Char('/');
    const auto rows = db.query(
        QStringLiteral("SELECT filePath FROM comicPages WHERE connectionID = ?"), {connectionId});

    int removed = 0;
    for (const auto &row : rows) {
        const QString rowPath = row.value(QStringLiteral("filePath")).toString();
        if (rowPath != path && !rowPath.startsWith(prefix)) {
            continue;
        }
        if (db.execute(
                QStringLiteral("DELETE FROM comicPages WHERE connectionID = ? AND filePath = ?"),
                {connectionId, rowPath})) {
            ++removed;
        }
    }
    return removed;
}

int ComicPageStore::renamePath(const QString &connectionId, const QString &oldPath,
                               const QString &newPath)
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen() || connectionId.isEmpty() || oldPath.isEmpty() || newPath.isEmpty()
        || oldPath == newPath) {
        return 0;
    }

    const QString prefix = oldPath + QLatin1Char('/');
    const auto rows = db.query(
        QStringLiteral("SELECT filePath FROM comicPages WHERE connectionID = ?"), {connectionId});

    int updated = 0;
    for (const auto &row : rows) {
        const QString rowPath = row.value(QStringLiteral("filePath")).toString();
        QString target;
        if (rowPath == oldPath) {
            target = newPath;
        } else if (rowPath.startsWith(prefix)) {
            target = newPath + rowPath.mid(oldPath.size());
        } else {
            continue;
        }
        // 覆盖式移动：目标路径可能已有被覆盖那本书的页名清单，先清掉再改路径，
        // 否则会撞 `(connectionID, filePath)` 唯一键而静默不生效
        db.execute(QStringLiteral("DELETE FROM comicPages WHERE connectionID = ? AND filePath = ?"),
                   {connectionId, target});
        if (db.execute(QStringLiteral("UPDATE comicPages SET filePath = ? "
                                      "WHERE connectionID = ? AND filePath = ?"),
                       {target, connectionId, rowPath})) {
            ++updated;
        }
    }
    return updated;
}

int ComicPageStore::count()
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen()) {
        return 0;
    }
    return db.queryScalar(QStringLiteral("SELECT COUNT(*) FROM comicPages")).toInt();
}

QString ComicPageStore::encode(const QStringList &pages)
{
    QJsonArray array;
    for (const QString &page : pages) {
        array.append(page);
    }
    return QString::fromUtf8(QJsonDocument(array).toJson(QJsonDocument::Compact));
}

bool ComicPageStore::decode(const QString &json, QStringList *out)
{
    const QJsonDocument doc = QJsonDocument::fromJson(json.toUtf8());
    if (!doc.isArray()) {
        return false;
    }
    QStringList pages;
    const QJsonArray array = doc.array();
    pages.reserve(array.size());
    for (const auto &value : array) {
        // 页名是压缩包内的相对路径：空串或非字符串都说明这行坏了，
        // 宁可当未命中重扫，也不能让 QML 拿到一个「第 0 页是空名」的清单
        if (!value.isString()) {
            return false;
        }
        const QString name = value.toString();
        if (name.isEmpty()) {
            return false;
        }
        pages.append(name);
    }
    if (pages.isEmpty()) {
        return false;
    }
    if (out) {
        *out = pages;
    }
    return true;
}

} // namespace myhub
