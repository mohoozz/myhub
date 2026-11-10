// 回收站单测（§3.3）：还原到原路径 / 同名顺延不覆盖 / 原目录重建 / 元数据缺失 /
// 彻底删除（连同 meta）/ 批量删除部分失败汇总
//
// 走真实代码路径（LocalAdapter + TrashStore + FileOperations），
// 使用独立临时目录，不污染用户真实数据。

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSignalSpy>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QtTest>
#include <memory>

#include "core/cache/DirectoryCache.h"
#include "core/database/AppDatabase.h"
#include "core/files/FileOperations.h"
#include "core/files/TrashStore.h"
#include "core/preferences/AppSettings.h"
#include "core/storage/LocalAdapter.h"
#include "core/storage/StoragePath.h"
#include "core/utils/AppPaths.h"

using namespace myhub;

class TestTrash : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void init();
    void restoresBackToOriginalPath();
    void restoreAppendsIndexWhenTargetExists();
    void restoreRecreatesMissingParentFolder();
    void restoreRejectsEntryWithoutMeta();
    void purgesEntryWithMeta();
    void purgesEntryWithoutMeta();
    void purgeAllRemovesEveryEntry();
    void cleanupTestCase();

private:
    QString rootPath() const { return m_root.path(); }
    QString absolute(const QString &rel) const { return rootPath() + rel; }
    void writeFile(const QString &rel, const QByteArray &content = QByteArrayLiteral("x"));
    /// 直接把条目塞进回收站（复用真实删除路径，保证 meta 与布局一致）
    void trashEntry(const QString &rel, const QByteArray &content = QByteArrayLiteral("x"));

    QTemporaryDir m_root;
    std::unique_ptr<LocalAdapter> m_adapter;
};

void TestTrash::initTestCase()
{
    QCoreApplication::setApplicationName(
        QStringLiteral("MyHubTest-%1").arg(QCoreApplication::applicationPid()));
    QStandardPaths::setTestModeEnabled(true);

    AppPaths::initializeAll();
    AppSettings::instance().initialize();

    auto &db = AppDatabase::instance();
    QVERIFY2(db.open(), qPrintable(db.lastError()));

    QVERIFY(m_root.isValid());
    m_adapter = std::make_unique<LocalAdapter>(rootPath());
}

void TestTrash::init()
{
    QDir(rootPath()).removeRecursively();
    QVERIFY(QDir().mkpath(rootPath()));
}

void TestTrash::cleanupTestCase()
{
    AppDatabase::instance().close();
}

void TestTrash::writeFile(const QString &rel, const QByteArray &content)
{
    const QString path = absolute(rel);
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile file(path);
    QVERIFY2(file.open(QIODevice::WriteOnly), qPrintable(path));
    file.write(content);
}

void TestTrash::trashEntry(const QString &rel, const QByteArray &content)
{
    writeFile(rel, content);
    auto &ops = FileOperations::instance();
    QSignalSpy removedSpy(&ops, &FileOperations::removed);
    ops.removeToTrash(m_adapter.get(), QStringLiteral("c-test"), {rel});
    QTRY_COMPARE_WITH_TIMEOUT(removedSpy.count(), 1, 5000);
}

void TestTrash::restoresBackToOriginalPath()
{
    trashEntry(QStringLiteral("/影片/movie.mkv"), QByteArrayLiteral("bytes"));
    const QString trashName = QStringLiteral("movie.mkv");
    QVERIFY(QFile::exists(absolute(QStringLiteral("/.trash/") + trashName)));

    auto &ops = FileOperations::instance();
    QSignalSpy restoredSpy(&ops, &FileOperations::restored);
    QSignalSpy failedSpy(&ops, &FileOperations::failed);

    ops.restoreFromTrash(m_adapter.get(), QStringLiteral("c-test"), trashName,
                         QStringLiteral("/影片/movie.mkv"));
    QTRY_COMPARE_WITH_TIMEOUT(restoredSpy.count(), 1, 5000);
    QCOMPARE(failedSpy.count(), 0);

    QVERIFY(QFile::exists(absolute(QStringLiteral("/影片/movie.mkv"))));
    QVERIFY(!QFile::exists(absolute(QStringLiteral("/.trash/") + trashName)));
    // meta 一并清理，避免留下「无主」残留
    QVERIFY(!QFile::exists(
        absolute(QStringLiteral("/.trash/") + trashName + QStringLiteral(".meta.json"))));

    const QList<QVariant> &args = restoredSpy.first();
    QCOMPARE(args.at(0).toString(), QStringLiteral("c-test"));
    QCOMPARE(args.at(1).toString(), trashName);
    QCOMPARE(args.at(2).toString(), QStringLiteral("/影片/movie.mkv"));

    // 还原后原目录缓存必须失效（列表要能立刻看到）
    QVERIFY(
        !DirectoryCache::instance().contains(QStringLiteral("c-test"), QStringLiteral("/影片")));
}

void TestTrash::restoreAppendsIndexWhenTargetExists()
{
    // 同名新文件占住了原路径：还原必须顺延为 `movie (1).mkv`，绝不覆盖
    trashEntry(QStringLiteral("/movie.mkv"), QByteArrayLiteral("trashed"));
    writeFile(QStringLiteral("/movie.mkv"), QByteArrayLiteral("newer"));

    auto &ops = FileOperations::instance();
    QSignalSpy restoredSpy(&ops, &FileOperations::restored);
    ops.restoreFromTrash(m_adapter.get(), QStringLiteral("c-test"), QStringLiteral("movie.mkv"),
                         QStringLiteral("/movie.mkv"));
    QTRY_COMPARE_WITH_TIMEOUT(restoredSpy.count(), 1, 5000);

    QCOMPARE(restoredSpy.first().at(2).toString(), QStringLiteral("/movie (1).mkv"));

    QFile existing(absolute(QStringLiteral("/movie.mkv")));
    QVERIFY(existing.open(QIODevice::ReadOnly));
    QCOMPARE(existing.readAll(), QByteArrayLiteral("newer")); // 未被覆盖
    existing.close();

    QFile restored(absolute(QStringLiteral("/movie (1).mkv")));
    QVERIFY(restored.open(QIODevice::ReadOnly));
    QCOMPARE(restored.readAll(), QByteArrayLiteral("trashed"));
}

void TestTrash::restoreRecreatesMissingParentFolder()
{
    trashEntry(QStringLiteral("/剧集/第一季/ep01.mkv"));

    // 整个父目录被删掉后再还原单文件：应自动重建目录，而不是直接失败
    QDir(absolute(QStringLiteral("/剧集"))).removeRecursively();

    auto &ops = FileOperations::instance();
    QSignalSpy restoredSpy(&ops, &FileOperations::restored);
    QSignalSpy failedSpy(&ops, &FileOperations::failed);

    ops.restoreFromTrash(m_adapter.get(), QStringLiteral("c-test"), QStringLiteral("ep01.mkv"),
                         QStringLiteral("/剧集/第一季/ep01.mkv"));
    QTRY_COMPARE_WITH_TIMEOUT(restoredSpy.count(), 1, 5000);
    QCOMPARE(failedSpy.count(), 0);
    QVERIFY(QFile::exists(absolute(QStringLiteral("/剧集/第一季/ep01.mkv"))));
}

void TestTrash::restoreRejectsEntryWithoutMeta()
{
    trashEntry(QStringLiteral("/lost.txt"));
    // 模拟删除记录丢失（例如别的客户端清掉/损坏了 meta）
    QVERIFY(QFile::remove(absolute(QStringLiteral("/.trash/lost.txt.meta.json"))));

    auto &ops = FileOperations::instance();
    QSignalSpy restoredSpy(&ops, &FileOperations::restored);
    QSignalSpy failedSpy(&ops, &FileOperations::failed);

    ops.restoreFromTrash(m_adapter.get(), QStringLiteral("c-test"), QStringLiteral("lost.txt"),
                         QString());
    QTRY_COMPARE_WITH_TIMEOUT(failedSpy.count(), 1, 5000);
    QCOMPARE(restoredSpy.count(), 0);

    // 不猜测原路径：条目留在回收站，文件不丢
    QVERIFY(QFile::exists(absolute(QStringLiteral("/.trash/lost.txt"))));
    QVERIFY(!QFile::exists(absolute(QStringLiteral("/lost.txt"))));
    QVERIFY(failedSpy.first().at(1).toString().contains(QStringLiteral("元数据")));
}

void TestTrash::purgesEntryWithMeta()
{
    trashEntry(QStringLiteral("/junk.txt"));
    const QString trashName = QStringLiteral("junk.txt");

    auto &ops = FileOperations::instance();
    QSignalSpy purgedSpy(&ops, &FileOperations::purged);
    QSignalSpy failedSpy(&ops, &FileOperations::failed);

    ops.purgeTrash(m_adapter.get(), QStringLiteral("c-test"), {trashName});
    QTRY_COMPARE_WITH_TIMEOUT(purgedSpy.count(), 1, 5000);
    QCOMPARE(failedSpy.count(), 0);

    QVERIFY(!QFile::exists(absolute(QStringLiteral("/.trash/") + trashName)));
    QVERIFY(!QFile::exists(
        absolute(QStringLiteral("/.trash/") + trashName + QStringLiteral(".meta.json"))));

    const QList<QVariant> &args = purgedSpy.first();
    QCOMPARE(args.at(0).toString(), QStringLiteral("c-test"));
    QCOMPARE(args.at(1).toStringList(), QStringList{trashName});
}

void TestTrash::purgesEntryWithoutMeta()
{
    // 无 meta 的条目只能彻底删除；清理 meta 时的 NotFound 不应被当成失败
    trashEntry(QStringLiteral("/ghost.bin"));
    const QString trashName = QStringLiteral("ghost.bin");
    QVERIFY(QFile::remove(absolute(QStringLiteral("/.trash/ghost.bin.meta.json"))));

    auto &ops = FileOperations::instance();
    QSignalSpy purgedSpy(&ops, &FileOperations::purged);
    QSignalSpy failedSpy(&ops, &FileOperations::failed);

    ops.purgeTrash(m_adapter.get(), QStringLiteral("c-test"), {trashName});
    QTRY_COMPARE_WITH_TIMEOUT(purgedSpy.count(), 1, 5000);
    QCOMPARE(failedSpy.count(), 0);

    QVERIFY(!QFile::exists(absolute(QStringLiteral("/.trash/ghost.bin"))));
    QCOMPARE(purgedSpy.first().at(1).toStringList(), QStringList{trashName});
}

void TestTrash::purgeAllRemovesEveryEntry()
{
    trashEntry(QStringLiteral("/one.txt"));
    trashEntry(QStringLiteral("/two.txt"));
    trashEntry(QStringLiteral("/three.txt"));

    auto &ops = FileOperations::instance();
    QSignalSpy purgedSpy(&ops, &FileOperations::purged);
    QSignalSpy failedSpy(&ops, &FileOperations::failed);

    ops.purgeTrash(
        m_adapter.get(), QStringLiteral("c-test"),
        {QStringLiteral("one.txt"), QStringLiteral("two.txt"), QStringLiteral("three.txt")});
    QTRY_COMPARE_WITH_TIMEOUT(purgedSpy.count(), 1, 5000);
    QCOMPARE(failedSpy.count(), 0);

    // 只剩目录本身，条目与 meta 全部清空
    const QStringList leftovers = QDir(absolute(QStringLiteral("/.trash")))
                                      .entryList(QDir::Files | QDir::Dirs | QDir::NoDotAndDotDot);
    QVERIFY2(leftovers.isEmpty(), qPrintable(leftovers.join(QStringLiteral(","))));
}

QTEST_MAIN(TestTrash)
#include "tst_trash.moc"
