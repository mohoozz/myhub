#include "EpubMetaStore.h"

#include "core/database/AppDatabase.h"
#include "core/utils/AppLogger.h"

#include <QDateTime>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QUuid>

namespace myhub {
namespace {

constexpr auto kSelectColumns = "SELECT metaJSON, fileSize, modTime FROM epubMeta";

/// 行 → EpubMeta；JSON 坏了就当没有这一行（调用方按「无快照」处理）
bool rowToMeta(const QVariantMap &row, EpubMeta *out)
{
    EpubMeta meta;
    if (!EpubMetaStore::decode(row.value(QStringLiteral("metaJSON")).toString(), &meta)) {
        return false;
    }
    meta.fileSize = row.value(QStringLiteral("fileSize")).toLongLong();
    meta.modTime = row.value(QStringLiteral("modTime")).toLongLong();
    *out = meta;
    return true;
}

} // namespace

bool EpubMetaStore::save(const QString &connectionId, const QString &path, const EpubMeta &meta)
{
    if (connectionId.isEmpty() || path.isEmpty() || !meta.isValid()) {
        return false;
    }
    auto &db = AppDatabase::instance();
    if (!db.isOpen()) {
        MH_DEBUG(NovelIndex,
                 QStringLiteral("epub 目录快照落库早于数据库就绪，已跳过：%1").arg(path));
        return false;
    }

    const bool ok = db.execute(
        QStringLiteral("INSERT INTO epubMeta "
                       "(id, connectionID, filePath, metaJSON, fileSize, modTime, updatedAt) "
                       "VALUES (?, ?, ?, ?, ?, ?, ?) "
                       "ON CONFLICT(connectionID, filePath) DO UPDATE SET "
                       " metaJSON = excluded.metaJSON, fileSize = excluded.fileSize, "
                       " modTime = excluded.modTime, updatedAt = excluded.updatedAt"),
        {QUuid::createUuid().toString(QUuid::WithoutBraces), connectionId, path, encode(meta),
         meta.fileSize, meta.modTime, QDateTime::currentMSecsSinceEpoch()});

    if (!ok) {
        MH_WARN(NovelIndex,
                QStringLiteral("epub 目录快照落库失败：%1（%2）").arg(path, db.lastError()));
        return false;
    }
    return true;
}

bool EpubMetaStore::find(const QString &connectionId, const QString &path, EpubMeta *out)
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
    EpubMeta meta;
    if (!rowToMeta(rows.first(), &meta) || !meta.isValid()) {
        return false;
    }
    if (out) {
        *out = meta;
    }
    return true;
}

bool EpubMetaStore::remove(const QString &connectionId, const QString &path)
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen() || connectionId.isEmpty() || path.isEmpty()) {
        return false;
    }
    return db.execute(
        QStringLiteral("DELETE FROM epubMeta WHERE connectionID = ? AND filePath = ?"),
        {connectionId, path});
}

int EpubMetaStore::removeSubtree(const QString &connectionId, const QString &path)
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen() || connectionId.isEmpty() || path.isEmpty()) {
        return 0;
    }

    // 与 `NovelIndexStore::removeSubtree` 同理：路径里可能含 % 与 _，
    // 与其给 LIKE 拼 ESCAPE，不如取回本连接的路径在内存里判前缀
    const QString prefix = path + QLatin1Char('/');
    const auto rows = db.query(
        QStringLiteral("SELECT filePath FROM epubMeta WHERE connectionID = ?"), {connectionId});

    int removed = 0;
    for (const auto &row : rows) {
        const QString rowPath = row.value(QStringLiteral("filePath")).toString();
        if (rowPath != path && !rowPath.startsWith(prefix)) {
            continue;
        }
        if (db.execute(
                QStringLiteral("DELETE FROM epubMeta WHERE connectionID = ? AND filePath = ?"),
                {connectionId, rowPath})) {
            ++removed;
        }
    }
    return removed;
}

int EpubMetaStore::renamePath(const QString &connectionId, const QString &oldPath,
                              const QString &newPath)
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen() || connectionId.isEmpty() || oldPath.isEmpty() || newPath.isEmpty()
        || oldPath == newPath) {
        return 0;
    }

    const QString prefix = oldPath + QLatin1Char('/');
    const auto rows = db.query(
        QStringLiteral("SELECT filePath FROM epubMeta WHERE connectionID = ?"), {connectionId});

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
        // 覆盖式移动：目标路径可能已有被覆盖那本书的快照，先清掉再改路径，
        // 否则会撞 `(connectionID, filePath)` 唯一键而静默不生效
        db.execute(QStringLiteral("DELETE FROM epubMeta WHERE connectionID = ? AND filePath = ?"),
                   {connectionId, target});
        if (db.execute(QStringLiteral("UPDATE epubMeta SET filePath = ? "
                                      "WHERE connectionID = ? AND filePath = ?"),
                       {target, connectionId, rowPath})) {
            ++updated;
        }
    }
    return updated;
}

int EpubMetaStore::count()
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen()) {
        return 0;
    }
    return db.queryScalar(QStringLiteral("SELECT COUNT(*) FROM epubMeta")).toInt();
}

QString EpubMetaStore::encode(const EpubMeta &meta)
{
    QJsonArray chapters;
    for (const EpubChapterRef &chapter : meta.chapters) {
        QJsonObject item;
        item.insert(QStringLiteral("title"), chapter.title);
        item.insert(QStringLiteral("href"), chapter.href);
        item.insert(QStringLiteral("level"), chapter.level);
        chapters.append(item);
    }

    QJsonObject root;
    root.insert(QStringLiteral("title"), meta.title);
    root.insert(QStringLiteral("author"), meta.author);
    root.insert(QStringLiteral("language"), meta.language);
    root.insert(QStringLiteral("cover"), meta.coverHref);
    root.insert(QStringLiteral("chapters"), chapters);
    return QString::fromUtf8(QJsonDocument(root).toJson(QJsonDocument::Compact));
}

bool EpubMetaStore::decode(const QString &json, EpubMeta *out)
{
    const QJsonDocument doc = QJsonDocument::fromJson(json.toUtf8());
    if (!doc.isObject()) {
        return false;
    }
    const QJsonObject root = doc.object();
    const QJsonValue chaptersValue = root.value(QStringLiteral("chapters"));
    if (!chaptersValue.isArray()) {
        return false;
    }

    QVector<EpubChapterRef> chapters;
    const QJsonArray array = chaptersValue.toArray();
    chapters.reserve(array.size());
    for (const auto &value : array) {
        // 章名与条目路径缺一个都说明这行坏了：目录项没有路径就无从定位，
        // 没有标题在目录面板里就是一排空行 —— 宁可当未命中、老实报错
        if (!value.isObject()) {
            return false;
        }
        const QJsonObject item = value.toObject();
        EpubChapterRef chapter;
        chapter.title = item.value(QStringLiteral("title")).toString();
        chapter.href = item.value(QStringLiteral("href")).toString();
        if (chapter.title.isEmpty() || chapter.href.isEmpty()) {
            return false;
        }
        // level 只用于目录缩进，坏值夹紧即可，不必因此丢掉整份快照
        chapter.level = qBound(0, item.value(QStringLiteral("level")).toInt(), 9);
        chapters.append(chapter);
    }
    if (chapters.isEmpty()) {
        return false;
    }

    EpubMeta meta;
    meta.title = root.value(QStringLiteral("title")).toString();
    meta.author = root.value(QStringLiteral("author")).toString();
    meta.language = root.value(QStringLiteral("language")).toString();
    meta.coverHref = root.value(QStringLiteral("cover")).toString();
    meta.chapters = chapters;
    if (out) {
        *out = meta;
    }
    return true;
}

} // namespace myhub
