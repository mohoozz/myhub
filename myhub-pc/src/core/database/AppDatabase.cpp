#include "AppDatabase.h"
#include "Migrations.h"
#include "../utils/AppLogger.h"
#include "../utils/AppPaths.h"

#include <QDateTime>
#include <QDir>
#include <QFileInfo>
#include <QMutex>
#include <QMutexLocker>
#include <QRecursiveMutex>

#include <sqlite3.h>

namespace myhub {

struct AppDatabase::Private
{
    sqlite3 *db = nullptr;
    mutable QRecursiveMutex mutex;
    mutable QString lastError;
    QString filePath;
    int transactionDepth = 0;
};

AppDatabase::AppDatabase(QObject *parent)
    : QObject(parent)
    , d(new Private)
{}

AppDatabase::~AppDatabase()
{
    close();
    delete d;
}

AppDatabase &AppDatabase::instance()
{
    static AppDatabase s_instance;
    return s_instance;
}

bool AppDatabase::isOpen() const
{
    QMutexLocker lock(&d->mutex);
    return d->db != nullptr;
}

QString AppDatabase::lastError() const
{
    QMutexLocker lock(&d->mutex);
    return d->lastError;
}

bool AppDatabase::open(const QString &filePath)
{
    QMutexLocker lock(&d->mutex);
    if (d->db)
        return true;

    d->filePath = filePath.isEmpty() ? AppPaths::databaseFile() : filePath;
    AppPaths::ensureDir(QFileInfo(d->filePath).absolutePath());

    const int rc = sqlite3_open_v2(
        d->filePath.toUtf8().constData(), &d->db,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nullptr);
    if (rc != SQLITE_OK) {
        d->lastError = QString::fromUtf8(sqlite3_errmsg(d->db));
        MH_ERROR(Database, QStringLiteral("open failed: %1").arg(d->lastError));
        if (d->db) {
            sqlite3_close(d->db);
            d->db = nullptr;
        }
        return false;
    }

    lock.unlock();

    // WAL 提升并发读写表现；外键级联为 §5.3 约束所必需
    execute(QStringLiteral("PRAGMA journal_mode=WAL"));
    execute(QStringLiteral("PRAGMA synchronous=NORMAL"));
    execute(QStringLiteral("PRAGMA foreign_keys=ON"));
    execute(QStringLiteral("PRAGMA busy_timeout=5000"));

    if (!Migrations::migrate(*this)) {
        MH_ERROR(Database, QStringLiteral("migration failed: %1").arg(lastError()));
        close();
        return false;
    }

    MH_INFO(Database,
            QStringLiteral("opened %1 (schema v%2)").arg(d->filePath).arg(schemaVersion()));

    backupIfNeeded();
    emit ready();
    return true;
}

void AppDatabase::close()
{
    QMutexLocker lock(&d->mutex);
    if (!d->db)
        return;
    sqlite3_close(d->db);
    d->db = nullptr;
}

int AppDatabase::schemaVersion() const
{
    return queryScalar(QStringLiteral("PRAGMA user_version")).toInt();
}

// 绑定参数：按 QVariant 类型分派
static void bindValue(sqlite3_stmt *stmt, int index, const QVariant &v)
{
    switch (v.typeId()) {
    case QMetaType::UnknownType:
        sqlite3_bind_null(stmt, index);
        break;
    case QMetaType::Bool:
        sqlite3_bind_int(stmt, index, v.toBool() ? 1 : 0);
        break;
    case QMetaType::Int:
    case QMetaType::UInt:
    case QMetaType::LongLong:
    case QMetaType::ULongLong:
        sqlite3_bind_int64(stmt, index, v.toLongLong());
        break;
    case QMetaType::Double:
    case QMetaType::Float:
        sqlite3_bind_double(stmt, index, v.toDouble());
        break;
    case QMetaType::QByteArray: {
        const QByteArray b = v.toByteArray();
        sqlite3_bind_blob(stmt, index, b.constData(), b.size(), SQLITE_TRANSIENT);
        break;
    }
    case QMetaType::QDateTime: {
        // 统一存 Unix 秒，与 iOS 端一致
        const QDateTime dt = v.toDateTime();
        if (dt.isValid())
            sqlite3_bind_int64(stmt, index, dt.toSecsSinceEpoch());
        else
            sqlite3_bind_null(stmt, index);
        break;
    }
    default: {
        if (!v.isValid() || v.isNull()) {
            sqlite3_bind_null(stmt, index);
            break;
        }
        const QByteArray s = v.toString().toUtf8();
        sqlite3_bind_text(stmt, index, s.constData(), s.size(), SQLITE_TRANSIENT);
        break;
    }
    }
}

bool AppDatabase::execute(const QString &sql, const QVariantList &params)
{
    QMutexLocker lock(&d->mutex);
    if (!d->db) {
        d->lastError = QStringLiteral("database not open");
        return false;
    }

    sqlite3_stmt *stmt = nullptr;
    const QByteArray utf8 = sql.toUtf8();
    if (sqlite3_prepare_v2(d->db, utf8.constData(), utf8.size(), &stmt, nullptr) != SQLITE_OK) {
        d->lastError =
            QStringLiteral("%1 | SQL: %2").arg(QString::fromUtf8(sqlite3_errmsg(d->db)), sql);
        return false;
    }

    for (int i = 0; i < params.size(); ++i)
        bindValue(stmt, i + 1, params.at(i));

    const int rc = sqlite3_step(stmt);
    const bool ok = (rc == SQLITE_DONE || rc == SQLITE_ROW);
    if (!ok) {
        d->lastError =
            QStringLiteral("%1 | SQL: %2").arg(QString::fromUtf8(sqlite3_errmsg(d->db)), sql);
    }
    sqlite3_finalize(stmt);
    return ok;
}

QList<QVariantMap> AppDatabase::query(const QString &sql, const QVariantList &params) const
{
    QMutexLocker lock(&d->mutex);
    QList<QVariantMap> rows;
    if (!d->db) {
        d->lastError = QStringLiteral("database not open");
        return rows;
    }

    sqlite3_stmt *stmt = nullptr;
    const QByteArray utf8 = sql.toUtf8();
    if (sqlite3_prepare_v2(d->db, utf8.constData(), utf8.size(), &stmt, nullptr) != SQLITE_OK) {
        d->lastError =
            QStringLiteral("%1 | SQL: %2").arg(QString::fromUtf8(sqlite3_errmsg(d->db)), sql);
        return rows;
    }

    for (int i = 0; i < params.size(); ++i)
        bindValue(stmt, i + 1, params.at(i));

    const int columns = sqlite3_column_count(stmt);
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        QVariantMap row;
        for (int c = 0; c < columns; ++c) {
            const QString name = QString::fromUtf8(sqlite3_column_name(stmt, c));
            switch (sqlite3_column_type(stmt, c)) {
            case SQLITE_INTEGER:
                row.insert(name, static_cast<qint64>(sqlite3_column_int64(stmt, c)));
                break;
            case SQLITE_FLOAT:
                row.insert(name, sqlite3_column_double(stmt, c));
                break;
            case SQLITE_BLOB: {
                const void *blob = sqlite3_column_blob(stmt, c);
                const int len = sqlite3_column_bytes(stmt, c);
                row.insert(name, QByteArray(static_cast<const char *>(blob), len));
                break;
            }
            case SQLITE_NULL:
                row.insert(name, QVariant());
                break;
            default:
                row.insert(name,
                           QString::fromUtf8(
                               reinterpret_cast<const char *>(sqlite3_column_text(stmt, c))));
                break;
            }
        }
        rows.append(row);
    }
    sqlite3_finalize(stmt);
    return rows;
}

QVariant AppDatabase::queryScalar(const QString &sql, const QVariantList &params) const
{
    const QList<QVariantMap> rows = query(sql, params);
    if (rows.isEmpty())
        return {};
    const QVariantMap &row = rows.first();
    if (row.isEmpty())
        return {};
    return row.first();
}

qint64 AppDatabase::lastInsertRowId() const
{
    QMutexLocker lock(&d->mutex);
    return d->db ? sqlite3_last_insert_rowid(d->db) : -1;
}

bool AppDatabase::beginTransaction()
{
    QMutexLocker lock(&d->mutex);
    if (d->transactionDepth++ > 0)
        return true; // 已在事务中，按嵌套计数处理
    lock.unlock();
    return execute(QStringLiteral("BEGIN IMMEDIATE"));
}

bool AppDatabase::commit()
{
    QMutexLocker lock(&d->mutex);
    if (d->transactionDepth <= 0)
        return false;
    if (--d->transactionDepth > 0)
        return true;
    lock.unlock();
    return execute(QStringLiteral("COMMIT"));
}

bool AppDatabase::rollback()
{
    QMutexLocker lock(&d->mutex);
    if (d->transactionDepth <= 0)
        return false;
    d->transactionDepth = 0;
    lock.unlock();
    return execute(QStringLiteral("ROLLBACK"));
}

bool AppDatabase::backupIfNeeded()
{
    const QString dir = AppPaths::backupDir();
    AppPaths::ensureDir(dir);

    // 每日最多一份
    const QString stamp = QDate::currentDate().toString(QStringLiteral("yyyy-MM-dd"));
    const QString target = dir + QStringLiteral("/myhub-%1.sqlite").arg(stamp);
    if (QFileInfo::exists(target))
        return true;
    return backupNow();
}

bool AppDatabase::backupNow()
{
    QMutexLocker lock(&d->mutex);
    if (!d->db)
        return false;

    const QString dir = AppPaths::backupDir();
    AppPaths::ensureDir(dir);
    const QString stamp = QDate::currentDate().toString(QStringLiteral("yyyy-MM-dd"));
    const QString target = dir + QStringLiteral("/myhub-%1.sqlite").arg(stamp);

    sqlite3 *dest = nullptr;
    if (sqlite3_open(target.toUtf8().constData(), &dest) != SQLITE_OK) {
        if (dest)
            sqlite3_close(dest);
        return false;
    }

    // 使用 SQLite 在线备份 API，WAL 模式下也能得到一致快照
    sqlite3_backup *bk = sqlite3_backup_init(dest, "main", d->db, "main");
    bool ok = false;
    if (bk) {
        ok = (sqlite3_backup_step(bk, -1) == SQLITE_DONE);
        sqlite3_backup_finish(bk);
    }
    sqlite3_close(dest);

    lock.unlock();
    if (ok) {
        MH_INFO(Database, QStringLiteral("backup written: %1").arg(target));
        pruneBackups();
    } else {
        MH_WARN(Database, QStringLiteral("backup failed: %1").arg(target));
        QFile::remove(target);
    }
    return ok;
}

void AppDatabase::pruneBackups()
{
    QDir dir(AppPaths::backupDir());
    if (!dir.exists())
        return;
    QFileInfoList files =
        dir.entryInfoList({QStringLiteral("myhub-*.sqlite")}, QDir::Files, QDir::Name);
    while (files.size() > 7) { // 保留最近 7 份（§2.3）
        QFile::remove(files.first().absoluteFilePath());
        files.removeFirst();
    }
}

} // namespace myhub
