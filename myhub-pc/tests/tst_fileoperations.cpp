// 文件操作单测：名称校验 / 回收站布局 / 新建 / 重命名 / 删除 / 阅读记录联动
//
// 走真实代码路径（LocalAdapter + DirectoryCache + ProgressRepository），
// 验证 §3.2「文件操作联动阅读记录」与 §3.3「回收站 + 命名冲突不覆盖」。
//
// 注意：本测试使用独立的临时数据目录，不污染用户真实数据。

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
#include "core/history/ProgressRepository.h"
#include "core/preferences/AppSettings.h"
#include "core/storage/LocalAdapter.h"
#include "core/storage/StoragePath.h"
#include "core/utils/AppPaths.h"

using namespace myhub;

class TestFileOperations : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void init();
    void nameValidation();
    void trashNameCandidates();
    void trashMetaRoundTrip();
    void createsFolder();
    void rejectsDuplicateFolder();
    void renamesFile();
    void rejectsDuplicateRename();
    void movesToTrashWithMeta();
    void trashDoesNotOverwriteSameName();
    void ignoresRootAndTrashEntries();
    void syncsProgressOnRename();
    void syncsProgressOnRemove();
    void inspectReportsLiveStatAndProgress();
    void cleanupTestCase();

private:
    QString rootPath() const { return m_root.path(); }
    QString absolute(const QString &rel) const { return rootPath() + rel; }
    void writeFile(const QString &rel, const QByteArray &content = QByteArrayLiteral("x"));
    void insertProgress(const QString &id, const QString &path, const QString &title = QString());

    QTemporaryDir m_root;
    std::unique_ptr<LocalAdapter> m_adapter;
    int m_counter = 0;
};

void TestFileOperations::initTestCase()
{
    // 隔离数据目录，避免污染真实用户数据
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

void TestFileOperations::init()
{
    // 每个用例独立的条目名，避免互相污染；回收站逐例清空
    QDir(rootPath() + QStringLiteral("/.trash")).removeRecursively();
    QDir(rootPath()).removeRecursively();
    QVERIFY(QDir().mkpath(rootPath()));
    ++m_counter;
}

void TestFileOperations::cleanupTestCase()
{
    AppDatabase::instance().close();
}

void TestFileOperations::writeFile(const QString &rel, const QByteArray &content)
{
    const QString path = absolute(rel);
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile file(path);
    QVERIFY2(file.open(QIODevice::WriteOnly), qPrintable(path));
    file.write(content);
}

void TestFileOperations::insertProgress(const QString &id, const QString &path,
                                        const QString &title)
{
    auto &db = AppDatabase::instance();
    QVERIFY(db.execute(QStringLiteral("INSERT INTO readingProgress "
                                      "(id,connectionID,filePath,mediaType,title,progressJSON,"
                                      "percent,finished,updatedAt,fileSize,modTime) "
                                      "VALUES (?,?,?,?,?,?,?,?,?,?,?)"),
                       {id, QStringLiteral("c-test"), path, QStringLiteral("video"),
                        title.isEmpty() ? StoragePath::baseName(path) : title, QStringLiteral("{}"),
                        0.5, 0, QDateTime::currentSecsSinceEpoch(), 1, 0}));
}

void TestFileOperations::nameValidation()
{
    QVERIFY(FileOperations::validateName(QStringLiteral("正常名称 02")).isEmpty());
    QVERIFY(FileOperations::validateName(QStringLiteral("a.tar.gz")).isEmpty());

    QVERIFY(!FileOperations::validateName(QString()).isEmpty());
    QVERIFY(!FileOperations::validateName(QStringLiteral("  ")).isEmpty());
    QVERIFY(!FileOperations::validateName(QStringLiteral("a/b")).isEmpty());
    QVERIFY(!FileOperations::validateName(QStringLiteral("a\\b")).isEmpty());
    QVERIFY(!FileOperations::validateName(QStringLiteral("a:b")).isEmpty());
    QVERIFY(!FileOperations::validateName(QStringLiteral("a*b")).isEmpty());
    QVERIFY(!FileOperations::validateName(QStringLiteral("a?b")).isEmpty());
    QVERIFY(!FileOperations::validateName(QStringLiteral("a\"b")).isEmpty());
    QVERIFY(!FileOperations::validateName(QStringLiteral("a<b")).isEmpty());
    QVERIFY(!FileOperations::validateName(QStringLiteral("a|b")).isEmpty());
    // 点开头的隐藏文件是合法名称
    QVERIFY(FileOperations::validateName(QStringLiteral(".hidden")).isEmpty());

    // 首尾空格 / 末尾点号 / 保留名 / 控制字符
    QVERIFY(!FileOperations::validateName(QStringLiteral(" a")).isEmpty());
    QVERIFY(!FileOperations::validateName(QStringLiteral("a ")).isEmpty());
    QVERIFY(!FileOperations::validateName(QStringLiteral("a.")).isEmpty());
    QVERIFY(!FileOperations::validateName(QStringLiteral(".")).isEmpty());
    QVERIFY(!FileOperations::validateName(QStringLiteral("..")).isEmpty());
    QVERIFY(!FileOperations::validateName(QStringLiteral("CON")).isEmpty());
    QVERIFY(!FileOperations::validateName(QStringLiteral("lpt1.txt")).isEmpty());
    QVERIFY(!FileOperations::validateName(QStringLiteral("a\tb")).isEmpty());
    QVERIFY(!FileOperations::validateName(QString(200, QLatin1Char('x'))).isEmpty());
}

void TestFileOperations::trashNameCandidates()
{
    QCOMPARE(TrashStore::candidateName(QStringLiteral("a.mp4"), 0), QStringLiteral("a.mp4"));
    QCOMPARE(TrashStore::candidateName(QStringLiteral("a.mp4"), 1), QStringLiteral("a (1).mp4"));
    QCOMPARE(TrashStore::candidateName(QStringLiteral("a.mp4"), 12), QStringLiteral("a (12).mp4"));
    // 无扩展名 / 多点名：序号都插在「最后一个扩展名」之前
    QCOMPARE(TrashStore::candidateName(QStringLiteral("README"), 2), QStringLiteral("README (2)"));
    QCOMPARE(TrashStore::candidateName(QStringLiteral("a.tar.gz"), 3),
             QStringLiteral("a.tar (3).gz"));

    QCOMPARE(TrashStore::trashDir(), QStringLiteral("/.trash"));
    QCOMPARE(TrashStore::entryPath(QStringLiteral("a.mp4")), QStringLiteral("/.trash/a.mp4"));
    QCOMPARE(TrashStore::metaPath(QStringLiteral("a.mp4")),
             QStringLiteral("/.trash/a.mp4.meta.json"));
    QVERIFY(TrashStore::isMetaName(QStringLiteral("a.mp4.meta.json")));
    QVERIFY(!TrashStore::isMetaName(QStringLiteral("a.mp4")));
    QVERIFY(TrashStore::isTrashDir(QStringLiteral("/.trash")));
}

void TestFileOperations::trashMetaRoundTrip()
{
    TrashStore::Meta meta;
    meta.connectionId = QStringLiteral("c-test");
    meta.originalPath = QStringLiteral("/剧集/ep1.mkv");
    meta.deletedAtMs = 1762300000000LL;

    const TrashStore::Meta parsed = TrashStore::decodeMeta(TrashStore::encodeMeta(meta));
    QCOMPARE(parsed.connectionId, meta.connectionId);
    QCOMPARE(parsed.originalPath, meta.originalPath);
    QCOMPARE(parsed.deletedAtMs, meta.deletedAtMs);
    QVERIFY(parsed.isValid());

    // 脏数据不猜原路径（宁可当作无主条目）
    QVERIFY(!TrashStore::decodeMeta(QByteArrayLiteral("not json")).isValid());
    QVERIFY(!TrashStore::decodeMeta(QByteArrayLiteral("{}")).isValid());
}

void TestFileOperations::createsFolder()
{
    auto &ops = FileOperations::instance();
    QSignalSpy createdSpy(&ops, &FileOperations::created);
    QSignalSpy failedSpy(&ops, &FileOperations::failed);

    ops.createFolder(m_adapter.get(), QStringLiteral("c-test"), QStringLiteral("/"),
                     QStringLiteral("新目录"));
    QTRY_COMPARE_WITH_TIMEOUT(createdSpy.count(), 1, 5000);
    QCOMPARE(failedSpy.count(), 0);

    QVERIFY(QDir(absolute(QStringLiteral("/新目录"))).exists());
    const QList<QVariant> &args = createdSpy.first();
    QCOMPARE(args.at(0).toString(), QStringLiteral("/"));
    QCOMPARE(args.at(1).toString(), QStringLiteral("/新目录"));
    QCOMPARE(args.at(2).toBool(), true);

    // 成功即失效目录缓存（否则用户要手动刷新才看得到）
    QVERIFY(!DirectoryCache::instance().contains(QStringLiteral("c-test"), QStringLiteral("/")));
}

void TestFileOperations::rejectsDuplicateFolder()
{
    writeFile(QStringLiteral("/重复目录/keep.txt"));

    auto &ops = FileOperations::instance();
    QSignalSpy createdSpy(&ops, &FileOperations::created);
    QSignalSpy failedSpy(&ops, &FileOperations::failed);

    ops.createFolder(m_adapter.get(), QStringLiteral("c-test"), QStringLiteral("/"),
                     QStringLiteral("重复目录"));
    QTRY_COMPARE_WITH_TIMEOUT(failedSpy.count(), 1, 5000);
    QCOMPARE(createdSpy.count(), 0);

    // 失败必须带具体原因（§3.3）
    const QList<QVariant> &args = failedSpy.first();
    QVERIFY(args.at(1).toString().contains(QStringLiteral("已存在")));
}

void TestFileOperations::renamesFile()
{
    writeFile(QStringLiteral("/旧名.txt"), QByteArrayLiteral("hello"));

    auto &ops = FileOperations::instance();
    QSignalSpy renamedSpy(&ops, &FileOperations::renamed);
    QSignalSpy failedSpy(&ops, &FileOperations::failed);

    ops.rename(m_adapter.get(), QStringLiteral("c-test"), QStringLiteral("/旧名.txt"),
               QStringLiteral("新名.txt"));
    QTRY_COMPARE_WITH_TIMEOUT(renamedSpy.count(), 1, 5000);
    QCOMPARE(failedSpy.count(), 0);

    QVERIFY(!QFile::exists(absolute(QStringLiteral("/旧名.txt"))));
    QVERIFY(QFile::exists(absolute(QStringLiteral("/新名.txt"))));
    QCOMPARE(renamedSpy.first().at(1).toString(), QStringLiteral("/新名.txt"));
}

void TestFileOperations::rejectsDuplicateRename()
{
    writeFile(QStringLiteral("/a.txt"));
    writeFile(QStringLiteral("/b.txt"));

    auto &ops = FileOperations::instance();
    QSignalSpy renamedSpy(&ops, &FileOperations::renamed);
    QSignalSpy failedSpy(&ops, &FileOperations::failed);

    ops.rename(m_adapter.get(), QStringLiteral("c-test"), QStringLiteral("/a.txt"),
               QStringLiteral("b.txt"));
    QTRY_COMPARE_WITH_TIMEOUT(failedSpy.count(), 1, 5000);
    QCOMPARE(renamedSpy.count(), 0);
    QVERIFY(failedSpy.first().at(1).toString().contains(QStringLiteral("已存在")));
    QVERIFY(QFile::exists(absolute(QStringLiteral("/a.txt"))));
}

void TestFileOperations::movesToTrashWithMeta()
{
    writeFile(QStringLiteral("/剧集/ep10.mkv"), QByteArrayLiteral("video-bytes"));

    auto &ops = FileOperations::instance();
    QSignalSpy removedSpy(&ops, &FileOperations::removed);
    QSignalSpy failedSpy(&ops, &FileOperations::failed);

    ops.removeToTrash(m_adapter.get(), QStringLiteral("c-test"),
                      {QStringLiteral("/剧集/ep10.mkv")});
    QTRY_COMPARE_WITH_TIMEOUT(removedSpy.count(), 1, 5000);
    QCOMPARE(failedSpy.count(), 0);

    // 原位置没了，回收站里原样保管
    QVERIFY(!QFile::exists(absolute(QStringLiteral("/剧集/ep10.mkv"))));
    QVERIFY(QFile::exists(absolute(QStringLiteral("/.trash/ep10.mkv"))));

    // 元数据记录原路径 + 删除时间，还原才可能
    QFile meta(absolute(QStringLiteral("/.trash/ep10.mkv.meta.json")));
    QVERIFY(meta.open(QIODevice::ReadOnly));
    const TrashStore::Meta parsed = TrashStore::decodeMeta(meta.readAll());
    QVERIFY(parsed.isValid());
    QCOMPARE(parsed.originalPath, QStringLiteral("/剧集/ep10.mkv"));
    QCOMPARE(parsed.connectionId, QStringLiteral("c-test"));
    QVERIFY(parsed.deletedAtMs > 0);

    QCOMPARE(removedSpy.first().at(1).toBool(), true); // toTrash
}

void TestFileOperations::trashDoesNotOverwriteSameName()
{
    writeFile(QStringLiteral("/a.txt"), QByteArrayLiteral("first"));
    auto &ops = FileOperations::instance();

    QSignalSpy first(&ops, &FileOperations::removed);
    ops.removeToTrash(m_adapter.get(), QStringLiteral("c-test"), {QStringLiteral("/a.txt")});
    QTRY_COMPARE_WITH_TIMEOUT(first.count(), 1, 5000);

    // 同名文件再删一次：回收站里必须顺延序号，不能把上一份顶掉
    writeFile(QStringLiteral("/a.txt"), QByteArrayLiteral("second"));
    QSignalSpy second(&ops, &FileOperations::removed);
    ops.removeToTrash(m_adapter.get(), QStringLiteral("c-test"), {QStringLiteral("/a.txt")});
    QTRY_COMPARE_WITH_TIMEOUT(second.count(), 1, 5000);

    QVERIFY(QFile::exists(absolute(QStringLiteral("/.trash/a.txt"))));
    QVERIFY(QFile::exists(absolute(QStringLiteral("/.trash/a (1).txt"))));

    QFile kept(absolute(QStringLiteral("/.trash/a.txt")));
    QVERIFY(kept.open(QIODevice::ReadOnly));
    QCOMPARE(kept.readAll(), QByteArrayLiteral("first"));
}

void TestFileOperations::ignoresRootAndTrashEntries()
{
    writeFile(QStringLiteral("/.trash/old.bin"), QByteArrayLiteral("x"));

    auto &ops = FileOperations::instance();
    QSignalSpy removedSpy(&ops, &FileOperations::removed);
    QSignalSpy failedSpy(&ops, &FileOperations::failed);

    ops.removeToTrash(m_adapter.get(), QStringLiteral("c-test"),
                      {QStringLiteral("/"), QStringLiteral("/.trash/old.bin")});
    QTest::qWait(300);

    QCOMPARE(removedSpy.count(), 0);
    QCOMPARE(failedSpy.count(), 0);
    QVERIFY(QFile::exists(absolute(QStringLiteral("/.trash/old.bin"))));
}

void TestFileOperations::syncsProgressOnRename()
{
    writeFile(QStringLiteral("/剧集/ep1.mkv"));
    insertProgress(QStringLiteral("p-rename"), QStringLiteral("/剧集/ep1.mkv"));

    auto &ops = FileOperations::instance();
    QSignalSpy renamedSpy(&ops, &FileOperations::renamed);
    ops.rename(m_adapter.get(), QStringLiteral("c-test"), QStringLiteral("/剧集/ep1.mkv"),
               QStringLiteral("ep1-改.mkv"));
    QTRY_COMPARE_WITH_TIMEOUT(renamedSpy.count(), 1, 5000);

    // 记录跟着改名：否则「正在阅读」里会留下点开即失败的幽灵条目
    auto &repo = ProgressRepository::instance();
    ProgressRecord record;
    QVERIFY(repo.find(QStringLiteral("c-test"), QStringLiteral("/剧集/ep1-改.mkv"), &record));
    QCOMPARE(record.title, QStringLiteral("ep1-改"));

    ProgressRecord stale;
    QVERIFY(!repo.find(QStringLiteral("c-test"), QStringLiteral("/剧集/ep1.mkv"), &stale));
}

void TestFileOperations::syncsProgressOnRemove()
{
    writeFile(QStringLiteral("/漫画/vol1.cbz"));
    insertProgress(QStringLiteral("p-rm-1"), QStringLiteral("/漫画/vol1.cbz"));
    insertProgress(QStringLiteral("p-rm-2"), QStringLiteral("/漫画/vol1.cbz/sub/page.png"));
    insertProgress(QStringLiteral("p-rm-3"), QStringLiteral("/漫画/vol2.cbz"));

    auto &ops = FileOperations::instance();
    QSignalSpy removedSpy(&ops, &FileOperations::removed);
    ops.removeToTrash(m_adapter.get(), QStringLiteral("c-test"),
                      {QStringLiteral("/漫画/vol1.cbz")});
    QTRY_COMPARE_WITH_TIMEOUT(removedSpy.count(), 1, 5000);

    // 条目与其子树记录一并清除，兄弟条目不受影响
    auto &repo = ProgressRepository::instance();
    ProgressRecord record;
    QVERIFY(!repo.find(QStringLiteral("c-test"), QStringLiteral("/漫画/vol1.cbz"), &record));
    QVERIFY(!repo.find(QStringLiteral("c-test"), QStringLiteral("/漫画/vol1.cbz/sub/page.png"),
                       &record));
    QVERIFY(repo.find(QStringLiteral("c-test"), QStringLiteral("/漫画/vol2.cbz"), &record));
}

void TestFileOperations::inspectReportsLiveStatAndProgress()
{
    writeFile(QStringLiteral("/inspect/movie.mkv"), QByteArrayLiteral("0123456789"));

    // 阅读进度：位置 4.2s / 总 10s / 42%
    ProgressRecord record;
    record.connectionId = QStringLiteral("c-test");
    record.path = QStringLiteral("/inspect/movie.mkv");
    record.mediaType = QStringLiteral("video");
    record.title = QStringLiteral("movie.mkv");
    record.percent = 0.42;
    record.progress.insert(QStringLiteral("positionMs"), 4200);
    record.progress.insert(QStringLiteral("durationMs"), 10000);
    QVERIFY(ProgressRepository::instance().upsert(record));

    auto &ops = FileOperations::instance();
    QSignalSpy spy(&ops, &FileOperations::inspected);
    ops.inspect(m_adapter.get(), QStringLiteral("c-test"), QStringLiteral("/inspect/movie.mkv"));
    QTRY_COMPARE_WITH_TIMEOUT(spy.count(), 1, 5000);
    QCOMPARE(spy.first().at(0).toString(), QStringLiteral("c-test"));

    const QVariantMap info = spy.first().at(2).toMap();
    QCOMPARE(info.value(QStringLiteral("name")).toString(), QStringLiteral("movie.mkv"));
    // 现场 stat：大小取自文件本身，不是任何缓存的列数据
    QCOMPARE(info.value(QStringLiteral("size")).toLongLong(), qint64(10));
    QCOMPARE(info.value(QStringLiteral("isDir")).toBool(), false);
    QVERIFY(!info.value(QStringLiteral("sizeText")).toString().isEmpty());
    QVERIFY(!info.value(QStringLiteral("modTimeText")).toString().isEmpty());
    QCOMPARE(info.value(QStringLiteral("mediaKind")).toString(), QStringLiteral("video"));
    QCOMPARE(info.value(QStringLiteral("hasProgress")).toBool(), true);
    QCOMPARE(info.value(QStringLiteral("progressPercent")).toDouble(), 0.42);
    QCOMPARE(info.value(QStringLiteral("resumeMs")).toLongLong(), qint64(4200));

    // 未读过的条目不得伪造进度
    writeFile(QStringLiteral("/inspect/plain.txt"));
    QSignalSpy plainSpy(&ops, &FileOperations::inspected);
    ops.inspect(m_adapter.get(), QStringLiteral("c-test"), QStringLiteral("/inspect/plain.txt"));
    QTRY_COMPARE_WITH_TIMEOUT(plainSpy.count(), 1, 5000);
    const QVariantMap plain = plainSpy.first().at(2).toMap();
    QCOMPARE(plain.value(QStringLiteral("hasProgress")).toBool(), false);
    QCOMPARE(plain.value(QStringLiteral("textEditable")).toBool(), true);

    // 已被删除的条目：明确失败，而不是回一份空属性
    QSignalSpy failedSpy(&ops, &FileOperations::inspectFailed);
    ops.inspect(m_adapter.get(), QStringLiteral("c-test"), QStringLiteral("/inspect/missing.mkv"));
    QTRY_COMPARE_WITH_TIMEOUT(failedSpy.count(), 1, 5000);
}

QTEST_MAIN(TestFileOperations)
#include "tst_fileoperations.moc"
