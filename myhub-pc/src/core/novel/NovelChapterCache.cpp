#include "NovelChapterCache.h"

#include "core/database/AppDatabase.h"
#include "core/text/TextCodec.h"
#include "core/utils/AppLogger.h"

#include <QDateTime>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QUuid>

namespace myhub {
namespace {

/// payload 版本：解码端不认识的版本一律当未命中，绝不猜字段含义
constexpr int kPayloadVersion = 1;

constexpr auto kSelectColumns = "SELECT fileSize, modTime, payload FROM novelChapter";

/// 影响行数取 sqlite 的 changes()：execute() 只回报语句是否成功，不回报改了几行
int changedRows(AppDatabase &db)
{
    return db.queryScalar(QStringLiteral("SELECT changes()")).toInt();
}

QString encodeTxt(const TxtChapterText &text)
{
    QJsonObject root;
    root.insert(QStringLiteral("v"), kPayloadVersion);
    root.insert(QStringLiteral("title"), text.title);
    root.insert(QStringLiteral("encoding"), TextCodec::name(text.encoding));
    root.insert(QStringLiteral("start"), text.start);
    root.insert(QStringLiteral("end"), text.end);
    root.insert(QStringLiteral("firstBodyLine"), text.firstBodyLine);
    root.insert(QStringLiteral("truncated"), text.truncated);

    QJsonArray lines;
    for (const TxtLine &line : text.lines) {
        QJsonObject item;
        item.insert(QStringLiteral("t"), line.text);
        item.insert(QStringLiteral("s"), line.start);
        item.insert(QStringLiteral("e"), line.end);
        lines.append(item);
    }
    root.insert(QStringLiteral("lines"), lines);
    return QString::fromUtf8(QJsonDocument(root).toJson(QJsonDocument::Compact));
}

bool decodeTxt(const QByteArray &json, TxtChapterText *out)
{
    const QJsonDocument doc = QJsonDocument::fromJson(json);
    if (!doc.isObject()) {
        return false;
    }
    const QJsonObject root = doc.object();
    if (root.value(QStringLiteral("v")).toInt() != kPayloadVersion) {
        return false;
    }

    TxtChapterText text;
    text.title = root.value(QStringLiteral("title")).toString();
    text.encoding = TextCodec::fromName(root.value(QStringLiteral("encoding")).toString());
    text.start = root.value(QStringLiteral("start")).toInteger(-1);
    text.end = root.value(QStringLiteral("end")).toInteger(-1);
    text.firstBodyLine = root.value(QStringLiteral("firstBodyLine")).toInt();
    text.truncated = root.value(QStringLiteral("truncated")).toBool();

    const QJsonArray lines = root.value(QStringLiteral("lines")).toArray();
    if (lines.isEmpty() || text.start < 0 || text.firstBodyLine < 0
        || text.firstBodyLine > lines.size()) {
        return false;
    }

    qint64 lastStart = -1;
    for (const auto &value : lines) {
        if (!value.isObject()) {
            return false;
        }
        const QJsonObject item = value.toObject();
        TxtLine line;
        line.text = item.value(QStringLiteral("t")).toString();
        line.start = item.value(QStringLiteral("s")).toInteger(-1);
        line.end = item.value(QStringLiteral("e")).toInteger(-1);
        // 偏移必须严格递增：坏掉的缓存宁可当未命中重读，也不能让锚点算出乱位置
        if (line.start < 0 || line.end < line.start || line.start <= lastStart) {
            return false;
        }
        lastStart = line.start;
        text.lines.append(line);
    }

    *out = text;
    return true;
}

QString encodeEpub(const QStringList &paragraphs)
{
    QJsonArray array;
    for (const QString &paragraph : paragraphs) {
        array.append(paragraph);
    }
    QJsonObject root;
    root.insert(QStringLiteral("v"), kPayloadVersion);
    root.insert(QStringLiteral("paragraphs"), array);
    return QString::fromUtf8(QJsonDocument(root).toJson(QJsonDocument::Compact));
}

bool decodeEpub(const QByteArray &json, QStringList *out)
{
    const QJsonDocument doc = QJsonDocument::fromJson(json);
    if (!doc.isObject()) {
        return false;
    }
    const QJsonObject root = doc.object();
    if (root.value(QStringLiteral("v")).toInt() != kPayloadVersion) {
        return false;
    }
    const QJsonArray array = root.value(QStringLiteral("paragraphs")).toArray();
    // 空章是**合法**的（封面页 / 纯图片页解不出文字），所以这里只校类型不校数量
    QStringList paragraphs;
    paragraphs.reserve(array.size());
    for (const auto &value : array) {
        if (!value.isString()) {
            return false;
        }
        paragraphs.append(value.toString());
    }
    *out = paragraphs;
    return true;
}

/// 落库前统一压一遍：正文 JSON 的冗余（键名、转义）压掉约六成
QByteArray pack(const QString &json)
{
    return qCompress(json.toUtf8(), 6);
}

} // namespace

bool NovelChapterCache::Fingerprint::matches(qint64 size, qint64 modTimeMs) const
{
    return fileSize == size && modTime == modTimeMs;
}

bool NovelChapterCache::store(const QString &connectionId, const QString &path,
                              const Fingerprint &fingerprint, int chapter, const QString &title,
                              const QByteArray &payload)
{
    if (connectionId.isEmpty() || path.isEmpty() || chapter < 0 || payload.isEmpty()) {
        return false;
    }
    if (!fingerprint.known()) {
        // 离线打开时不知道指纹：写进去的行永远对不上号，之后在线打开只会当它是垃圾。
        // 这一章本来也在内存预取里，不落盘不影响阅读
        return false;
    }
    if (payload.size() > kMaxPayloadBytes) {
        // 超大章节（多为「整本单章」兜底）不落库：写一次几十 MB，读回来也不会更快
        return false;
    }
    auto &db = AppDatabase::instance();
    if (!db.isOpen()) {
        return false;
    }

    const bool ok = db.execute(
        QStringLiteral("INSERT INTO novelChapter "
                       "(id, connectionID, filePath, fileSize, modTime, chapterIndex, title, "
                       " payload, updatedAt) "
                       "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) "
                       "ON CONFLICT(connectionID, filePath, chapterIndex) DO UPDATE SET "
                       " fileSize = excluded.fileSize, modTime = excluded.modTime, "
                       " title = excluded.title, payload = excluded.payload, "
                       " updatedAt = excluded.updatedAt"),
        {QUuid::createUuid().toString(QUuid::WithoutBraces), connectionId, path,
         fingerprint.fileSize, fingerprint.modTime, chapter, title, payload,
         QDateTime::currentMSecsSinceEpoch()});
    if (!ok) {
        MH_WARN(NovelIndex,
                QStringLiteral("章节落库失败：%1 第 %2 章（%3）")
                    .arg(path)
                    .arg(chapter)
                    .arg(db.lastError()));
    }
    return ok;
}

QByteArray NovelChapterCache::fetch(const QString &connectionId, const QString &path,
                                    const Fingerprint &fingerprint, int chapter)
{
    if (connectionId.isEmpty() || path.isEmpty() || chapter < 0) {
        return {};
    }
    auto &db = AppDatabase::instance();
    if (!db.isOpen()) {
        return {};
    }

    const auto rows = db.query(QStringLiteral("%1 WHERE connectionID = ? AND filePath = ? "
                                              "AND chapterIndex = ?")
                                   .arg(QLatin1String(kSelectColumns)),
                               {connectionId, path, chapter});
    if (rows.isEmpty()) {
        return {};
    }
    const QVariantMap &row = rows.constFirst();
    if (!fingerprint.accepts(row.value(QStringLiteral("fileSize")).toLongLong(),
                             row.value(QStringLiteral("modTime")).toLongLong())) {
        return {};
    }
    return row.value(QStringLiteral("payload")).toByteArray();
}

bool NovelChapterCache::loadTxt(const QString &connectionId, const QString &path,
                                const Fingerprint &fingerprint, int chapter, TxtChapterText *out)
{
    const QByteArray payload = fetch(connectionId, path, fingerprint, chapter);
    if (payload.isEmpty()) {
        return false;
    }
    const QByteArray json = qUncompress(payload);
    if (json.isEmpty() || !decodeTxt(json, out)) {
        MH_INFO(NovelIndex,
                QStringLiteral("章节缓存损坏，按未命中处理：%1 第 %2 章").arg(path).arg(chapter));
        return false;
    }
    return true;
}

bool NovelChapterCache::saveTxt(const QString &connectionId, const QString &path,
                                const Fingerprint &fingerprint, int chapter,
                                const TxtChapterText &text)
{
    if (text.isEmpty()) {
        return false; // 空章不占缓存位：读回来还是空的，直接重读更省事
    }
    return store(connectionId, path, fingerprint, chapter, text.title, pack(encodeTxt(text)));
}

bool NovelChapterCache::loadEpub(const QString &connectionId, const QString &path,
                                 const Fingerprint &fingerprint, int chapter, QStringList *out)
{
    const QByteArray payload = fetch(connectionId, path, fingerprint, chapter);
    if (payload.isEmpty()) {
        return false;
    }
    const QByteArray json = qUncompress(payload);
    if (json.isEmpty() || !decodeEpub(json, out)) {
        MH_INFO(NovelIndex,
                QStringLiteral("章节缓存损坏，按未命中处理：%1 第 %2 章").arg(path).arg(chapter));
        return false;
    }
    return true;
}

bool NovelChapterCache::saveEpub(const QString &connectionId, const QString &path,
                                 const Fingerprint &fingerprint, int chapter,
                                 const QStringList &paragraphs)
{
    if (paragraphs.isEmpty()) {
        return false;
    }
    return store(connectionId, path, fingerprint, chapter, QString(), pack(encodeEpub(paragraphs)));
}

int NovelChapterCache::dropStale(const QString &connectionId, const QString &path,
                                 const Fingerprint &fingerprint)
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen() || connectionId.isEmpty() || path.isEmpty() || !fingerprint.known()) {
        // 指纹未知（离线 / stat 失败）时不能删：那正是最需要这份缓存的时候
        return 0;
    }
    const bool ok = db.execute(
        QStringLiteral("DELETE FROM novelChapter WHERE connectionID = ? AND filePath = ? "
                       "AND (fileSize <> ? OR modTime <> ?)"),
        {connectionId, path, fingerprint.fileSize, fingerprint.modTime});
    if (!ok) {
        return 0;
    }
    const int removed = changedRows(db);
    if (removed > 0) {
        MH_INFO(NovelIndex,
                QStringLiteral("文件已变，丢弃 %1 章旧缓存：%2").arg(removed).arg(path));
    }
    return removed;
}

int NovelChapterCache::trim(int keep)
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen() || keep <= 0) {
        return 0;
    }
    // 按最后访问时间淘汰：读者正在读的那本必然是最新的，不会被自己的活跃度挤掉
    const bool ok =
        db.execute(QStringLiteral("DELETE FROM novelChapter WHERE id NOT IN "
                                  "(SELECT id FROM novelChapter ORDER BY updatedAt DESC LIMIT ?)"),
                   {keep});
    return ok ? changedRows(db) : 0;
}

int NovelChapterCache::remove(const QString &connectionId, const QString &path)
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen() || connectionId.isEmpty() || path.isEmpty()) {
        return 0;
    }
    const bool ok = db.execute(
        QStringLiteral("DELETE FROM novelChapter WHERE connectionID = ? AND filePath = ?"),
        {connectionId, path});
    return ok ? changedRows(db) : 0;
}

int NovelChapterCache::removeSubtree(const QString &connectionId, const QString &path)
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen() || connectionId.isEmpty() || path.isEmpty()) {
        return 0;
    }

    // 与 `NovelIndexStore::removeSubtree` 同一套：文件路径里可能含 % 与 _，
    // 取回本连接的全部路径在内存里判前缀，比给 LIKE 拼 ESCAPE 稳
    const QString prefix = path + QLatin1Char('/');
    const auto rows = db.query(
        QStringLiteral("SELECT DISTINCT filePath FROM novelChapter WHERE connectionID = ?"),
        {connectionId});

    int removed = 0;
    for (const auto &row : rows) {
        const QString rowPath = row.value(QStringLiteral("filePath")).toString();
        if (rowPath != path && !rowPath.startsWith(prefix)) {
            continue;
        }
        if (db.execute(
                QStringLiteral("DELETE FROM novelChapter WHERE connectionID = ? AND filePath = ?"),
                {connectionId, rowPath})) {
            removed += changedRows(db);
        }
    }
    if (removed > 0) {
        MH_INFO(NovelIndex,
                QStringLiteral("删除目录，清掉 %1 行章节缓存：%2").arg(removed).arg(path));
    }
    return removed;
}

int NovelChapterCache::renamePath(const QString &connectionId, const QString &oldPath,
                                  const QString &newPath)
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen() || connectionId.isEmpty() || oldPath.isEmpty() || newPath.isEmpty()
        || oldPath == newPath) {
        return 0;
    }

    const QString prefix = oldPath + QLatin1Char('/');
    const auto rows = db.query(
        QStringLiteral("SELECT DISTINCT filePath FROM novelChapter WHERE connectionID = ?"),
        {connectionId});

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
        // 覆盖式移动：目标路径可能已有被覆盖那本书的缓存行。先清掉再改路径 ——
        // 直接 UPDATE 会撞 `(connectionID, filePath, chapterIndex)` 唯一键
        db.execute(
            QStringLiteral("DELETE FROM novelChapter WHERE connectionID = ? AND filePath = ?"),
            {connectionId, target});
        if (db.execute(QStringLiteral("UPDATE novelChapter SET filePath = ? "
                                      "WHERE connectionID = ? AND filePath = ?"),
                       {target, connectionId, rowPath})) {
            updated += changedRows(db);
        }
    }
    if (updated > 0) {
        MH_INFO(
            NovelIndex,
            QStringLiteral("缓存路径随文件改写 %1 行：%2 → %3").arg(updated).arg(oldPath, newPath));
    }
    return updated;
}

QList<int> NovelChapterCache::cachedChapters(const QString &connectionId, const QString &path)
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen() || connectionId.isEmpty() || path.isEmpty()) {
        return {};
    }
    const auto rows = db.query(QStringLiteral("SELECT chapterIndex FROM novelChapter "
                                              "WHERE connectionID = ? AND filePath = ? "
                                              "ORDER BY chapterIndex"),
                               {connectionId, path});
    QList<int> chapters;
    chapters.reserve(rows.size());
    for (const QVariantMap &row : rows) {
        chapters.append(row.value(QStringLiteral("chapterIndex")).toInt());
    }
    return chapters;
}

int NovelChapterCache::count()
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen()) {
        return 0;
    }
    return db.queryScalar(QStringLiteral("SELECT COUNT(*) FROM novelChapter")).toInt();
}

} // namespace myhub
