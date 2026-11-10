// 收藏仓库单测（PC-107）
//
// 覆盖 FavoriteRepository 的全部写入语义：
//   落库/查回、唯一性（重复收藏不新增行、不刷新收藏时间）、切换、
//   删除与子树清理、重命名/移动后的路径改写、键集（启动预载用）。
//
// 数据库用临时目录里的真实 sqlite 文件（走与生产相同的迁移路径）。

#include <QSignalSpy>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QtTest>

#include "core/database/AppDatabase.h"
#include "core/favorites/FavoriteRepository.h"
#include "core/preferences/AppSettings.h"
#include "core/utils/AppPaths.h"
#include "core/utils/MediaType.h"

using namespace myhub;

namespace {

FavoriteRecord favoriteFor(const QString &path, const QString &mediaType = QStringLiteral("video"),
                           qint64 size = 1024, qint64 createdAt = 0)
{
    FavoriteRecord record;
    record.connectionId = QStringLiteral("conn-1");
    record.filePath = path;
    record.mediaType = mediaType;
    record.size = size;
    record.createdAt = createdAt;
    return record;
}

QStringList pathsOf(const QList<FavoriteRecord> &records)
{
    QStringList paths;
    paths.reserve(records.size());
    for (const FavoriteRecord &record : records) {
        paths.append(record.filePath);
    }
    return paths;
}

} // namespace

class TestFavorite : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void init();

    void addThenQueryRoundTrip();
    void duplicateAddKeepsSingleRowAndCreatedAt();
    void toggleFlipsState();
    void removeDeletesOnlyThatEntry();
    void removeMissingIsNoOp();
    void removeSubtreeCleansWholeBranch();
    void renamePathRewritesFileAndSubtree();
    void keysMatchTable();
    void mediaBadgeRoundTrip();

private:
    QTemporaryDir m_dir;
};

void TestFavorite::initTestCase()
{
    QCoreApplication::setApplicationName(
        QStringLiteral("MyHubFavoriteTest-%1").arg(QCoreApplication::applicationPid()));
    QStandardPaths::setTestModeEnabled(true);
    AppPaths::initializeAll();
    AppSettings::instance().initialize();

    QVERIFY(m_dir.isValid());
    QVERIFY(AppDatabase::instance().open(m_dir.filePath(QStringLiteral("myhub.sqlite"))));
}

void TestFavorite::init()
{
    auto &db = AppDatabase::instance();
    QVERIFY(db.execute(QStringLiteral("DELETE FROM favorite")));
    // favorite.connectionID 有外键指向 connection(id)（ON DELETE CASCADE），
    // 测试里必须先把连接源建出来，否则插入会被外键挡住
    QVERIFY(
        db.execute(QStringLiteral("INSERT OR REPLACE INTO connection "
                                  "(id, name, type, configJSON, mountPoint, enabled, createdAt) "
                                  "VALUES (?, ?, ?, ?, ?, 1, 0)"),
                   {QStringLiteral("conn-1"), QStringLiteral("测试源"), QStringLiteral("local"),
                    QStringLiteral("{}"), QStringLiteral("C:/media")}));
}

void TestFavorite::addThenQueryRoundTrip()
{
    auto &repo = FavoriteRepository::instance();
    QSignalSpy spy(&repo, &FavoriteRepository::favoriteChanged);

    const QString path = QStringLiteral("C:/media/movie.mkv");
    QVERIFY(repo.add(favoriteFor(path, QStringLiteral("video"), 4096)));
    QCOMPARE(spy.count(), 1);

    QVERIFY(repo.contains(QStringLiteral("conn-1"), path));
    QCOMPARE(repo.count(), 1);

    const auto records = repo.list();
    QCOMPARE(records.size(), 1);
    QCOMPARE(records.first().filePath, path);
    QCOMPARE(records.first().connectionId, QStringLiteral("conn-1"));
    QCOMPARE(records.first().mediaType, QStringLiteral("video"));
    QCOMPARE(records.first().size, qint64(4096));
    QVERIFY(records.first().createdAt > 0);
    QVERIFY(!records.first().isDir());

    // 未收藏的路径必须明确返回「没有」
    QVERIFY(!repo.contains(QStringLiteral("conn-1"), QStringLiteral("C:/media/other.mkv")));
}

void TestFavorite::duplicateAddKeepsSingleRowAndCreatedAt()
{
    auto &repo = FavoriteRepository::instance();
    const QString path = QStringLiteral("C:/media/same.mkv");

    QVERIFY(repo.add(favoriteFor(path, QStringLiteral("video"), 100, 1000)));
    // 重复收藏：只刷新类型/大小，收藏时间保持第一次的（列表顺序才不会乱跳）
    QVERIFY(repo.add(favoriteFor(path, QStringLiteral("file"), 200, 2000)));

    QCOMPARE(repo.count(), 1);
    const auto records = repo.list();
    QCOMPARE(records.size(), 1);
    QCOMPARE(records.first().createdAt, qint64(1000));
    QCOMPARE(records.first().mediaType, QStringLiteral("file"));
    QCOMPARE(records.first().size, qint64(200));
}

void TestFavorite::toggleFlipsState()
{
    auto &repo = FavoriteRepository::instance();
    const QString path = QStringLiteral("C:/media/toggle.mkv");

    bool nowFavorite = false;
    QVERIFY(repo.toggle(favoriteFor(path), &nowFavorite));
    QVERIFY(nowFavorite);
    QVERIFY(repo.contains(QStringLiteral("conn-1"), path));

    QVERIFY(repo.toggle(favoriteFor(path), &nowFavorite));
    QVERIFY(!nowFavorite);
    QVERIFY(!repo.contains(QStringLiteral("conn-1"), path));
    QCOMPARE(repo.count(), 0);
}

void TestFavorite::removeDeletesOnlyThatEntry()
{
    auto &repo = FavoriteRepository::instance();
    const QString keep = QStringLiteral("C:/media/keep.mkv");
    const QString drop = QStringLiteral("C:/media/drop.mkv");
    QVERIFY(repo.add(favoriteFor(keep, QStringLiteral("video"), 10, 1000)));
    QVERIFY(repo.add(favoriteFor(drop, QStringLiteral("video"), 10, 2000)));

    QSignalSpy spy(&repo, &FavoriteRepository::favoriteChanged);
    QVERIFY(repo.remove(QStringLiteral("conn-1"), drop));
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.first().at(2).toBool(), false);

    QVERIFY(!repo.contains(QStringLiteral("conn-1"), drop));
    QVERIFY(repo.contains(QStringLiteral("conn-1"), keep));
}

void TestFavorite::removeMissingIsNoOp()
{
    auto &repo = FavoriteRepository::instance();
    QSignalSpy spy(&repo, &FavoriteRepository::favoriteChanged);

    // 本来就没收藏：不得返回成功，也不得广播「取消收藏」
    QVERIFY(!repo.remove(QStringLiteral("conn-1"), QStringLiteral("C:/media/none.mkv")));
    QCOMPARE(spy.count(), 0);
}

void TestFavorite::removeSubtreeCleansWholeBranch()
{
    auto &repo = FavoriteRepository::instance();
    QVERIFY(
        repo.add(favoriteFor(QStringLiteral("C:/media/show"), QStringLiteral("folder"), 0, 1000)));
    QVERIFY(repo.add(
        favoriteFor(QStringLiteral("C:/media/show/e01.mkv"), QStringLiteral("video"), 10, 2000)));
    QVERIFY(repo.add(
        favoriteFor(QStringLiteral("C:/media/show/e02.mkv"), QStringLiteral("video"), 10, 3000)));
    // 前缀相同但不在子树内：不能被误删
    QVERIFY(repo.add(
        favoriteFor(QStringLiteral("C:/media/showcase.mkv"), QStringLiteral("video"), 10, 4000)));

    QSignalSpy spy(&repo, &FavoriteRepository::favoriteChanged);
    QCOMPARE(repo.removeSubtree(QStringLiteral("conn-1"), QStringLiteral("C:/media/show")), 3);
    QCOMPARE(spy.count(), 3);

    QCOMPARE(pathsOf(repo.list()), QStringList{QStringLiteral("C:/media/showcase.mkv")});
}

void TestFavorite::renamePathRewritesFileAndSubtree()
{
    auto &repo = FavoriteRepository::instance();
    QVERIFY(repo.add(
        favoriteFor(QStringLiteral("C:/media/old/show"), QStringLiteral("folder"), 0, 1000)));
    QVERIFY(repo.add(favoriteFor(QStringLiteral("C:/media/old/show/e01.mkv"),
                                 QStringLiteral("video"), 10, 2000)));
    QVERIFY(repo.add(
        favoriteFor(QStringLiteral("C:/media/old/other.mkv"), QStringLiteral("video"), 10, 3000)));

    // 目录改名：子树前缀必须一起改写
    QCOMPARE(repo.renamePath(QStringLiteral("conn-1"), QStringLiteral("C:/media/old/show"),
                             QStringLiteral("C:/media/new/show")),
             2);
    QVERIFY(repo.contains(QStringLiteral("conn-1"), QStringLiteral("C:/media/new/show")));
    QVERIFY(repo.contains(QStringLiteral("conn-1"), QStringLiteral("C:/media/new/show/e01.mkv")));
    QVERIFY(!repo.contains(QStringLiteral("conn-1"), QStringLiteral("C:/media/old/show")));
    QVERIFY(repo.contains(QStringLiteral("conn-1"),
                          QStringLiteral("C:/media/old/other.mkv"))); // 不受影响

    // 单文件改名
    QCOMPARE(repo.renamePath(QStringLiteral("conn-1"), QStringLiteral("C:/media/old/other.mkv"),
                             QStringLiteral("C:/media/old/renamed.mkv")),
             1);
    QVERIFY(repo.contains(QStringLiteral("conn-1"), QStringLiteral("C:/media/old/renamed.mkv")));
}

void TestFavorite::keysMatchTable()
{
    auto &repo = FavoriteRepository::instance();
    QVERIFY(
        repo.add(favoriteFor(QStringLiteral("C:/media/a.mkv"), QStringLiteral("video"), 1, 1000)));
    QVERIFY(repo.add(favoriteFor(QStringLiteral("C:/media/b"), QStringLiteral("folder"), 0, 2000)));

    const QStringList keys = repo.keys();
    QCOMPARE(keys.size(), 2);
    QVERIFY(keys.contains(QStringLiteral("conn-1\nC:/media/a.mkv")));
    QVERIFY(keys.contains(QStringLiteral("conn-1\nC:/media/b")));
}

void TestFavorite::mediaBadgeRoundTrip()
{
    // 收藏表只存徽标串，读回时要能还原类型与中文名
    const QList<QPair<MediaType::Kind, QString>> cases = {
        {MediaType::Directory, QStringLiteral("folder")},
        {MediaType::Video, QStringLiteral("video")},
        {MediaType::Audio, QStringLiteral("audio")},
        {MediaType::Novel, QStringLiteral("novel")},
        {MediaType::Comic, QStringLiteral("comic")},
        {MediaType::Image, QStringLiteral("image")},
        {MediaType::Subtitle, QStringLiteral("subtitle")},
        {MediaType::Text, QStringLiteral("text")},
        {MediaType::Unknown, QStringLiteral("file")},
    };

    for (const auto &entry : cases) {
        QCOMPARE(MediaType::badgeId(entry.first), entry.second);
        QCOMPARE(MediaType::fromBadgeId(entry.second), entry.first);
        QCOMPARE(MediaType::displayNameForBadge(entry.second), MediaType::displayName(entry.first));
    }
}

QTEST_MAIN(TestFavorite)
#include "tst_favorite.moc"
