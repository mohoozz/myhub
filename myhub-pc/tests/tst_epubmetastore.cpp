// epub 目录快照单测（§5「epub 元数据快照」、§13 离线阅读）
//
// 覆盖四层：
//   1. 往返：书名 / 章名 / 条目路径 / 层级 / 指纹原样取回，重复保存只留一行；
//   2. find 不校验指纹：离线路径就靠它把目录和指纹一起捞回来；
//   3. 生命周期：改名跟着目录走，删目录只清子树、不误伤兄弟目录；
//   4. 坏数据自愈：JSON 坏了或目录项缺字段一律当未命中，绝不把半份目录递出去。

#include <QStandardPaths>
#include <QTemporaryDir>
#include <QtTest>

#include "core/database/AppDatabase.h"
#include "core/database/Migrations.h"
#include "core/novel/EpubMetaStore.h"
#include "core/preferences/AppSettings.h"
#include "core/utils/AppPaths.h"

using namespace myhub;

namespace {

const QString kConnectionId = QStringLiteral("conn-epubmeta");
const QString kPath = QStringLiteral("/书架/书一.epub");
const qint64 kSize = 4096;
const qint64 kModTime = 1700000000000LL;

EpubChapterRef chapter(const QString &title, const QString &href, int level)
{
    EpubChapterRef ref;
    ref.title = title;
    ref.href = href;
    ref.level = level;
    return ref;
}

EpubMeta sampleMeta()
{
    EpubMeta meta;
    meta.title = QStringLiteral("书一");
    meta.author = QStringLiteral("某作者");
    meta.language = QStringLiteral("zh-CN");
    meta.coverHref = QStringLiteral("OEBPS/cover.png");
    meta.fileSize = kSize;
    meta.modTime = kModTime;
    meta.chapters = {
        chapter(QStringLiteral("第一章"), QStringLiteral("OEBPS/ch1.xhtml"), 0),
        chapter(QStringLiteral("第一节"), QStringLiteral("OEBPS/ch1-1.xhtml"), 1),
        chapter(QStringLiteral("第二章"), QStringLiteral("OEBPS/ch2.xhtml"), 0),
    };
    return meta;
}

} // namespace

class TestEpubMetaStore : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void init();
    void cleanupTestCase();

    void roundTripKeepsChapterOrder();
    void savingTwiceKeepsSingleRow();
    void findIgnoresFingerprintButNotConnection();
    void renamesWholeSubtree();
    void renameOverwritesTargetRow();
    void removeSubtreeOnlyDropsThatTree();
    void rejectsCorruptPayload();

private:
    QTemporaryDir m_dir;
};

void TestEpubMetaStore::initTestCase()
{
    QCoreApplication::setApplicationName(
        QStringLiteral("MyHubEpubMetaStoreTest-%1").arg(QCoreApplication::applicationPid()));
    QStandardPaths::setTestModeEnabled(true);
    AppPaths::initializeAll();
    AppSettings::instance().initialize();

    QVERIFY(m_dir.isValid());
    QVERIFY(AppDatabase::instance().open(m_dir.filePath(QStringLiteral("myhub.sqlite"))));
    // 迁移到最新版本时 epubMeta 表必须已经建好，否则后面的读写全无意义
    QCOMPARE(AppDatabase::instance().schemaVersion(), Migrations::kTargetVersion);
}

void TestEpubMetaStore::init()
{
    QVERIFY(AppDatabase::instance().execute(QStringLiteral("DELETE FROM epubMeta")));
}

void TestEpubMetaStore::cleanupTestCase()
{
    AppDatabase::instance().close();
}

void TestEpubMetaStore::roundTripKeepsChapterOrder()
{
    QVERIFY(EpubMetaStore::save(kConnectionId, kPath, sampleMeta()));
    QCOMPARE(EpubMetaStore::count(), 1);

    EpubMeta restored;
    QVERIFY(EpubMetaStore::find(kConnectionId, kPath, &restored));
    QCOMPARE(restored.title, QStringLiteral("书一"));
    QCOMPARE(restored.author, QStringLiteral("某作者"));
    QCOMPARE(restored.language, QStringLiteral("zh-CN"));
    QCOMPARE(restored.coverHref, QStringLiteral("OEBPS/cover.png"));
    QCOMPARE(restored.fileSize, kSize);
    QCOMPARE(restored.modTime, kModTime);

    // 章序就是阅读顺序：多一章少一章、换个序，目录与进度全错位
    QCOMPARE(restored.chapters.size(), 3);
    QCOMPARE(restored.chapters.at(0).title, QStringLiteral("第一章"));
    QCOMPARE(restored.chapters.at(1).href, QStringLiteral("OEBPS/ch1-1.xhtml"));
    QCOMPARE(restored.chapters.at(1).level, 1);
    QCOMPARE(restored.chapters.at(2).title, QStringLiteral("第二章"));
}

void TestEpubMetaStore::savingTwiceKeepsSingleRow()
{
    QVERIFY(EpubMetaStore::save(kConnectionId, kPath, sampleMeta()));

    EpubMeta smaller = sampleMeta();
    smaller.chapters = {chapter(QStringLiteral("唯一一章"), QStringLiteral("OEBPS/only.xhtml"), 0)};
    QVERIFY(EpubMetaStore::save(kConnectionId, kPath, smaller));
    QCOMPARE(EpubMetaStore::count(), 1);

    EpubMeta restored;
    QVERIFY(EpubMetaStore::find(kConnectionId, kPath, &restored));
    QCOMPARE(restored.chapters.size(), 1);
    QCOMPARE(restored.chapters.first().title, QStringLiteral("唯一一章"));
}

void TestEpubMetaStore::findIgnoresFingerprintButNotConnection()
{
    QVERIFY(EpubMetaStore::save(kConnectionId, kPath, sampleMeta()));

    // 离线打开走的正是这条：stat 拿不到长度与时间，只能信上一次存下的章表，
    // 并把指纹从这一行里恢复出来（章节缓存键靠它对齐）
    EpubMeta restored;
    QVERIFY(EpubMetaStore::find(kConnectionId, kPath, &restored));
    QCOMPARE(restored.chapters.size(), 3);
    QCOMPARE(restored.fileSize, kSize);

    // 同路径不同连接源就是另一个文件，不许串味
    QVERIFY(!EpubMetaStore::find(QStringLiteral("conn-smb"), kPath, &restored));
}

void TestEpubMetaStore::renamesWholeSubtree()
{
    QVERIFY(EpubMetaStore::save(kConnectionId, QStringLiteral("/书架/旧/a.epub"), sampleMeta()));
    QVERIFY(EpubMetaStore::save(kConnectionId, QStringLiteral("/书架/旧/子/b.epub"), sampleMeta()));
    QVERIFY(EpubMetaStore::save(kConnectionId, QStringLiteral("/书架/别/c.epub"), sampleMeta()));

    // 目录整体改名：子树里的快照要跟着走，否则改名后第一次打开会认不出「读过」
    QCOMPARE(EpubMetaStore::renamePath(kConnectionId, QStringLiteral("/书架/旧"),
                                       QStringLiteral("/书架/新")),
             2);
    QCOMPARE(EpubMetaStore::count(), 3);

    EpubMeta restored;
    QVERIFY(EpubMetaStore::find(kConnectionId, QStringLiteral("/书架/新/a.epub"), &restored));
    QVERIFY(EpubMetaStore::find(kConnectionId, QStringLiteral("/书架/新/子/b.epub"), &restored));
    QVERIFY(!EpubMetaStore::find(kConnectionId, QStringLiteral("/书架/旧/a.epub"), &restored));
    // 兄弟目录不受影响（前缀只认到 `/`，`/书架/别` 不是 `/书架/旧` 的子树）
    QVERIFY(EpubMetaStore::find(kConnectionId, QStringLiteral("/书架/别/c.epub"), &restored));
}

void TestEpubMetaStore::renameOverwritesTargetRow()
{
    // 覆盖式移动：目标路径上已有被覆盖那本的快照，硬 UPDATE 会撞唯一键
    const QString source = QStringLiteral("/书架/新.epub");
    const QString target = QStringLiteral("/归档/新.epub");
    QVERIFY(EpubMetaStore::save(kConnectionId, source, sampleMeta()));

    EpubMeta stale = sampleMeta();
    stale.title = QStringLiteral("被覆盖的旧书");
    stale.chapters = {chapter(QStringLiteral("旧章"), QStringLiteral("old.xhtml"), 0)};
    QVERIFY(EpubMetaStore::save(kConnectionId, target, stale));

    QCOMPARE(EpubMetaStore::renamePath(kConnectionId, source, target), 1);
    QCOMPARE(EpubMetaStore::count(), 1);

    EpubMeta restored;
    QVERIFY(EpubMetaStore::find(kConnectionId, target, &restored));
    QCOMPARE(restored.title, QStringLiteral("书一"));
    QVERIFY(!EpubMetaStore::find(kConnectionId, source, &restored));
}

void TestEpubMetaStore::removeSubtreeOnlyDropsThatTree()
{
    QVERIFY(EpubMetaStore::save(kConnectionId, QStringLiteral("/书架/卷/a.epub"), sampleMeta()));
    QVERIFY(EpubMetaStore::save(kConnectionId, QStringLiteral("/书架/卷/子/b.epub"), sampleMeta()));
    QVERIFY(EpubMetaStore::save(kConnectionId, QStringLiteral("/书架/卷宗/c.epub"), sampleMeta()));

    QCOMPARE(EpubMetaStore::removeSubtree(kConnectionId, QStringLiteral("/书架/卷")), 2);
    QCOMPARE(EpubMetaStore::count(), 1);

    // `/书架/卷宗` 只是名字以 `/书架/卷` 开头，并不是它的子项
    EpubMeta restored;
    QVERIFY(EpubMetaStore::find(kConnectionId, QStringLiteral("/书架/卷宗/c.epub"), &restored));
}

void TestEpubMetaStore::rejectsCorruptPayload()
{
    QVERIFY(AppDatabase::instance().execute(
        QStringLiteral("INSERT INTO epubMeta (id, connectionID, filePath, metaJSON, fileSize, "
                       "modTime, updatedAt) VALUES (?, ?, ?, ?, ?, ?, ?)"),
        {QStringLiteral("raw-1"), kConnectionId, kPath, QStringLiteral("not json at all"), kSize,
         kModTime, 1LL}));

    EpubMeta restored;
    QVERIFY(!EpubMetaStore::find(kConnectionId, kPath, &restored));

    // 是对象但没有 chapters：同样不算一份可用的目录
    QVERIFY(AppDatabase::instance().execute(
        QStringLiteral("UPDATE epubMeta SET metaJSON = ? WHERE id = 'raw-1'"),
        {QStringLiteral("{\"title\":\"只有书名\"}")}));
    QVERIFY(!EpubMetaStore::find(kConnectionId, kPath, &restored));

    // 目录项缺 href：没有条目路径就无从定位正文，宁可当未命中
    QVERIFY(AppDatabase::instance().execute(
        QStringLiteral("UPDATE epubMeta SET metaJSON = ? WHERE id = 'raw-1'"),
        {QStringLiteral("{\"chapters\":[{\"title\":\"第一章\"}]}")}));
    QVERIFY(!EpubMetaStore::find(kConnectionId, kPath, &restored));

    // 越过 JSON 边界：level 坏值只夹紧，不丢整份目录
    QVERIFY(AppDatabase::instance().execute(
        QStringLiteral("UPDATE epubMeta SET metaJSON = ? WHERE id = 'raw-1'"),
        {QStringLiteral(
            "{\"chapters\":[{\"title\":\"第一章\",\"href\":\"a.xhtml\",\"level\":-3}]}")}));
    QVERIFY(EpubMetaStore::find(kConnectionId, kPath, &restored));
    QCOMPARE(restored.chapters.first().level, 0);
}

QTEST_MAIN(TestEpubMetaStore)
#include "tst_epubmetastore.moc"
