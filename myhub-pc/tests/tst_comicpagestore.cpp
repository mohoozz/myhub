// 漫画页名清单单测（§5 `ComicPageStore`、§6「页名清单持久化 + 离线源」）
//
// 覆盖三层：
//   1. 往返：页名顺序（含子目录）存进去能原样取回，且重复保存只留一行；
//   2. 指纹：文件变了（size 或 modTime 超过 2 秒）即未命中，绝不给旧页序；
//      但 `find` 不看指纹 —— 离线时正是靠它把指纹恢复出来；
//   3. 自愈 + 维护：payload 被写坏 / 空清单一律当未命中；改名、删目录要跟着走。
//
// 数据库用临时目录里的真实 sqlite 文件，走与生产完全相同的迁移路径。

#include <QStandardPaths>
#include <QTemporaryDir>
#include <QtTest>

#include "core/comic/ComicPageStore.h"
#include "core/database/AppDatabase.h"
#include "core/database/Migrations.h"
#include "core/preferences/AppSettings.h"
#include "core/utils/AppPaths.h"

using namespace myhub;

namespace {

const QString kConnectionId = QStringLiteral("conn-local");
const QString kPath = QStringLiteral("/漫画/第1话.cbz");
const qint64 kSize = 1024LL * 1024 * 3;
const qint64 kModTime = 1700000000000LL;

QStringList samplePages()
{
    // 真实页名带子目录前缀，排序是「自然序」而不是字典序（10 要排在 9 后面）
    return {QStringLiteral("pages/1.png"), QStringLiteral("pages/2.png"),
            QStringLiteral("pages/10.png")};
}

} // namespace

class TestComicPageStore : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void cleanupTestCase();
    void init();

    void roundTripKeepsPageOrder();
    void savingTwiceKeepsSingleRow();
    void rejectsChangedFileSize();
    void rejectsChangedModTime();
    void toleratesSecondPrecisionDrift();
    void findIgnoresFingerprint();
    void rejectsCorruptPayload();
    void rejectsEmptyPageList();
    void renamePathMovesSubtree();
    void renameOverwritesTargetRow();
    void removeSubtreeOnlyTouchesThatPath();

private:
    QTemporaryDir m_dir;
};

void TestComicPageStore::initTestCase()
{
    QCoreApplication::setApplicationName(
        QStringLiteral("MyHubComicPageStoreTest-%1").arg(QCoreApplication::applicationPid()));
    QStandardPaths::setTestModeEnabled(true);
    AppPaths::initializeAll();
    AppSettings::instance().initialize();

    QVERIFY(m_dir.isValid());
    QVERIFY(AppDatabase::instance().open(m_dir.filePath(QStringLiteral("myhub.sqlite"))));
    // 迁移到最新版本时 comicPages 表必须已经建好，否则后面的读写全无意义
    // 断言「迁移跑到了目标版本」而不是写死 5：否则每加一次迁移都要改这四个测试
    QCOMPARE(AppDatabase::instance().schemaVersion(), Migrations::kTargetVersion);
}

void TestComicPageStore::cleanupTestCase()
{
    AppDatabase::instance().close();
}

void TestComicPageStore::init()
{
    QVERIFY(AppDatabase::instance().execute(QStringLiteral("DELETE FROM comicPages")));
}

void TestComicPageStore::roundTripKeepsPageOrder()
{
    QVERIFY(ComicPageStore::save(kConnectionId, kPath, samplePages(), kSize, kModTime));
    QCOMPARE(ComicPageStore::count(), 1);

    ComicPageList restored;
    QVERIFY(ComicPageStore::load(kConnectionId, kPath, kSize, kModTime, &restored));
    // 页序就是这一卷的阅读顺序：多一页少一页、换个序，页码全错位
    QCOMPARE(restored.pages, samplePages());
    QCOMPARE(restored.fileSize, kSize);
    QCOMPARE(restored.modTime, kModTime);
}

void TestComicPageStore::savingTwiceKeepsSingleRow()
{
    QVERIFY(ComicPageStore::save(kConnectionId, kPath, samplePages(), kSize, kModTime));
    QVERIFY(ComicPageStore::save(kConnectionId, kPath, {QStringLiteral("a.png")}, kSize, kModTime));
    QCOMPARE(ComicPageStore::count(), 1);

    ComicPageList restored;
    QVERIFY(ComicPageStore::load(kConnectionId, kPath, kSize, kModTime, &restored));
    QCOMPARE(restored.pages, QStringList{QStringLiteral("a.png")});
}

void TestComicPageStore::rejectsChangedFileSize()
{
    QVERIFY(ComicPageStore::save(kConnectionId, kPath, samplePages(), kSize, kModTime));

    ComicPageList restored;
    QVERIFY(!ComicPageStore::load(kConnectionId, kPath, kSize + 1, kModTime, &restored));
    QVERIFY(restored.pages.isEmpty());
}

void TestComicPageStore::rejectsChangedModTime()
{
    QVERIFY(ComicPageStore::save(kConnectionId, kPath, samplePages(), kSize, kModTime));

    ComicPageList restored;
    // 超过 2 秒才算变了：同一次拷贝里 FAT/SMB 的秒级抖动不该把缓存废掉
    QVERIFY(!ComicPageStore::load(kConnectionId, kPath, kSize, kModTime + 2001, &restored));
}

void TestComicPageStore::toleratesSecondPrecisionDrift()
{
    QVERIFY(ComicPageStore::save(kConnectionId, kPath, samplePages(), kSize, kModTime));

    ComicPageList restored;
    QVERIFY(ComicPageStore::load(kConnectionId, kPath, kSize, kModTime + 1500, &restored));
    QCOMPARE(restored.pages, samplePages());
}

void TestComicPageStore::findIgnoresFingerprint()
{
    QVERIFY(ComicPageStore::save(kConnectionId, kPath, samplePages(), kSize, kModTime));

    // 离线打开走的正是这条：stat 根本拿不到，只能信上一次存下的清单，
    // 并把指纹（页缓存键的一部分）从这一行里恢复出来
    ComicPageList restored;
    QVERIFY(ComicPageStore::find(kConnectionId, kPath, &restored));
    QCOMPARE(restored.pages, samplePages());
    QCOMPARE(restored.fileSize, kSize);
    QCOMPARE(restored.modTime, kModTime);

    // 换个连接源就是另一个文件（同路径不同源），不许串味
    QVERIFY(!ComicPageStore::find(QStringLiteral("conn-smb"), kPath, &restored));
}

void TestComicPageStore::rejectsCorruptPayload()
{
    QVERIFY(AppDatabase::instance().execute(
        QStringLiteral("INSERT INTO comicPages (id, connectionID, filePath, pagesJSON, fileSize, "
                       "modTime, updatedAt) VALUES (?, ?, ?, ?, ?, ?, ?)"),
        {QStringLiteral("raw-1"), kConnectionId, kPath, QStringLiteral("not json at all"), kSize,
         kModTime, 1LL}));

    ComicPageList restored;
    QVERIFY(!ComicPageStore::load(kConnectionId, kPath, kSize, kModTime, &restored));
    // `find` 也不该把坏行递出去（离线路径同样要自愈）
    QVERIFY(!ComicPageStore::find(kConnectionId, kPath, &restored));

    // 是数组但不是页名字符串数组：同样当未命中
    QVERIFY(ComicPageStore::save(kConnectionId, kPath, samplePages(), kSize, kModTime));
    QVERIFY(AppDatabase::instance().execute(
        QStringLiteral(
            "UPDATE comicPages SET pagesJSON = ? WHERE connectionID = ? AND filePath = ?"),
        {QStringLiteral("[1,2,3]"), kConnectionId, kPath}));
    QVERIFY(!ComicPageStore::load(kConnectionId, kPath, kSize, kModTime, &restored));
}

void TestComicPageStore::rejectsEmptyPageList()
{
    // 空清单没有任何用途（页数 0 的漫画本来就打不开），写进去只会让
    // 下次打开显示成「0 页」
    QVERIFY(!ComicPageStore::save(kConnectionId, kPath, {}, kSize, kModTime));
    QCOMPARE(ComicPageStore::count(), 0);

    ComicPageList restored;
    QVERIFY(!ComicPageStore::decode(QStringLiteral("[]"), &restored.pages));
    QVERIFY(!ComicPageStore::decode(QStringLiteral("[\"\"]"), &restored.pages));
}

void TestComicPageStore::renamePathMovesSubtree()
{
    const QString dir = QStringLiteral("/漫画/连载");
    QVERIFY(ComicPageStore::save(kConnectionId, kPath, samplePages(), kSize, kModTime));
    QVERIFY(ComicPageStore::save(kConnectionId, dir + QStringLiteral("/第2话.cbz"), samplePages(),
                                 kSize, kModTime));
    QVERIFY(ComicPageStore::save(kConnectionId, QStringLiteral("/漫画/别处.cbz"), samplePages(),
                                 kSize, kModTime));

    // 改名/移动要跟着走：否则清单留在一个已经不存在的路径上，白占空间
    const QString target = QStringLiteral("/归档/第1话.cbz");
    QCOMPARE(ComicPageStore::renamePath(kConnectionId, kPath, target), 1);
    ComicPageList restored;
    QVERIFY(ComicPageStore::find(kConnectionId, target, &restored));
    QVERIFY(!ComicPageStore::find(kConnectionId, kPath, &restored));

    // 整目录改名：子树里的行一起搬，前缀之外的不能动
    QCOMPARE(ComicPageStore::renamePath(kConnectionId, dir, QStringLiteral("/归档/连载")), 1);
    QVERIFY(ComicPageStore::find(kConnectionId, QStringLiteral("/归档/连载/第2话.cbz"), &restored));
    QVERIFY(ComicPageStore::find(kConnectionId, QStringLiteral("/漫画/别处.cbz"), &restored));
}

void TestComicPageStore::removeSubtreeOnlyTouchesThatPath()
{
    const QString dir = QStringLiteral("/漫画/连载");
    QVERIFY(ComicPageStore::save(kConnectionId, kPath, samplePages(), kSize, kModTime));
    QVERIFY(ComicPageStore::save(kConnectionId, dir + QStringLiteral("/第2话.cbz"), samplePages(),
                                 kSize, kModTime));
    // 名字前缀相同但不是子目录（`/漫画/连载2`），不能被「子树」误伤
    QVERIFY(ComicPageStore::save(kConnectionId, QStringLiteral("/漫画/连载2.cbz"), samplePages(),
                                 kSize, kModTime));
    QCOMPARE(ComicPageStore::count(), 3);

    QCOMPARE(ComicPageStore::removeSubtree(kConnectionId, dir), 1);
    ComicPageList restored;
    QVERIFY(ComicPageStore::find(kConnectionId, QStringLiteral("/漫画/连载2.cbz"), &restored));

    QCOMPARE(ComicPageStore::remove(kConnectionId, kPath), 1);
    QCOMPARE(ComicPageStore::count(), 1);
}

void TestComicPageStore::renameOverwritesTargetRow()
{
    // 覆盖式移动：目标路径上已有被覆盖那本的清单，硬 UPDATE 会撞唯一键
    const QString source = QStringLiteral("/漫画/第1话.cbz");
    const QString target = QStringLiteral("/归档/第1话.cbz");
    QVERIFY(ComicPageStore::save(kConnectionId, source, samplePages(), kSize, kModTime));
    QVERIFY(ComicPageStore::save(kConnectionId, target, {QStringLiteral("old/only.png")}, kSize + 1,
                                 kModTime + 1));

    QCOMPARE(ComicPageStore::renamePath(kConnectionId, source, target), 1);
    QCOMPARE(ComicPageStore::count(), 1);

    ComicPageList restored;
    QVERIFY(ComicPageStore::load(kConnectionId, target, kSize, kModTime, &restored));
    QCOMPARE(restored.pages, samplePages());
    QVERIFY(!ComicPageStore::find(kConnectionId, source, &restored));
}

QTEST_GUILESS_MAIN(TestComicPageStore)
#include "tst_comicpagestore.moc"
