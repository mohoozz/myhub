#include "Migrations.h"
#include "AppDatabase.h"
#include "../utils/AppLogger.h"

#include <QStringList>

namespace myhub {

bool Migrations::migrate(AppDatabase &db)
{
    const int current = db.schemaVersion();
    if (current >= kTargetVersion)
        return true;

    MH_INFO(Database,
            QStringLiteral("migrating schema v%1 -> v%2").arg(current).arg(kTargetVersion));

    if (!db.beginTransaction())
        return false;

    bool ok = true;
    if (ok && current < 1)
        ok = v1_initial(db);
    if (ok && current < 2)
        ok = v2_reading_fingerprint(db);

    if (!ok) {
        db.rollback();
        return false;
    }

    ok = db.execute(QStringLiteral("PRAGMA user_version=%1").arg(kTargetVersion));
    if (!ok) {
        db.rollback();
        return false;
    }

    return db.commit();
}

bool Migrations::v1_initial(AppDatabase &db)
{
    // 9 张表与 iOS 端同构（需求文档 §5.3），字段、唯一约束、级联与索引一一对应
    const QStringList statements = {
        // ---- 连接源 ----
        QStringLiteral(R"(
            CREATE TABLE IF NOT EXISTS connection (
                id          TEXT PRIMARY KEY,
                name        TEXT NOT NULL,
                type        TEXT NOT NULL,
                configJSON  TEXT NOT NULL DEFAULT '{}',
                mountPoint  TEXT NOT NULL,
                enabled     INTEGER NOT NULL DEFAULT 1,
                createdAt   INTEGER NOT NULL
            ))"),
        QStringLiteral("CREATE UNIQUE INDEX IF NOT EXISTS idx_connection_mount "
                       "ON connection(mountPoint)"),

        // ---- 收藏 ----
        QStringLiteral(R"(
            CREATE TABLE IF NOT EXISTS favorite (
                id           TEXT PRIMARY KEY,
                connectionID TEXT NOT NULL REFERENCES connection(id) ON DELETE CASCADE,
                filePath     TEXT NOT NULL,
                mediaType    TEXT NOT NULL DEFAULT '',
                size         INTEGER NOT NULL DEFAULT 0,
                createdAt    INTEGER NOT NULL
            ))"),
        QStringLiteral("CREATE UNIQUE INDEX IF NOT EXISTS idx_favorite_unique "
                       "ON favorite(connectionID, filePath)"),

        // ---- 阅读进度 ----
        QStringLiteral(R"(
            CREATE TABLE IF NOT EXISTS readingProgress (
                id           TEXT PRIMARY KEY,
                connectionID TEXT NOT NULL,
                filePath     TEXT NOT NULL,
                mediaType    TEXT NOT NULL DEFAULT '',
                title        TEXT NOT NULL DEFAULT '',
                cover        TEXT,
                progressJSON TEXT NOT NULL DEFAULT '{}',
                percent      REAL NOT NULL DEFAULT 0,
                finished     INTEGER NOT NULL DEFAULT 0,
                updatedAt    INTEGER NOT NULL
            ))"),
        QStringLiteral("CREATE UNIQUE INDEX IF NOT EXISTS idx_progress_unique "
                       "ON readingProgress(connectionID, filePath)"),
        QStringLiteral("CREATE INDEX IF NOT EXISTS idx_progress_updated "
                       "ON readingProgress(updatedAt DESC)"),

        // ---- 小说索引 ----
        QStringLiteral(R"(
            CREATE TABLE IF NOT EXISTS novelIndex (
                id           TEXT PRIMARY KEY,
                connectionID TEXT NOT NULL,
                filePath     TEXT NOT NULL,
                encoding     TEXT NOT NULL DEFAULT '',
                chaptersJSON TEXT NOT NULL DEFAULT '[]',
                fileSize     INTEGER NOT NULL DEFAULT 0,
                modTime      INTEGER NOT NULL DEFAULT 0
            ))"),
        QStringLiteral("CREATE UNIQUE INDEX IF NOT EXISTS idx_novelindex_unique "
                       "ON novelIndex(connectionID, filePath)"),

        // ---- 浏览器书签 ----
        QStringLiteral(R"(
            CREATE TABLE IF NOT EXISTS bookmark (
                id        TEXT PRIMARY KEY,
                title     TEXT NOT NULL DEFAULT '',
                url       TEXT NOT NULL,
                favicon   TEXT,
                createdAt INTEGER NOT NULL
            ))"),
        QStringLiteral("CREATE UNIQUE INDEX IF NOT EXISTS idx_bookmark_url "
                       "ON bookmark(url)"),

        // ---- 浏览器历史 ----
        QStringLiteral(R"(
            CREATE TABLE IF NOT EXISTS browserHistory (
                id        TEXT PRIMARY KEY,
                title     TEXT NOT NULL DEFAULT '',
                url       TEXT NOT NULL,
                favicon   TEXT,
                visitedAt INTEGER NOT NULL
            ))"),
        QStringLiteral("CREATE INDEX IF NOT EXISTS idx_history_visited "
                       "ON browserHistory(visitedAt DESC)"),

        // ---- 浏览器快捷入口 ----
        QStringLiteral(R"(
            CREATE TABLE IF NOT EXISTS browserShortcut (
                id        TEXT PRIMARY KEY,
                title     TEXT NOT NULL DEFAULT '',
                url       TEXT NOT NULL,
                sortOrder INTEGER NOT NULL DEFAULT 0
            ))"),

        // ---- 下载任务（PC-606）----
        QStringLiteral(R"(
            CREATE TABLE IF NOT EXISTS downloadTask (
                id           TEXT PRIMARY KEY,
                connectionID TEXT NOT NULL,
                remotePath   TEXT NOT NULL,
                localPath    TEXT NOT NULL DEFAULT '',
                status       TEXT NOT NULL DEFAULT 'pending',
                progress     REAL NOT NULL DEFAULT 0
            ))"),

        // ---- 动态项（PC-301 预留）----
        QStringLiteral(R"(
            CREATE TABLE IF NOT EXISTS feedItem (
                id          TEXT PRIMARY KEY,
                platform    TEXT NOT NULL,
                contentID   TEXT NOT NULL,
                type        TEXT NOT NULL DEFAULT '',
                title       TEXT NOT NULL DEFAULT '',
                cover       TEXT,
                url         TEXT NOT NULL DEFAULT '',
                publishedAt INTEGER NOT NULL DEFAULT 0
            ))"),
        QStringLiteral("CREATE UNIQUE INDEX IF NOT EXISTS idx_feed_unique "
                       "ON feedItem(platform, contentID)"),
    };

    for (const QString &sql : statements) {
        if (!db.execute(sql)) {
            MH_ERROR(Database, QStringLiteral("v1_initial failed: %1").arg(db.lastError()));
            return false;
        }
    }
    MH_INFO(Database, QStringLiteral("v1_initial applied"));
    return true;
}

bool Migrations::v2_reading_fingerprint(AppDatabase &db)
{
    // 文件指纹（size + modTime）：校验文件是否被替换，防止进度/索引错乱
    // 并支持「免 stat 直接命中磁盘缓存秒出」（PC-209）
    const QStringList statements = {
        QStringLiteral("ALTER TABLE readingProgress ADD COLUMN fileSize INTEGER"),
        QStringLiteral("ALTER TABLE readingProgress ADD COLUMN modTime INTEGER"),
    };

    for (const QString &sql : statements) {
        if (!db.execute(sql)) {
            // 列已存在属可接受情况（重复迁移），其余视为失败
            if (db.lastError().contains(QStringLiteral("duplicate column"), Qt::CaseInsensitive))
                continue;
            MH_ERROR(Database,
                     QStringLiteral("v2_reading_fingerprint failed: %1").arg(db.lastError()));
            return false;
        }
    }
    MH_INFO(Database, QStringLiteral("v2_reading_fingerprint applied"));
    return true;
}

} // namespace myhub
