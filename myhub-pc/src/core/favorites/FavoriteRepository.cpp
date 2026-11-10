#include "FavoriteRepository.h"

#include "core/database/AppDatabase.h"
#include "core/utils/AppLogger.h"

#include <QDateTime>
#include <QUuid>

namespace myhub {
namespace {

constexpr auto kSelectColumns =
    "SELECT connectionID, filePath, mediaType, size, createdAt FROM favorite";

FavoriteRecord rowToRecord(const QVariantMap &row)
{
    FavoriteRecord record;
    record.connectionId = row.value(QStringLiteral("connectionID")).toString();
    record.filePath = row.value(QStringLiteral("filePath")).toString();
    record.mediaType = row.value(QStringLiteral("mediaType")).toString();
    record.size = row.value(QStringLiteral("size")).toLongLong();
    record.createdAt = row.value(QStringLiteral("createdAt")).toLongLong();
    return record;
}

/// 键的编码：路径里可能有换行吗？不可能 —— 但用 '\n' 拼比 '|' 更不可能与路径撞车
QString encodeKey(const QString &connectionId, const QString &filePath)
{
    return connectionId + QLatin1Char('\n') + filePath;
}

} // namespace

FavoriteRepository &FavoriteRepository::instance()
{
    static FavoriteRepository repository;
    return repository;
}

// 构造函数私有且无默认参数：避免被当作可默认构造的 QML 单例（同 ProgressRepository）
FavoriteRepository::FavoriteRepository(QObject *parent)
    : QObject(parent)
{}

FavoriteRepository::~FavoriteRepository() = default;

QList<FavoriteRecord> FavoriteRepository::list() const
{
    QList<FavoriteRecord> records;
    auto &db = AppDatabase::instance();
    if (!db.isOpen()) {
        return records;
    }

    const auto rows = db.query(QStringLiteral("%1 ORDER BY createdAt DESC, filePath ASC")
                                   .arg(QLatin1String(kSelectColumns)));
    records.reserve(rows.size());
    for (const auto &row : rows) {
        records.append(rowToRecord(row));
    }
    return records;
}

QStringList FavoriteRepository::keys() const
{
    QStringList out;
    auto &db = AppDatabase::instance();
    if (!db.isOpen()) {
        return out;
    }

    const auto rows = db.query(QStringLiteral("SELECT connectionID, filePath FROM favorite"));
    out.reserve(rows.size());
    for (const auto &row : rows) {
        out.append(encodeKey(row.value(QStringLiteral("connectionID")).toString(),
                             row.value(QStringLiteral("filePath")).toString()));
    }
    return out;
}

bool FavoriteRepository::contains(const QString &connectionId, const QString &filePath) const
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen() || connectionId.isEmpty() || filePath.isEmpty()) {
        return false;
    }
    return db.queryScalar(QStringLiteral("SELECT COUNT(*) FROM favorite "
                                         "WHERE connectionID = ? AND filePath = ?"),
                          {connectionId, filePath})
               .toInt()
        > 0;
}

bool FavoriteRepository::add(const FavoriteRecord &record)
{
    if (!record.isValid()) {
        return false;
    }
    auto &db = AppDatabase::instance();
    if (!db.isOpen()) {
        MH_WARN(Database, QStringLiteral("favorite add before database is open"));
        return false;
    }

    // 已收藏则只刷新类型/大小，保留原收藏时间（顺序不乱跳）
    const bool ok = db.execute(
        QStringLiteral(
            "INSERT INTO favorite (id, connectionID, filePath, mediaType, size, createdAt) "
            "VALUES (?, ?, ?, ?, ?, ?) "
            "ON CONFLICT(connectionID, filePath) DO UPDATE SET "
            " mediaType = excluded.mediaType, size = excluded.size"),
        {QUuid::createUuid().toString(QUuid::WithoutBraces), record.connectionId, record.filePath,
         record.mediaType, record.size,
         record.createdAt > 0 ? record.createdAt : QDateTime::currentMSecsSinceEpoch()});
    if (!ok) {
        MH_ERROR(Database, QStringLiteral("favorite add failed: %1").arg(db.lastError()));
        return false;
    }

    emit favoriteChanged(record.connectionId, record.filePath, true);
    return true;
}

bool FavoriteRepository::remove(const QString &connectionId, const QString &filePath)
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen() || connectionId.isEmpty() || filePath.isEmpty()) {
        return false;
    }
    // 不存在的键不发「取消收藏」信号：否则订阅方要区分「真删了」和「本来就没有」
    if (!contains(connectionId, filePath)) {
        return false;
    }
    if (!db.execute(QStringLiteral("DELETE FROM favorite WHERE connectionID = ? AND filePath = ?"),
                    {connectionId, filePath})) {
        MH_ERROR(Database, QStringLiteral("favorite delete failed: %1").arg(db.lastError()));
        return false;
    }

    emit favoriteChanged(connectionId, filePath, false);
    return true;
}

bool FavoriteRepository::toggle(const FavoriteRecord &record, bool *nowFavorite)
{
    if (!record.isValid()) {
        if (nowFavorite) {
            *nowFavorite = false;
        }
        return false;
    }

    if (contains(record.connectionId, record.filePath)) {
        const bool ok = remove(record.connectionId, record.filePath);
        if (nowFavorite) {
            *nowFavorite = false;
        }
        return ok;
    }

    const bool ok = add(record);
    if (nowFavorite) {
        *nowFavorite = ok;
    }
    return ok;
}

int FavoriteRepository::removeSubtree(const QString &connectionId, const QString &path)
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen() || connectionId.isEmpty() || path.isEmpty()) {
        return 0;
    }

    // 收藏量在几十条量级：先取回本连接的全部路径，再在内存里判前缀 ——
    // 不给 LIKE 拼 ESCAPE（路径里可能含 % 和 _），同 ProgressRepository 的处理。
    const QString prefix = path + QLatin1Char('/');
    const auto rows = db.query(
        QStringLiteral("SELECT filePath FROM favorite WHERE connectionID = ?"), {connectionId});

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

    int removed = 0;
    for (const QString &target : targets) {
        if (!db.execute(
                QStringLiteral("DELETE FROM favorite WHERE connectionID = ? AND filePath = ?"),
                {connectionId, target})) {
            MH_ERROR(Database, QStringLiteral("favorite delete failed: %1").arg(db.lastError()));
            continue;
        }
        ++removed;
        emit favoriteChanged(connectionId, target, false);
    }
    return removed;
}

int FavoriteRepository::renamePath(const QString &connectionId, const QString &oldPath,
                                   const QString &newPath)
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen() || connectionId.isEmpty() || oldPath.isEmpty() || newPath.isEmpty()
        || oldPath == newPath) {
        return 0;
    }

    const QString prefix = oldPath + QLatin1Char('/');
    const auto rows = db.query(
        QStringLiteral("SELECT id, filePath FROM favorite WHERE connectionID = ?"), {connectionId});

    struct Target
    {
        QString id;
        QString oldFilePath;
        QString newFilePath;
    };
    QList<Target> targets;
    for (const auto &row : rows) {
        const QString rowPath = row.value(QStringLiteral("filePath")).toString();
        if (rowPath != oldPath && !rowPath.startsWith(prefix)) {
            continue;
        }
        targets.append({row.value(QStringLiteral("id")).toString(), rowPath,
                        newPath + rowPath.mid(oldPath.size())});
    }
    if (targets.isEmpty()) {
        return 0;
    }

    int updated = 0;
    for (const Target &target : targets) {
        if (!db.execute(QStringLiteral("UPDATE favorite SET filePath = ? WHERE id = ?"),
                        {target.newFilePath, target.id})) {
            MH_ERROR(Database, QStringLiteral("favorite rename failed: %1").arg(db.lastError()));
            continue;
        }
        ++updated;
        // 先报旧路径被移除、再报新路径被收藏：键集缓存的顺序无关，但语义要成对
        emit favoriteChanged(connectionId, target.oldFilePath, false);
        emit favoriteChanged(connectionId, target.newFilePath, true);
    }
    return updated;
}

int FavoriteRepository::count() const
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen()) {
        return 0;
    }
    return db.queryScalar(QStringLiteral("SELECT COUNT(*) FROM favorite")).toInt();
}

} // namespace myhub
