// 端到端集成测试：连接源 → 适配器 → 目录列举 → 缓存
//
// 走真实代码路径（AppDatabase / ConnectionStore 的底层依赖 / LocalAdapter /
// DirectoryCache），验证 M0 的浏览链路是否打通。
//
// 注意：本测试使用独立的临时数据目录，不污染用户真实数据。

#include <QtTest>
#include <QSignalSpy>
#include <QStandardPaths>
#include <QTemporaryDir>

#include "core/cache/DirectoryCache.h"
#include "core/database/AppDatabase.h"
#include "core/preferences/AppSettings.h"
#include "core/storage/LocalAdapter.h"
#include "core/storage/StorageAdapterFactory.h"
#include "core/utils/AppPaths.h"

using namespace myhub;

class TestE2EBrowse : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void databaseMigratesToTargetVersion();
    void connectionCrudRoundTrip();
    void localAdapterListsDirectory();
    void localAdapterRejectsMissingRoot();
    void localAdapterStatAndRead();
    void directoryCacheRoundTrip();
    void directoryCacheRefusesUnverifiedEmpty();
    void factoryRejectsUnsupportedProtocol();
    void cleanupTestCase();

private:
    QTemporaryDir m_sampleDir;
    QString m_root;
};

void TestE2EBrowse::initTestCase()
{
    // 隔离数据目录，避免污染真实用户数据
    QCoreApplication::setApplicationName(
        QStringLiteral("MyHubTest-%1").arg(QCoreApplication::applicationPid()));
    QStandardPaths::setTestModeEnabled(true);

    AppPaths::initializeAll();
    AppSettings::instance().initialize();

    QVERIFY(m_sampleDir.isValid());
    m_root = m_sampleDir.path();

    // 构造素材树
    QDir d(m_root);
    QVERIFY(d.mkpath(QStringLiteral("剧集")));
    QVERIFY(d.mkpath(QStringLiteral("漫画")));
    QVERIFY(d.mkpath(QStringLiteral(".trash"))); // 应被过滤

    auto writeFile = [](const QString &path, const QByteArray &content) {
        QFile f(path);
        QVERIFY2(f.open(QIODevice::WriteOnly), qPrintable(path));
        f.write(content);
    };
    writeFile(m_root + QStringLiteral("/note.txt"), QByteArrayLiteral("hello myhub"));
    writeFile(m_root + QStringLiteral("/剧集/ep10.mkv"), QByteArrayLiteral("v"));
    writeFile(m_root + QStringLiteral("/剧集/ep2.mkv"), QByteArrayLiteral("v"));
    writeFile(m_root + QStringLiteral("/漫画/vol1.cbz"), QByteArrayLiteral("c"));
    writeFile(m_root + QStringLiteral("/.trash/deleted.bin"), QByteArrayLiteral("x"));
}

void TestE2EBrowse::databaseMigratesToTargetVersion()
{
    auto &db = AppDatabase::instance();
    QSignalSpy readySpy(&db, &AppDatabase::ready);

    QVERIFY2(db.open(), qPrintable(db.lastError()));
    QCOMPARE(readySpy.count(), 1);
    QCOMPARE(db.schemaVersion(), 2);

    // 9 张表齐备（§5.3）
    const QStringList expected = {
        QStringLiteral("connection"),      QStringLiteral("favorite"),
        QStringLiteral("readingProgress"), QStringLiteral("novelIndex"),
        QStringLiteral("bookmark"),        QStringLiteral("browserHistory"),
        QStringLiteral("browserShortcut"), QStringLiteral("downloadTask"),
        QStringLiteral("feedItem"),
    };
    for (const QString &t : expected) {
        const QVariant n = db.queryScalar(
            QStringLiteral("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?"),
            {t});
        QVERIFY2(n.toInt() == 1, qPrintable(QStringLiteral("missing table: %1").arg(t)));
    }

    // v2 的指纹列
    const auto cols = db.query(QStringLiteral("PRAGMA table_info(readingProgress)"));
    QStringList names;
    for (const auto &c : cols)
        names << c.value(QStringLiteral("name")).toString();
    QVERIFY(names.contains(QStringLiteral("fileSize")));
    QVERIFY(names.contains(QStringLiteral("modTime")));
}

void TestE2EBrowse::connectionCrudRoundTrip()
{
    auto &db = AppDatabase::instance();
    const qint64 now = QDateTime::currentSecsSinceEpoch();

    QVERIFY(db.execute(QStringLiteral("INSERT INTO connection "
                                      "(id,name,type,configJSON,mountPoint,enabled,createdAt) "
                                      "VALUES (?,?,?,?,?,?,?)"),
                       {QStringLiteral("c1"), QStringLiteral("本地源"), QStringLiteral("local"),
                        QStringLiteral("{\"path\":\"D:/x\"}"), QStringLiteral("/L"), 1, now}));

    auto rows =
        db.query(QStringLiteral("SELECT * FROM connection WHERE id=?"), {QStringLiteral("c1")});
    QCOMPARE(rows.size(), 1);
    QCOMPARE(rows.first().value(QStringLiteral("name")).toString(), QStringLiteral("本地源"));

    // unique(mountPoint) 约束生效
    QVERIFY(!db.execute(QStringLiteral("INSERT INTO connection "
                                       "(id,name,type,configJSON,mountPoint,enabled,createdAt) "
                                       "VALUES (?,?,?,?,?,?,?)"),
                        {QStringLiteral("c2"), QStringLiteral("冲突"), QStringLiteral("local"),
                         QStringLiteral("{}"), QStringLiteral("/L"), 1, now}));

    // 外键级联：删除连接源后收藏一并清除
    QVERIFY(db.execute(QStringLiteral("INSERT INTO favorite "
                                      "(id,connectionID,filePath,mediaType,size,createdAt) "
                                      "VALUES (?,?,?,?,?,?)"),
                       {QStringLiteral("f1"), QStringLiteral("c1"), QStringLiteral("/a.mkv"),
                        QStringLiteral("video"), 1, now}));
    QCOMPARE(db.queryScalar(QStringLiteral("SELECT COUNT(*) FROM favorite")).toInt(), 1);

    QVERIFY(
        db.execute(QStringLiteral("DELETE FROM connection WHERE id=?"), {QStringLiteral("c1")}));
    QCOMPARE(db.queryScalar(QStringLiteral("SELECT COUNT(*) FROM favorite")).toInt(), 0);
}

void TestE2EBrowse::localAdapterListsDirectory()
{
    LocalAdapter adapter(m_root);

    ListResult captured;
    bool done = false;
    adapter.list(QStringLiteral("/"), [&](ListResult r) {
        captured = std::move(r);
        done = true;
    });
    QTRY_VERIFY_WITH_TIMEOUT(done, 5000);

    QVERIFY2(captured.ok(), qPrintable(captured.error.message()));

    QStringList names;
    for (const FileEntry &e : captured.value)
        names << e.name;

    QVERIFY(names.contains(QStringLiteral("note.txt")));
    QVERIFY(names.contains(QStringLiteral("剧集")));
    QVERIFY(names.contains(QStringLiteral("漫画")));
    // .trash 是回收站实现细节，不得呈现给用户
    QVERIFY(!names.contains(QStringLiteral(".trash")));

    // 目录与文件的元信息正确
    for (const FileEntry &e : captured.value) {
        if (e.name == QStringLiteral("剧集")) {
            QVERIFY(e.isDir);
            QCOMPARE(e.size, 0);
            QCOMPARE(e.path, QStringLiteral("/剧集"));
        }
        if (e.name == QStringLiteral("note.txt")) {
            QVERIFY(!e.isDir);
            QCOMPARE(e.ext, QStringLiteral("txt"));
            QVERIFY(e.size > 0);
            QVERIFY(!e.fingerprint().isEmpty());
        }
    }

    // 子目录列举
    done = false;
    adapter.list(QStringLiteral("/剧集"), [&](ListResult r) {
        captured = std::move(r);
        done = true;
    });
    QTRY_VERIFY_WITH_TIMEOUT(done, 5000);
    QVERIFY(captured.ok());
    QCOMPARE(captured.value.size(), 2);
}

void TestE2EBrowse::localAdapterRejectsMissingRoot()
{
    LocalAdapter adapter(m_root + QStringLiteral("/__not_exist__"));

    StorageError err;
    bool done = false;
    adapter.testConnection([&](StorageError e) {
        err = e;
        done = true;
    });
    QTRY_VERIFY_WITH_TIMEOUT(done, 5000);

    QVERIFY(!err.isNull());
    QCOMPARE(err.kind(), StorageError::NotFound);
    // 失败提示必须携带具体原因（§3.3）
    QVERIFY(!err.userMessage().isEmpty());
}

void TestE2EBrowse::localAdapterStatAndRead()
{
    LocalAdapter adapter(m_root);

    StatResult stat;
    bool done = false;
    adapter.stat(QStringLiteral("/note.txt"), [&](StatResult r) {
        stat = r;
        done = true;
    });
    QTRY_VERIFY_WITH_TIMEOUT(done, 5000);
    QVERIFY(stat.ok());
    QCOMPARE(stat.value.name, QStringLiteral("note.txt"));
    QCOMPARE(stat.value.size, 11); // "hello myhub"

    // 整文件读取
    DataResult data;
    done = false;
    adapter.readRange(QStringLiteral("/note.txt"), std::nullopt, std::nullopt, [&](DataResult r) {
        data = r;
        done = true;
    });
    QTRY_VERIFY_WITH_TIMEOUT(done, 5000);
    QVERIFY(data.ok());
    QCOMPARE(data.value, QByteArrayLiteral("hello myhub"));

    // Range 读取（封面提取 / 边下边播依赖此能力）
    done = false;
    adapter.readRange(QStringLiteral("/note.txt"), 6, 10, [&](DataResult r) {
        data = r;
        done = true;
    });
    QTRY_VERIFY_WITH_TIMEOUT(done, 5000);
    QVERIFY(data.ok());
    QCOMPARE(data.value, QByteArrayLiteral("myhub"));
}

void TestE2EBrowse::directoryCacheRoundTrip()
{
    auto &cache = DirectoryCache::instance();
    const QString conn = QStringLiteral("conn-x");
    const QString path = QStringLiteral("/剧集");

    FileEntryList entries;
    FileEntry a;
    a.name = QStringLiteral("ep2.mkv");
    a.path = QStringLiteral("/剧集/ep2.mkv");
    a.ext = QStringLiteral("mkv");
    a.size = 100;
    a.modTime = QDateTime::currentDateTime();
    entries << a;

    cache.store(conn, path, entries);
    QVERIFY(cache.contains(conn, path));

    FileEntryList loaded;
    QVERIFY(cache.load(conn, path, &loaded));
    QCOMPARE(loaded.size(), 1);
    QCOMPARE(loaded.first().name, QStringLiteral("ep2.mkv"));
    QCOMPARE(loaded.first().size, 100);
    QCOMPARE(loaded.first().ext, QStringLiteral("mkv"));

    cache.invalidate(conn, path);
    QVERIFY(!cache.contains(conn, path));
}

void TestE2EBrowse::directoryCacheRefusesUnverifiedEmpty()
{
    // 关键纪律：异常响应导致的空列表**严禁**被当作「空目录」写入缓存（PC-708）
    auto &cache = DirectoryCache::instance();
    const QString conn = QStringLiteral("conn-y");
    const QString path = QStringLiteral("/maybe-broken");

    cache.store(conn, path, {}, /*verifiedEmpty=*/false);
    QVERIFY2(!cache.contains(conn, path), "unverified empty listing must not be cached");

    // 确认为真空目录时才允许写入
    cache.store(conn, path, {}, /*verifiedEmpty=*/true);
    QVERIFY(cache.contains(conn, path));

    FileEntryList loaded;
    QVERIFY(cache.load(conn, path, &loaded));
    QVERIFY(loaded.isEmpty());

    cache.invalidate(conn, path);
}

void TestE2EBrowse::factoryRejectsUnsupportedProtocol()
{
    // FTP / SFTP / NFS 为预留枚举，工厂必须明确抛「暂不支持」（§2.4）
    ConnectionRecord r;
    r.id = QStringLiteral("ftp1");
    r.name = QStringLiteral("FTP");
    r.type = ConnectionType::FTP;

    StorageError err;
    StorageAdapter *adapter = StorageAdapterFactory::create(r, QString(), &err);
    QVERIFY(adapter == nullptr);
    QCOMPARE(err.kind(), StorageError::UnsupportedProtocol);

    // 配置缺失时也必须明确失败，不得静默成功
    ConnectionRecord bad;
    bad.id = QStringLiteral("l1");
    bad.type = ConnectionType::Local;
    adapter = StorageAdapterFactory::create(bad, QString(), &err);
    QVERIFY(adapter == nullptr);
    QCOMPARE(err.kind(), StorageError::InvalidConfig);
}

void TestE2EBrowse::cleanupTestCase()
{
    AppDatabase::instance().close();
}

QTEST_MAIN(TestE2EBrowse)
#include "tst_e2e_browse.moc"
