#include "ProgressRepository.h"

#include "core/database/AppDatabase.h"
#include "core/storage/StoragePath.h"
#include "core/utils/AppLogger.h"

#include <QDateTime>
#include <QJsonDocument>
#include <QJsonObject>
#include <QUuid>
#include <QVariantList>

namespace myhub {
namespace {

constexpr qint64 kNearEndThresholdMs = 3000;

QString encodeProgress(const QVariantMap &progress)
{
    return QString::fromUtf8(
        QJsonDocument(QJsonObject::fromVariantMap(progress)).toJson(QJsonDocument::Compact));
}

QVariantMap decodeProgress(const QString &json)
{
    const auto doc = QJsonDocument::fromJson(json.toUtf8());
    return doc.isObject() ? doc.object().toVariantMap() : QVariantMap();
}

ProgressRecord rowToRecord(const QVariantMap &row)
{
    ProgressRecord record;
    record.connectionId = row.value(QStringLiteral("connectionID")).toString();
    record.path = row.value(QStringLiteral("filePath")).toString();
    record.mediaType = row.value(QStringLiteral("mediaType")).toString();
    record.title = row.value(QStringLiteral("title")).toString();
    record.cover = row.value(QStringLiteral("cover")).toString();
    record.progress = decodeProgress(row.value(QStringLiteral("progressJSON")).toString());
    record.percent = row.value(QStringLiteral("percent")).toDouble();
    record.finished = row.value(QStringLiteral("finished")).toInt() != 0;
    record.updatedAt = row.value(QStringLiteral("updatedAt")).toLongLong();
    return record;
}

constexpr auto kSelectColumns = "SELECT connectionID, filePath, mediaType, title, cover, "
                                "progressJSON, percent, finished, updatedAt FROM readingProgress";

} // namespace

ProgressRepository &ProgressRepository::instance()
{
    static ProgressRepository repository;
    return repository;
}

// 构造函数私有且无默认参数：避免被当作可默认构造的 QML 单例（§4.4 渲染面纪律同款坑）
ProgressRepository::ProgressRepository(QObject *parent)
    : QObject(parent)
{}

ProgressRepository::~ProgressRepository() = default;

bool ProgressRepository::find(const QString &connectionId, const QString &path,
                              ProgressRecord *out) const
{
    if (connectionId.isEmpty() || path.isEmpty() || !out) {
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
    *out = rowToRecord(rows.first());
    return true;
}

QList<ProgressRecord> ProgressRepository::recent(int limit) const
{
    QList<ProgressRecord> records;
    auto &db = AppDatabase::instance();
    if (!db.isOpen() || limit <= 0) {
        return records;
    }

    const auto rows = db.query(
        QStringLiteral("%1 ORDER BY updatedAt DESC LIMIT ?").arg(QLatin1String(kSelectColumns)),
        {limit});
    records.reserve(rows.size());
    for (const auto &row : rows) {
        records.append(rowToRecord(row));
    }
    return records;
}

QHash<QString, ProgressBrief> ProgressRepository::briefs(const QString &connectionId) const
{
    QHash<QString, ProgressBrief> map;
    if (connectionId.isEmpty()) {
        return map;
    }
    auto &db = AppDatabase::instance();
    if (!db.isOpen()) {
        return map;
    }

    const auto rows =
        db.query(QStringLiteral("SELECT filePath, percent, finished FROM readingProgress "
                                "WHERE connectionID = ?"),
                 {connectionId});
    map.reserve(rows.size());
    for (const auto &row : rows) {
        ProgressBrief brief;
        brief.percent = row.value(QStringLiteral("percent")).toDouble();
        brief.finished = row.value(QStringLiteral("finished")).toInt() != 0;
        map.insert(row.value(QStringLiteral("filePath")).toString(), brief);
    }
    return map;
}

bool ProgressRepository::upsert(ProgressRecord record)
{
    if (!record.isValid()) {
        return false;
    }
    auto &db = AppDatabase::instance();
    if (!db.isOpen()) {
        MH_WARN(App, QStringLiteral("progress upsert before database is open"));
        return false;
    }

    record.updatedAt = QDateTime::currentMSecsSinceEpoch();

    // 唯一索引 (connectionID, filePath)：同一文件的多次上报只更新同一行。
    // cover 不在更新列里 —— 播放侧不提供封面，不能把已有封面清空。
    const bool ok = db.execute(
        QStringLiteral("INSERT INTO readingProgress "
                       "(id, connectionID, filePath, mediaType, title, cover, progressJSON, "
                       " percent, finished, updatedAt) "
                       "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) "
                       "ON CONFLICT(connectionID, filePath) DO UPDATE SET "
                       " mediaType = excluded.mediaType, title = excluded.title, "
                       " progressJSON = excluded.progressJSON, percent = excluded.percent, "
                       " finished = excluded.finished, updatedAt = excluded.updatedAt"),
        {QUuid::createUuid().toString(QUuid::WithoutBraces), record.connectionId, record.path,
         record.mediaType, record.title, record.cover.isEmpty() ? QVariant() : record.cover,
         encodeProgress(record.progress), record.percent, record.finished ? 1 : 0,
         record.updatedAt});

    if (!ok) {
        MH_ERROR(Player, QStringLiteral("progress upsert failed: %1").arg(db.lastError()));
        return false;
    }

    emit progressChanged(record.connectionId, record.path);
    return true;
}

bool ProgressRepository::remove(const QString &connectionId, const QString &path)
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen()) {
        return false;
    }
    if (!db.execute(QStringLiteral("DELETE FROM readingProgress "
                                   "WHERE connectionID = ? AND filePath = ?"),
                    {connectionId, path})) {
        MH_ERROR(Player, QStringLiteral("progress delete failed: %1").arg(db.lastError()));
        return false;
    }
    emit progressRemoved(connectionId, path);
    return true;
}

int ProgressRepository::removeSubtree(const QString &connectionId, const QString &path)
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen() || connectionId.isEmpty() || path.isEmpty()) {
        return 0;
    }

    // 记录数在几十条量级：一次取回本连接的全部路径再在内存里判断前缀，
    // 比给 LIKE 拼 ESCAPE 更不容易出错（路径里可能含 % 和 _）。
    const QString prefix = path + QLatin1Char('/');
    const auto rows =
        db.query(QStringLiteral("SELECT filePath FROM readingProgress WHERE connectionID = ?"),
                 {connectionId});

    QStringList targets;
    targets.reserve(rows.size());
    for (const auto &row : rows) {
        const QString rowPath = row.value(QStringLiteral("filePath")).toString();
        if (rowPath == path || rowPath.startsWith(prefix)) {
            targets.append(rowPath);
        }
    }
    if (targets.isEmpty()) {
        return 0;
    }

    for (const QString &target : targets) {
        if (!db.execute(QStringLiteral("DELETE FROM readingProgress "
                                       "WHERE connectionID = ? AND filePath = ?"),
                        {connectionId, target})) {
            MH_ERROR(Player, QStringLiteral("progress delete failed: %1").arg(db.lastError()));
            continue;
        }
        emit progressRemoved(connectionId, target);
    }
    return static_cast<int>(targets.size());
}

int ProgressRepository::renamePath(const QString &connectionId, const QString &oldPath,
                                   const QString &newPath)
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen() || connectionId.isEmpty() || oldPath.isEmpty() || newPath.isEmpty()
        || oldPath == newPath) {
        return 0;
    }

    const QString prefix = oldPath + QLatin1Char('/');
    const auto rows = db.query(
        QStringLiteral("SELECT id, filePath, title FROM readingProgress WHERE connectionID = ?"),
        {connectionId});

    struct Target
    {
        QString id;
        QString oldFilePath;
        QString newFilePath;
        QString newTitle;
    };
    QList<Target> targets;
    for (const auto &row : rows) {
        const QString rowPath = row.value(QStringLiteral("filePath")).toString();
        if (rowPath != oldPath && !rowPath.startsWith(prefix)) {
            continue;
        }
        const QString moved = newPath + rowPath.mid(oldPath.size());
        const QString title = row.value(QStringLiteral("title")).toString();
        // 标题仍是「原文件名推导值」才跟着改名，用户/元数据来源的标题保持不动
        const QString newTitle =
            (title == StoragePath::baseName(rowPath)) ? StoragePath::baseName(moved) : title;
        targets.append({row.value(QStringLiteral("id")).toString(), rowPath, moved, newTitle});
    }
    if (targets.isEmpty()) {
        return 0;
    }

    int updated = 0;
    for (const Target &target : targets) {
        if (!db.execute(QStringLiteral("UPDATE readingProgress SET filePath = ?, title = ? "
                                       "WHERE id = ?"),
                        {target.newFilePath, target.newTitle, target.id})) {
            MH_ERROR(Player, QStringLiteral("progress rename failed: %1").arg(db.lastError()));
            continue;
        }
        ++updated;
        emit progressChanged(connectionId, target.newFilePath);
    }
    return updated;
}

int ProgressRepository::count() const
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen()) {
        return 0;
    }
    return db.queryScalar(QStringLiteral("SELECT COUNT(*) FROM readingProgress")).toInt();
}

qint64 ProgressRepository::resumePositionMs(const ProgressRecord &record)
{
    if (record.finished) {
        return 0;
    }
    const qint64 position = record.positionMs();
    if (position <= 0 || isNearEnd(position, record.durationMs())) {
        return 0;
    }
    return position;
}

bool ProgressRepository::isNearEnd(qint64 positionMs, qint64 durationMs)
{
    return durationMs > 0 && positionMs >= durationMs - kNearEndThresholdMs;
}

} // namespace myhub
