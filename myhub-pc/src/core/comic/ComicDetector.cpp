#include "ComicDetector.h"

#include "core/database/AppDatabase.h"
#include "core/storage/StoragePath.h"
#include "core/utils/AppLogger.h"
#include "core/utils/MediaType.h"

#include <QDateTime>
#include <QHash>
#include <QUuid>

#include <utility>

namespace myhub {
namespace {

struct Verdict
{
    bool isComic = false;
    qint64 fileSize = 0;
    qint64 modTimeSecs = 0;
};

/// 进程内镜像：`data()` 每次重绘都会问一遍，这里绝不能出现 IO
QHash<QString, Verdict> &memory()
{
    static QHash<QString, Verdict> table;
    return table;
}

QString memoryKey(const QString &connectionId, const QString &path)
{
    // 用换行分隔：连接源 id 是 UUID、路径以 '/' 开头，两者都不会含换行
    return connectionId + QLatin1Char('\n') + path;
}

qint64 secondsOf(const QDateTime &time)
{
    return time.isValid() ? time.toSecsSinceEpoch() : 0;
}

constexpr auto kSelectColumns = "SELECT isComic, fileSize, modTime FROM comicVerdict";

} // namespace

bool ComicDetector::isComicArchivePath(const QString &path)
{
    return MediaType::isComicArchive(StoragePath::extension(path));
}

bool ComicDetector::couldBeComic(const QString &path)
{
    if (isComicArchivePath(path)) {
        return true;
    }
    // 图集 epub 与文字书 epub 外观完全一样，只能靠内容区分 —— 先算「可能」
    return StoragePath::extension(path) == QLatin1String("epub");
}

qint64 ComicDetector::secondsFromMillis(qint64 millis)
{
    return millis > 0 ? millis / 1000 : 0;
}

bool ComicDetector::known(const QString &connectionId, const FileEntry &entry, bool *isComic)
{
    // 目录先排除：名叫「xx.cbz」的文件夹不是漫画包
    if (entry.isDir) {
        return false;
    }

    // 扩展名已经能定的事不问缓存：省一次查表，也不让缓存有机会覆盖确定结论
    if (isComicArchivePath(entry.path)) {
        if (isComic) {
            *isComic = true;
        }
        return true;
    }

    if (connectionId.isEmpty() || entry.path.isEmpty()) {
        return false;
    }

    const auto it = memory().constFind(memoryKey(connectionId, entry.path));
    if (it == memory().cend()) {
        return false;
    }

    // 指纹对不上 = 文件被换过，旧结论不再成立（宁可先不挂徽标，等下次读到时再记）
    if (it.value().fileSize != entry.size || it.value().modTimeSecs != secondsOf(entry.modTime)) {
        return false;
    }

    if (isComic) {
        *isComic = it.value().isComic;
    }
    return true;
}

void ComicDetector::prime(const QString &connectionId, const FileEntryList &entries)
{
    if (connectionId.isEmpty()) {
        return;
    }
    auto &db = AppDatabase::instance();
    if (!db.isOpen()) {
        return;
    }

    for (const FileEntry &entry : std::as_const(entries)) {
        if (entry.isDir || !couldBeComic(entry.path) || isComicArchivePath(entry.path)) {
            continue;
        }
        const QString key = memoryKey(connectionId, entry.path);
        if (memory().contains(key)) {
            continue;
        }
        const auto rows = db.query(QStringLiteral("%1 WHERE connectionID = ? AND filePath = ?")
                                       .arg(QLatin1String(kSelectColumns)),
                                   {connectionId, entry.path});
        if (rows.isEmpty()) {
            continue;
        }
        const QVariantMap &row = rows.first();
        Verdict verdict;
        verdict.isComic = row.value(QStringLiteral("isComic")).toInt() != 0;
        verdict.fileSize = row.value(QStringLiteral("fileSize")).toLongLong();
        verdict.modTimeSecs = row.value(QStringLiteral("modTime")).toLongLong();
        // 过期行也照样放进内存：`known()` 每次都会比指纹，放进来不会误判，
        // 反而省掉后续每次列目录的重复查询
        memory().insert(key, verdict);
    }
}

bool ComicDetector::remember(const QString &connectionId, const QString &path, bool isComic,
                             qint64 fileSize, qint64 modTimeSecs)
{
    if (connectionId.isEmpty() || path.isEmpty()) {
        return false;
    }

    Verdict verdict;
    verdict.isComic = isComic;
    verdict.fileSize = fileSize > 0 ? fileSize : 0;
    verdict.modTimeSecs = modTimeSecs > 0 ? modTimeSecs : 0;

    // 先写内存：即便数据库还没就绪，本次会话的列目录/下一本也要立刻能用
    memory().insert(memoryKey(connectionId, path), verdict);

    auto &db = AppDatabase::instance();
    if (!db.isOpen()) {
        return false;
    }

    const bool ok = db.execute(
        QStringLiteral("INSERT INTO comicVerdict "
                       "(id, connectionID, filePath, isComic, fileSize, modTime, updatedAt) "
                       "VALUES (?, ?, ?, ?, ?, ?, ?) "
                       "ON CONFLICT(connectionID, filePath) DO UPDATE SET "
                       " isComic = excluded.isComic, fileSize = excluded.fileSize, "
                       " modTime = excluded.modTime, updatedAt = excluded.updatedAt"),
        {QUuid::createUuid().toString(QUuid::WithoutBraces), connectionId, path,
         verdict.isComic ? 1 : 0, verdict.fileSize, verdict.modTimeSecs,
         QDateTime::currentMSecsSinceEpoch()});

    if (!ok) {
        MH_WARN(ComicReader,
                QStringLiteral("漫画判定结论落库失败：%1（%2）").arg(path, db.lastError()));
        return false;
    }
    return true;
}

void ComicDetector::forget(const QString &connectionId, const QString &path)
{
    if (connectionId.isEmpty() || path.isEmpty()) {
        return;
    }
    memory().remove(memoryKey(connectionId, path));

    auto &db = AppDatabase::instance();
    if (!db.isOpen()) {
        return;
    }
    db.execute(QStringLiteral("DELETE FROM comicVerdict WHERE connectionID = ? AND filePath = ?"),
               {connectionId, path});
}

int ComicDetector::count()
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen()) {
        return 0;
    }
    return db.queryScalar(QStringLiteral("SELECT COUNT(*) FROM comicVerdict")).toInt();
}

void ComicDetector::resetMemory()
{
    memory().clear();
}

} // namespace myhub
