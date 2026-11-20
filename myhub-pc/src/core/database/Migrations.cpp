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
    if (ok && current < 3)
        ok = v3_novel_chapter_cache(db);
    if (ok && current < 4)
        ok = v4_comic_page_list(db);
    if (ok && current < 5)
        ok = v5_epub_meta(db);
    if (ok && current < 6)
        ok = v6_comic_verdict(db);

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

bool Migrations::v3_novel_chapter_cache(AppDatabase &db)
{
    // 章节解码产物落盘（§5 `NovelChapterCache`、§13「小说章节缓存本地化」）。
    //
    // 为什么进数据库而不是缓存目录里的散文件：章节是「按书 + 章号」寻址的小块数据，
    // 一亿个文件的 inode 开销和清理逻辑都不值得；SQLite 一条 DELETE 就能做
    // 「这本书的缓存全清」「超量修剪」，与索引缓存共用一套生命周期。
    //
    // 指纹列冗余在行上（而不是只按书存一行元数据）：文件一变，逐行判得出来，
    // 不必先删再建，弱网下「旧的还能读就先读」也不需要额外的分支。
    const QStringList statements = {
        QStringLiteral(R"(
            CREATE TABLE IF NOT EXISTS novelChapter (
                id           TEXT PRIMARY KEY,
                connectionID TEXT NOT NULL,
                filePath     TEXT NOT NULL,
                fileSize     INTEGER NOT NULL DEFAULT 0,
                modTime      INTEGER NOT NULL DEFAULT 0,
                chapterIndex INTEGER NOT NULL,
                title        TEXT NOT NULL DEFAULT '',
                payload      BLOB NOT NULL,
                updatedAt    INTEGER NOT NULL
            ))"),
        QStringLiteral("CREATE UNIQUE INDEX IF NOT EXISTS idx_novelchapter_unique "
                       "ON novelChapter(connectionID, filePath, chapterIndex)"),
        QStringLiteral("CREATE INDEX IF NOT EXISTS idx_novelchapter_updated "
                       "ON novelChapter(updatedAt DESC)"),
    };

    for (const QString &sql : statements) {
        if (!db.execute(sql)) {
            MH_ERROR(Database,
                     QStringLiteral("v3_novel_chapter_cache failed: %1").arg(db.lastError()));
            return false;
        }
    }
    MH_INFO(Database, QStringLiteral("v3_novel_chapter_cache applied"));
    return true;
}

bool Migrations::v4_comic_page_list(AppDatabase &db)
{
    // 漫画「页名清单」快照（§5 `ComicPageStore`、§6「页名清单持久化 + 离线源」）。
    //
    // 页名只能从压缩包里读出来（zip 要读尾部队列表，远程 cbr 甚至要整包在手），
    // 存在这里就等于把「有几页、第几页叫什么」变成一次查表：
    //   · 重开同一本：页数与页序立刻就有，续读页在盘上就直接上屏；
    //   · 源够不着：靠这一行恢复指纹，页缓存键仍能对上，读过的页照看。
    //
    // 一个文件一行（页名清单是「一本书的元数据」，不是按页寻址的块数据）；
    // 指纹冗余在行上，文件一变旧行自然失配，不需要先删再建。
    const QStringList statements = {
        QStringLiteral(R"(
            CREATE TABLE IF NOT EXISTS comicPages (
                id           TEXT PRIMARY KEY,
                connectionID TEXT NOT NULL,
                filePath     TEXT NOT NULL,
                pagesJSON    TEXT NOT NULL DEFAULT '[]',
                fileSize     INTEGER NOT NULL DEFAULT 0,
                modTime      INTEGER NOT NULL DEFAULT 0,
                updatedAt    INTEGER NOT NULL
            ))"),
        QStringLiteral("CREATE UNIQUE INDEX IF NOT EXISTS idx_comicpages_unique "
                       "ON comicPages(connectionID, filePath)"),
    };

    for (const QString &sql : statements) {
        if (!db.execute(sql)) {
            MH_ERROR(Database, QStringLiteral("v4_comic_page_list failed: %1").arg(db.lastError()));
            return false;
        }
    }
    MH_INFO(Database, QStringLiteral("v4_comic_page_list applied"));
    return true;
}

bool Migrations::v5_epub_meta(AppDatabase &db)
{
    // epub 的目录与元数据快照（§5「epub 元数据快照」、§13 离线阅读）。
    //
    // epub 没有可缓存的行表 / 字节索引：目录藏在 OPF 与 NAV/NCX 里，
    // 要读它们就得先打开 zip（还要先 stat 到文件长度）。源够不着时 stat 就失败了，
    // 连「有几章」都答不上来 —— 所以把「书名 + 章名 + 条目路径」单独存一份。
    //
    // 与 `comicPages` 同一套约定：一个文件一行、指纹冗余在行上；
    // 文件变了旧行自然对不上（离线时用它把指纹恢复出来，章节缓存键因此仍能命中）。
    const QStringList statements = {
        QStringLiteral(R"(
            CREATE TABLE IF NOT EXISTS epubMeta (
                id           TEXT PRIMARY KEY,
                connectionID TEXT NOT NULL,
                filePath     TEXT NOT NULL,
                metaJSON     TEXT NOT NULL DEFAULT '{}',
                fileSize     INTEGER NOT NULL DEFAULT 0,
                modTime      INTEGER NOT NULL DEFAULT 0,
                updatedAt    INTEGER NOT NULL
            ))"),
        QStringLiteral("CREATE UNIQUE INDEX IF NOT EXISTS idx_epubmeta_unique "
                       "ON epubMeta(connectionID, filePath)"),
    };

    for (const QString &sql : statements) {
        if (!db.execute(sql)) {
            MH_ERROR(Database, QStringLiteral("v5_epub_meta failed: %1").arg(db.lastError()));
            return false;
        }
    }
    MH_INFO(Database, QStringLiteral("v5_epub_meta applied"));
    return true;
}

bool Migrations::v6_comic_verdict(AppDatabase &db)
{
    // 「这个文件是不是漫画」的判定结论缓存（§6 `ComicDetector` ③）。
    //
    // 单独一张表而不是塞进 `epubMeta`：图集 epub 的章节表可能是空的，
    // 而 `EpubMeta::isValid()` 要求 chapters 非空 —— 结论会被那条约束连坐丢掉。
    // 判定结论对文字书同样有价值（`isComic = 0` 说明「查过了，不是图集」），
    // 与目录快照的生命周期也不一致，故独立存放。
    //
    // 指纹（fileSize + modTime，秒）冗余在这一行上：文件被换过，旧结论不再成立，
    // 读取方一比对指纹就能发现，不需要额外的失效逻辑。
    const QStringList statements = {
        QStringLiteral(R"(
            CREATE TABLE IF NOT EXISTS comicVerdict (
                id           TEXT PRIMARY KEY,
                connectionID TEXT NOT NULL,
                filePath     TEXT NOT NULL,
                isComic      INTEGER NOT NULL DEFAULT 0,
                fileSize     INTEGER NOT NULL DEFAULT 0,
                modTime      INTEGER NOT NULL DEFAULT 0,
                updatedAt    INTEGER NOT NULL
            ))"),
        QStringLiteral("CREATE UNIQUE INDEX IF NOT EXISTS idx_comicverdict_unique "
                       "ON comicVerdict(connectionID, filePath)"),
    };

    for (const QString &sql : statements) {
        if (!db.execute(sql)) {
            MH_ERROR(Database, QStringLiteral("v6_comic_verdict failed: %1").arg(db.lastError()));
            return false;
        }
    }
    MH_INFO(Database, QStringLiteral("v6_comic_verdict applied"));
    return true;
}

} // namespace myhub
