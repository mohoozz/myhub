#include "NovelIndexStore.h"

#include "core/database/AppDatabase.h"
#include "core/utils/AppLogger.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QUuid>

namespace myhub {
namespace {

constexpr auto kSelectColumns =
    "SELECT connectionID, filePath, encoding, chaptersJSON, fileSize, modTime FROM novelIndex";

QString encodeChaptersArray(const NovelIndex &index)
{
    QJsonArray array;
    for (int i = 0; i < index.chapters.size(); ++i) {
        const NovelChapter &chapter = index.chapters.at(i);
        QJsonObject item;
        item.insert(QStringLiteral("title"), chapter.title);
        item.insert(QStringLiteral("startOffset"), chapter.startOffset);
        // 只有首章带规则 id：与 iOS `ChapterInfo` 约定一致，避免每章重复几十字节
        const QString ruleId = i == 0 && !index.ruleId.isEmpty() ? index.ruleId : chapter.ruleId;
        if (i == 0 && !ruleId.isEmpty()) {
            item.insert(QStringLiteral("ruleID"), ruleId);
        }
        array.append(item);
    }
    return QString::fromUtf8(QJsonDocument(array).toJson(QJsonDocument::Compact));
}

/// 行 → NovelIndex；chapters 解析失败返回 false
bool rowToIndex(const QVariantMap &row, NovelIndex *out)
{
    NovelIndex index;
    index.encoding = TextCodec::fromName(row.value(QStringLiteral("encoding")).toString());
    index.fileSize = row.value(QStringLiteral("fileSize")).toLongLong();
    index.modTime = row.value(QStringLiteral("modTime")).toLongLong();
    if (!NovelIndexStore::decodeChapters(row.value(QStringLiteral("chaptersJSON")).toString(),
                                         &index.chapters)) {
        return false;
    }
    index.ruleId = index.chapters.isEmpty() ? QString() : index.chapters.constFirst().ruleId;
    *out = index;
    return true;
}

} // namespace

bool NovelIndexStore::load(const QString &connectionId, const QString &path, qint64 fileSize,
                           qint64 modTimeMs, NovelIndex *out)
{
    NovelIndex cached;
    if (!find(connectionId, path, &cached)) {
        return false;
    }
    // 指纹不符：文件被替换/追加过，旧索引的字节偏移全部作废
    if (fileSize > 0 && !cached.matchesFile(fileSize, modTimeMs)) {
        MH_INFO(NovelIndex,
                QStringLiteral("索引指纹不符，将重扫：%1（缓存 %2 字节 → 实际 %3 字节）")
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

bool NovelIndexStore::find(const QString &connectionId, const QString &path, NovelIndex *out)
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
    NovelIndex index;
    if (!rowToIndex(rows.first(), &index) || !index.isValid()) {
        return false;
    }
    if (out) {
        *out = index;
    }
    return true;
}

bool NovelIndexStore::save(const QString &connectionId, const QString &path,
                           const NovelIndex &index)
{
    if (connectionId.isEmpty() || path.isEmpty() || !index.isValid()) {
        return false;
    }
    auto &db = AppDatabase::instance();
    if (!db.isOpen()) {
        MH_WARN(NovelIndex, QStringLiteral("索引落库早于数据库就绪，已跳过：%1").arg(path));
        return false;
    }

    const bool ok = db.execute(
        QStringLiteral("INSERT INTO novelIndex "
                       "(id, connectionID, filePath, encoding, chaptersJSON, fileSize, modTime) "
                       "VALUES (?, ?, ?, ?, ?, ?, ?) "
                       "ON CONFLICT(connectionID, filePath) DO UPDATE SET "
                       " encoding = excluded.encoding, chaptersJSON = excluded.chaptersJSON, "
                       " fileSize = excluded.fileSize, modTime = excluded.modTime"),
        {QUuid::createUuid().toString(QUuid::WithoutBraces), connectionId, path,
         TextCodec::name(index.encoding), encodeChaptersArray(index), index.fileSize,
         index.modTime});

    if (!ok) {
        MH_ERROR(NovelIndex, QStringLiteral("索引落库失败：%1（%2）").arg(path, db.lastError()));
        return false;
    }
    return true;
}

bool NovelIndexStore::remove(const QString &connectionId, const QString &path)
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen() || connectionId.isEmpty() || path.isEmpty()) {
        return false;
    }
    return db.execute(
        QStringLiteral("DELETE FROM novelIndex WHERE connectionID = ? AND filePath = ?"),
        {connectionId, path});
}

int NovelIndexStore::removeSubtree(const QString &connectionId, const QString &path)
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen() || connectionId.isEmpty() || path.isEmpty()) {
        return 0;
    }

    // 索引最多几十上百条：一次取回本连接全部路径，在内存里判前缀，
    // 比给 LIKE 拼 ESCAPE 更稳（文件路径里可能含 % 与 _）
    const QString prefix = path + QLatin1Char('/');
    const auto rows = db.query(
        QStringLiteral("SELECT filePath FROM novelIndex WHERE connectionID = ?"), {connectionId});

    int removed = 0;
    for (const auto &row : rows) {
        const QString rowPath = row.value(QStringLiteral("filePath")).toString();
        if (rowPath != path && !rowPath.startsWith(prefix)) {
            continue;
        }
        if (db.execute(
                QStringLiteral("DELETE FROM novelIndex WHERE connectionID = ? AND filePath = ?"),
                {connectionId, rowPath})) {
            ++removed;
        }
    }
    return removed;
}

int NovelIndexStore::renamePath(const QString &connectionId, const QString &oldPath,
                                const QString &newPath)
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen() || connectionId.isEmpty() || oldPath.isEmpty() || newPath.isEmpty()
        || oldPath == newPath) {
        return 0;
    }

    const QString prefix = oldPath + QLatin1Char('/');
    const auto rows = db.query(
        QStringLiteral("SELECT filePath FROM novelIndex WHERE connectionID = ?"), {connectionId});

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
        // 覆盖式移动：目标路径可能已有被覆盖那本书的索引行。先清掉再改路径 ——
        // 直接 UPDATE 会撞 `(connectionID, filePath)` 唯一键，改成静默失败，
        // 结果新旧两行同时存在，按旧路径仍能查到一份早已不属于它的索引
        db.execute(QStringLiteral("DELETE FROM novelIndex WHERE connectionID = ? AND "
                                  "filePath = ?"),
                   {connectionId, target});
        if (db.execute(QStringLiteral("UPDATE novelIndex SET filePath = ? "
                                      "WHERE connectionID = ? AND filePath = ?"),
                       {target, connectionId, rowPath})) {
            ++updated;
        }
    }
    return updated;
}

int NovelIndexStore::count()
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen()) {
        return 0;
    }
    return db.queryScalar(QStringLiteral("SELECT COUNT(*) FROM novelIndex")).toInt();
}

QString NovelIndexStore::encodeChapters(const NovelIndex &index)
{
    return encodeChaptersArray(index);
}

bool NovelIndexStore::decodeChapters(const QString &json, QVector<NovelChapter> *out)
{
    QVector<NovelChapter> chapters;
    const QJsonDocument doc = QJsonDocument::fromJson(json.toUtf8());
    if (!doc.isArray()) {
        return false;
    }
    const QJsonArray array = doc.array();
    chapters.reserve(array.size());

    QString ruleId;
    qint64 lastOffset = -1;
    for (const auto &value : array) {
        if (!value.isObject()) {
            return false;
        }
        const QJsonObject item = value.toObject();
        NovelChapter chapter;
        chapter.title = item.value(QStringLiteral("title")).toString();
        chapter.startOffset = item.value(QStringLiteral("startOffset")).toInteger(-1);
        if (chapter.startOffset < 0 || chapter.title.isEmpty()) {
            return false;
        }
        // 偏移必须严格递增：坏掉的缓存宁可当未命中重扫，也不能让二分读出乱章
        if (chapter.startOffset <= lastOffset) {
            return false;
        }
        lastOffset = chapter.startOffset;
        if (item.contains(QStringLiteral("ruleID"))) {
            ruleId = item.value(QStringLiteral("ruleID")).toString();
        }
        chapter.ruleId = ruleId;
        chapters.append(chapter);
    }

    if (chapters.isEmpty()) {
        return false;
    }
    if (out) {
        *out = chapters;
    }
    return true;
}

} // namespace myhub
