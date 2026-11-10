// 移动 / 复制单测（PC-104）：
//   - 同源：文件 move/copy、目录递归复制、同名顺延、同目录移动无操作
//   - 跨源：流式中转（多分块、内容完整、源被删除、不残留 .myhub-part）
//   - 纪律：不能移动到自己内部、取消后不留痕、移动改写阅读记录
//   - 管道本身：RelayStream 能跨线程送出全部字节、abort 能立刻解除阻塞
//
// 走真实代码路径（LocalAdapter + RelayStream + FileOperations），临时目录隔离。

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSignalSpy>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QtTest>
#include <atomic>
#include <memory>
#include <thread>

#include "core/database/AppDatabase.h"
#include "core/files/FileOperations.h"
#include "core/preferences/AppSettings.h"
#include "core/storage/LocalAdapter.h"
#include "core/storage/StoragePath.h"
#include "core/transfer/RelayStream.h"
#include "core/utils/AppPaths.h"

using namespace myhub;

namespace {

constexpr qsizetype kOneKiB = 1024;

/// 可校验的伪随机内容（同一 seed 同一结果）
QByteArray patterned(qsizetype size, char seed)
{
    QByteArray data(size, Qt::Uninitialized);
    for (qsizetype i = 0; i < size; ++i) {
        data[i] = char((i * 31 + qsizetype(seed) * 17) & 0xFF);
    }
    return data;
}

} // namespace

class TestMoveCopy : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void init();
    void relayStreamDeliversData();
    void relayStreamAbortUnblocksReader();
    void movesFileWithinSource();
    void copiesFileKeepsSource();
    void copyAppendsIndexOnConflict();
    void copiesDirectoryRecursively();
    void movesAcrossSourcesStreaming();
    void movesReadingProgressAlong();
    void rejectsMoveIntoItself();
    void skipsMoveIntoSameDirectory();
    void cancelBeforeStartLeavesNoTrace();
    void cleanupTestCase();

private:
    FileOperations::TransferRequest
    request(bool copy, const QStringList &paths, const QString &targetDir,
            const QString &targetConnection = QStringLiteral("c-src"),
            StorageAdapter *destination = nullptr) const;

    void writeAt(const QString &root, const QString &rel, const QByteArray &data);
    void bakeDirectory(const QString &root, const QString &rel);
    bool exists(const QString &root, const QString &rel) const;
    QByteArray readAt(const QString &root, const QString &rel) const;
    void waitIdle();
    void insertProgress(const QString &id, const QString &path);

    QTemporaryDir m_src;
    QTemporaryDir m_dst;
    std::unique_ptr<LocalAdapter> m_adapter; ///< 源连接源
    std::unique_ptr<LocalAdapter> m_other;   ///< 目标连接源（跨源用）
    int m_counter = 0;
};

void TestMoveCopy::initTestCase()
{
    QCoreApplication::setApplicationName(
        QStringLiteral("MyHubTest-%1").arg(QCoreApplication::applicationPid()));
    QStandardPaths::setTestModeEnabled(true);

    AppPaths::initializeAll();
    AppSettings::instance().initialize();

    auto &db = AppDatabase::instance();
    QVERIFY2(db.open(), qPrintable(db.lastError()));

    QVERIFY(m_src.isValid());
    QVERIFY(m_dst.isValid());
    m_adapter = std::make_unique<LocalAdapter>(m_src.path());
    m_other = std::make_unique<LocalAdapter>(m_dst.path());
}

void TestMoveCopy::init()
{
    waitIdle();
    QDir(m_src.path()).removeRecursively();
    QDir(m_dst.path()).removeRecursively();
    QVERIFY(QDir().mkpath(m_src.path()));
    QVERIFY(QDir().mkpath(m_dst.path()));
    ++m_counter;
}

void TestMoveCopy::cleanupTestCase()
{
    AppDatabase::instance().close();
}

FileOperations::TransferRequest TestMoveCopy::request(bool copy, const QStringList &paths,
                                                      const QString &targetDir,
                                                      const QString &targetConnection,
                                                      StorageAdapter *destination) const
{
    FileOperations::TransferRequest req;
    req.source = m_adapter.get();
    req.sourceConnectionId = QStringLiteral("c-src");
    req.paths = paths;
    req.copy = copy;
    req.target.adapter = destination ? destination : m_adapter.get();
    req.target.connectionId = targetConnection;
    req.target.directory = targetDir;
    return req;
}

void TestMoveCopy::writeAt(const QString &root, const QString &rel, const QByteArray &data)
{
    const QString path = root + rel;
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile file(path);
    QVERIFY2(file.open(QIODevice::WriteOnly | QIODevice::Truncate), qPrintable(path));
    QCOMPARE(file.write(data), data.size());
}

void TestMoveCopy::bakeDirectory(const QString &root, const QString &rel)
{
    writeAt(root, rel + QStringLiteral("/a.txt"), QByteArrayLiteral("aaaa"));
    writeAt(root, rel + QStringLiteral("/sub/b.txt"), QByteArrayLiteral("bbbbbb"));
}

bool TestMoveCopy::exists(const QString &root, const QString &rel) const
{
    return QFileInfo::exists(root + rel);
}

QByteArray TestMoveCopy::readAt(const QString &root, const QString &rel) const
{
    QFile file(root + rel);
    if (!file.open(QIODevice::ReadOnly)) {
        return {};
    }
    return file.readAll();
}

void TestMoveCopy::waitIdle()
{
    QTRY_VERIFY_WITH_TIMEOUT(!FileOperations::instance().transferring(), 20000);
}

void TestMoveCopy::insertProgress(const QString &id, const QString &path)
{
    auto &db = AppDatabase::instance();
    QVERIFY(db.execute(QStringLiteral("INSERT INTO readingProgress "
                                      "(id,connectionID,filePath,mediaType,title,progressJSON,"
                                      "percent,finished,updatedAt) "
                                      "VALUES (?,?,?,?,?,?,?,?,?)"),
                       {id, QStringLiteral("c-src"), path, QStringLiteral("video"),
                        StoragePath::baseName(path), QStringLiteral("{}"), 0.4, 0,
                        QDateTime::currentSecsSinceEpoch()}));
}

// ---------------- 管道本身 ----------------

void TestMoveCopy::relayStreamDeliversData()
{
    const QByteArray payload = patterned(3 * kOneKiB * kOneKiB + 7, 'R');
    auto stream = std::make_unique<RelayStream>(payload.size());

    QByteArray received;
    std::atomic_bool done{false};
    // 消费者在另一个线程按序读（模拟 QNAM http 线程 / 本地线程池）
    std::thread reader([&stream, &received, &done]() {
        received = stream->readAll();
        done.store(true);
    });

    for (qsizetype offset = 0; offset < payload.size(); offset += 512 * kOneKiB) {
        QVERIFY(stream->append(payload.mid(offset, 512 * kOneKiB)));
    }
    stream->finish();

    QTRY_VERIFY_WITH_TIMEOUT(done.load(), 10000);
    reader.join();
    QCOMPARE(received, payload);
}

void TestMoveCopy::relayStreamAbortUnblocksReader()
{
    auto stream = std::make_unique<RelayStream>(1024);
    std::atomic_int result{-2};
    std::thread reader([&stream, &result]() {
        char buffer[16];
        result.store(int(stream->read(buffer, sizeof(buffer))));
    });

    QTest::qWait(50);
    stream->abort(StorageError(StorageError::Cancelled, QStringLiteral("已取消")));

    QTRY_VERIFY_WITH_TIMEOUT(result.load() != -2, 5000);
    reader.join();
    QCOMPARE(result.load(), -1);
}

// ---------------- 同源 ----------------

void TestMoveCopy::movesFileWithinSource()
{
    auto &ops = FileOperations::instance();
    const QByteArray payload = patterned(256 * kOneKiB, 'M');
    writeAt(m_src.path(), QStringLiteral("/in/a.mkv"), payload);
    QVERIFY(QDir().mkpath(m_src.path() + QStringLiteral("/out")));

    QSignalSpy transferred(&ops, &FileOperations::transferred);
    QSignalSpy failed(&ops, &FileOperations::failed);

    ops.moveOrCopy(request(false, {QStringLiteral("/in/a.mkv")}, QStringLiteral("/out")));
    waitIdle();

    QCOMPARE(failed.count(), 0);
    QCOMPARE(transferred.count(), 1);
    QVERIFY(!exists(m_src.path(), QStringLiteral("/in/a.mkv")));
    QCOMPARE(readAt(m_src.path(), QStringLiteral("/out/a.mkv")), payload);

    const QList<QVariant> &args = transferred.first();
    QCOMPARE(args.at(0).toString(), QStringLiteral("c-src"));
    QCOMPARE(args.at(1).toStringList(), QStringList{QStringLiteral("/in/a.mkv")});
    QCOMPARE(args.at(2).toString(), QStringLiteral("c-src"));
    QCOMPARE(args.at(3).toString(), QStringLiteral("/out"));
    QCOMPARE(args.at(4).toStringList(), QStringList{QStringLiteral("/out/a.mkv")});
    QCOMPARE(args.at(5).toBool(), false);
}

void TestMoveCopy::copiesFileKeepsSource()
{
    auto &ops = FileOperations::instance();
    writeAt(m_src.path(), QStringLiteral("/a.mkv"), QByteArrayLiteral("payload"));
    QVERIFY(QDir().mkpath(m_src.path() + QStringLiteral("/out")));

    QSignalSpy failed(&ops, &FileOperations::failed);
    ops.moveOrCopy(request(true, {QStringLiteral("/a.mkv")}, QStringLiteral("/out")));
    waitIdle();

    QCOMPARE(failed.count(), 0);
    QVERIFY(exists(m_src.path(), QStringLiteral("/a.mkv")));
    QCOMPARE(readAt(m_src.path(), QStringLiteral("/out/a.mkv")), QByteArrayLiteral("payload"));
}

void TestMoveCopy::copyAppendsIndexOnConflict()
{
    auto &ops = FileOperations::instance();
    writeAt(m_src.path(), QStringLiteral("/a.mkv"), QByteArrayLiteral("新"));
    writeAt(m_src.path(), QStringLiteral("/out/a.mkv"), QByteArrayLiteral("旧"));
    writeAt(m_src.path(), QStringLiteral("/out/a (1).mkv"), QByteArrayLiteral("旧1"));

    QSignalSpy failed(&ops, &FileOperations::failed);
    ops.moveOrCopy(request(true, {QStringLiteral("/a.mkv")}, QStringLiteral("/out")));
    waitIdle();

    QCOMPARE(failed.count(), 0);
    // 绝不覆盖：顺延到 a (2).mkv
    QCOMPARE(readAt(m_src.path(), QStringLiteral("/out/a.mkv")), QByteArrayLiteral("旧"));
    QCOMPARE(readAt(m_src.path(), QStringLiteral("/out/a (1).mkv")), QByteArrayLiteral("旧1"));
    QCOMPARE(readAt(m_src.path(), QStringLiteral("/out/a (2).mkv")), QByteArrayLiteral("新"));
}

void TestMoveCopy::copiesDirectoryRecursively()
{
    auto &ops = FileOperations::instance();
    bakeDirectory(m_src.path(), QStringLiteral("/dir"));
    QVERIFY(QDir().mkpath(m_src.path() + QStringLiteral("/out")));

    QSignalSpy failed(&ops, &FileOperations::failed);
    ops.moveOrCopy(request(true, {QStringLiteral("/dir")}, QStringLiteral("/out")));
    waitIdle();

    QCOMPARE(failed.count(), 0);
    QCOMPARE(readAt(m_src.path(), QStringLiteral("/out/dir/a.txt")), QByteArrayLiteral("aaaa"));
    QCOMPARE(readAt(m_src.path(), QStringLiteral("/out/dir/sub/b.txt")),
             QByteArrayLiteral("bbbbbb"));
    // 复制不动源
    QVERIFY(exists(m_src.path(), QStringLiteral("/dir/sub/b.txt")));
}

void TestMoveCopy::skipsMoveIntoSameDirectory()
{
    auto &ops = FileOperations::instance();
    writeAt(m_src.path(), QStringLiteral("/a.mkv"), QByteArrayLiteral("x"));
    QSignalSpy failed(&ops, &FileOperations::failed);

    ops.moveOrCopy(request(false, {QStringLiteral("/a.mkv")}, QStringLiteral("/")));
    waitIdle();

    QCOMPARE(failed.count(), 0);
    QCOMPARE(readAt(m_src.path(), QStringLiteral("/a.mkv")), QByteArrayLiteral("x"));
}

void TestMoveCopy::rejectsMoveIntoItself()
{
    auto &ops = FileOperations::instance();
    bakeDirectory(m_src.path(), QStringLiteral("/dir"));

    QSignalSpy failed(&ops, &FileOperations::failed);
    ops.moveOrCopy(request(false, {QStringLiteral("/dir")}, QStringLiteral("/dir/sub")));
    waitIdle();

    QCOMPARE(failed.count(), 1);
    QVERIFY(exists(m_src.path(), QStringLiteral("/dir/a.txt")));
    QVERIFY(!exists(m_src.path(), QStringLiteral("/dir/sub/dir")));
}

// ---------------- 跨源中转 ----------------

void TestMoveCopy::movesAcrossSourcesStreaming()
{
    auto &ops = FileOperations::instance();
    const QByteArray payload = patterned(3 * kOneKiB * kOneKiB + 11, 'C'); // 跨多个 1MB 分块
    writeAt(m_src.path(), QStringLiteral("/media/big.bin"), payload);
    bakeDirectory(m_src.path(), QStringLiteral("/media/dir"));
    QVERIFY(QDir().mkpath(m_dst.path() + QStringLiteral("/out")));

    QSignalSpy failed(&ops, &FileOperations::failed);
    QSignalSpy transferred(&ops, &FileOperations::transferred);

    ops.moveOrCopy(request(false, {QStringLiteral("/media/big.bin")}, QStringLiteral("/out"),
                           QStringLiteral("c-dst"), m_other.get()));
    waitIdle();
    QCOMPARE(failed.count(), 0);
    QCOMPARE(readAt(m_dst.path(), QStringLiteral("/out/big.bin")), payload);
    QVERIFY(!exists(m_src.path(), QStringLiteral("/media/big.bin")));
    // 不留半成品
    QVERIFY(!exists(m_dst.path(), QStringLiteral("/out/big.bin.myhub-part")));

    // 目录：递归 + 文件中转
    ops.moveOrCopy(request(false, {QStringLiteral("/media/dir")}, QStringLiteral("/out"),
                           QStringLiteral("c-dst"), m_other.get()));
    waitIdle();
    QCOMPARE(failed.count(), 0);
    QCOMPARE(readAt(m_dst.path(), QStringLiteral("/out/dir/a.txt")), QByteArrayLiteral("aaaa"));
    QCOMPARE(readAt(m_dst.path(), QStringLiteral("/out/dir/sub/b.txt")),
             QByteArrayLiteral("bbbbbb"));
    QVERIFY(!exists(m_src.path(), QStringLiteral("/media/dir")));
    QCOMPARE(transferred.count(), 2);

    // 跨源时记录不改写（连接源不同，留给后续切片）
    QCOMPARE(transferred.at(1).at(2).toString(), QStringLiteral("c-dst"));
}

void TestMoveCopy::movesReadingProgressAlong()
{
    auto &ops = FileOperations::instance();
    writeAt(m_src.path(), QStringLiteral("/剧集/ep1.mkv"), QByteArrayLiteral("ep1"));
    QVERIFY(QDir().mkpath(m_src.path() + QStringLiteral("/归档")));
    insertProgress(QStringLiteral("p-1"), QStringLiteral("/剧集/ep1.mkv"));

    QSignalSpy failed(&ops, &FileOperations::failed);
    ops.moveOrCopy(request(false, {QStringLiteral("/剧集/ep1.mkv")}, QStringLiteral("/归档")));
    waitIdle();
    QCOMPARE(failed.count(), 0);

    const auto rows = AppDatabase::instance().query(
        QStringLiteral("SELECT filePath FROM readingProgress WHERE id = ?"),
        {QStringLiteral("p-1")});
    QCOMPARE(rows.size(), 1);
    QCOMPARE(rows.first().value(QStringLiteral("filePath")).toString(),
             QStringLiteral("/归档/ep1.mkv"));
}

void TestMoveCopy::cancelBeforeStartLeavesNoTrace()
{
    auto &ops = FileOperations::instance();
    const QByteArray payload = patterned(128 * kOneKiB, 'X');
    writeAt(m_src.path(), QStringLiteral("/big.bin"), payload);
    QVERIFY(QDir().mkpath(m_dst.path() + QStringLiteral("/out")));

    ops.moveOrCopy(request(false, {QStringLiteral("/big.bin")}, QStringLiteral("/out"),
                           QStringLiteral("c-dst"), m_other.get()));
    // 立刻取消：还没开始任何 IO
    ops.cancelTransfer();
    waitIdle();

    QVERIFY(!exists(m_dst.path(), QStringLiteral("/out/big.bin")));
    QVERIFY(!exists(m_dst.path(), QStringLiteral("/out/big.bin.myhub-part")));
    QVERIFY(exists(m_src.path(), QStringLiteral("/big.bin")));
}

QTEST_GUILESS_MAIN(TestMoveCopy)
#include "tst_movecopy.moc"
