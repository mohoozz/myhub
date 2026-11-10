// 上传/下载单测（PC-103）：
//   - 上传：内容一致、字节级进度落点、同名顺延不覆盖、不支持时给出中文原因
//   - 队列：顺序执行、排队中取消不留残片
//   - 下载：默认目录布局、同名顺延、.part 断点续传、失败可重试
//
// 全部走真实代码路径（LocalAdapter + TransferManager），用临时目录隔离。

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QtTest>
#include <memory>

#include "core/storage/LocalAdapter.h"
#include "core/transfer/TransferManager.h"

using namespace myhub;

namespace {

/// 1 MiB：写成 qsizetype 常量，避免 int 乘法在调用点被隐式拓宽（clang-tidy）
constexpr qsizetype kOneMiB = qsizetype(1024) * 1024;

QByteArray patternedBytes(qsizetype size, char seed)
{
    QByteArray data(size, Qt::Uninitialized);
    for (qsizetype i = 0; i < size; ++i)
        data[i] = char((seed + i) % 251);
    return data;
}

/// 只读连接源：模拟 SMB 这类不支持写入的适配器
class ReadOnlyAdapter : public LocalAdapter
{
public:
    using LocalAdapter::LocalAdapter;

    void uploadFile(const QString &, const QString &, UploadProgress, CancelProbe,
                    ErrorCallback cb) override
    {
        if (cb) {
            cb(StorageError(StorageError::UnsupportedProtocol, QStringLiteral("read-only")));
        }
    }
};

} // namespace

class TestTransfer : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void init();
    void uploadsFileToTarget();
    void uploadAppendsIndexWhenNameExists();
    void uploadReportsUnsupportedAdapter();
    void cancelsQueuedTasks();
    void downloadsIntoConnectionFolder();
    void downloadAppendsIndexWhenNameExists();
    void downloadResumesFromPartFile();
    void failedDownloadCanBeRetried();

private:
    QString absolute(const QString &rel) const { return m_root.path() + rel; }
    void writeLocal(const QString &rel, const QByteArray &data);
    QByteArray readLocal(const QString &rel) const;
    void waitIdle();

    QTemporaryDir m_root;
    std::unique_ptr<LocalAdapter> m_adapter;
    TransferManager &m_transfers = TransferManager::instance();
};

void TestTransfer::initTestCase()
{
    QVERIFY(m_root.isValid());
    m_adapter = std::make_unique<LocalAdapter>(m_root.path());
}

void TestTransfer::init()
{
    m_transfers.cancelAll();
    m_transfers.clearFinished();
    QTRY_VERIFY_WITH_TIMEOUT(!m_transfers.busy(), 5000);

    QDir(m_root.path()).removeRecursively();
    QVERIFY(QDir().mkpath(absolute("/src")));
}

void TestTransfer::writeLocal(const QString &rel, const QByteArray &data)
{
    const QString path = absolute(rel);
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile file(path);
    QVERIFY2(file.open(QIODevice::WriteOnly | QIODevice::Truncate), qPrintable(path));
    QCOMPARE(file.write(data), data.size());
    file.close();
}

QByteArray TestTransfer::readLocal(const QString &rel) const
{
    QFile file(absolute(rel));
    if (!file.open(QIODevice::ReadOnly))
        return {};
    return file.readAll();
}

void TestTransfer::waitIdle()
{
    QTRY_VERIFY_WITH_TIMEOUT(!m_transfers.busy(), 15000);
}

void TestTransfer::uploadsFileToTarget()
{
    const QByteArray payload = patternedBytes(2 * 1024 * 1024 + 137, 7);
    writeLocal(QStringLiteral("/src/big.bin"), payload);

    QSignalSpy uploaded(&m_transfers, &TransferManager::uploaded);
    QSignalSpy changed(&m_transfers, &TransferManager::taskChanged);

    const int added = m_transfers.enqueueUploads(m_adapter.get(), QStringLiteral("c-test"),
                                                 QStringLiteral("测试源"), QStringLiteral("/dest"),
                                                 {absolute(QStringLiteral("/src/big.bin"))});
    QCOMPARE(added, 1);
    QTRY_COMPARE_WITH_TIMEOUT(uploaded.count(), 1, 15000);

    // 内容逐字节一致（分块拼接没有错位/丢块）
    QCOMPARE(readLocal(QStringLiteral("/dest/big.bin")), payload);
    QVERIFY(changed.count() >= 1); // 至少报告过一次进度

    const QList<TransferTask> tasks = m_transfers.tasks();
    QCOMPARE(tasks.size(), 1);
    QCOMPARE(tasks.first().status, TransferTask::Completed);
    QCOMPARE(tasks.first().transferred, qint64(payload.size()));
    QCOMPARE(tasks.first().totalBytes, qint64(payload.size()));
    QCOMPARE(uploaded.first().at(1).toString(), QStringLiteral("/dest"));
    QCOMPARE(uploaded.first().at(2).toString(), QStringLiteral("/dest/big.bin"));
}

void TestTransfer::uploadAppendsIndexWhenNameExists()
{
    writeLocal(QStringLiteral("/src/a.txt"), QByteArrayLiteral("new-content"));
    writeLocal(QStringLiteral("/dest/a.txt"), QByteArrayLiteral("old-content"));

    QSignalSpy uploaded(&m_transfers, &TransferManager::uploaded);
    m_transfers.enqueueUploads(m_adapter.get(), QStringLiteral("c-test"), QStringLiteral("测试源"),
                               QStringLiteral("/dest"), {absolute(QStringLiteral("/src/a.txt"))});
    QTRY_COMPARE_WITH_TIMEOUT(uploaded.count(), 1, 15000);

    // 原文件不被覆盖，新的落到 a (1).txt
    QCOMPARE(readLocal(QStringLiteral("/dest/a.txt")), QByteArrayLiteral("old-content"));
    QCOMPARE(readLocal(QStringLiteral("/dest/a (1).txt")), QByteArrayLiteral("new-content"));
    QCOMPARE(uploaded.first().at(2).toString(), QStringLiteral("/dest/a (1).txt"));
}

void TestTransfer::uploadReportsUnsupportedAdapter()
{
    ReadOnlyAdapter readOnly(m_root.path());
    writeLocal(QStringLiteral("/src/x.txt"), QByteArrayLiteral("x"));

    QSignalSpy changed(&m_transfers, &TransferManager::taskChanged);
    m_transfers.enqueueUploads(&readOnly, QStringLiteral("c-ro"), QStringLiteral("只读源"),
                               QStringLiteral("/dest"), {absolute(QStringLiteral("/src/x.txt"))});
    waitIdle();

    const QList<TransferTask> tasks = m_transfers.tasks();
    QCOMPARE(tasks.size(), 1);
    QCOMPARE(tasks.first().status, TransferTask::Failed);
    QVERIFY(tasks.first().canRetry);
    QVERIFY2(tasks.first().error.contains(QStringLiteral("不支持")),
             qPrintable(tasks.first().error));
}

void TestTransfer::cancelsQueuedTasks()
{
    const QByteArray payload = patternedBytes(kOneMiB, 3);
    for (int i = 0; i < 3; ++i) {
        writeLocal(QStringLiteral("/src/q%1.bin").arg(i), payload);
    }

    m_transfers.enqueueUploads(m_adapter.get(), QStringLiteral("c-test"), QStringLiteral("测试源"),
                               QStringLiteral("/dest"),
                               {absolute(QStringLiteral("/src/q0.bin")),
                                absolute(QStringLiteral("/src/q1.bin")),
                                absolute(QStringLiteral("/src/q2.bin"))});
    const QList<TransferTask> queued = m_transfers.tasks();
    QCOMPARE(queued.size(), 3);
    m_transfers.cancel(queued.at(1).id);
    m_transfers.cancel(queued.at(2).id);

    waitIdle();

    // 排队的两个直接移除，只剩跑完的那个
    const QList<TransferTask> left = m_transfers.tasks();
    QCOMPARE(left.size(), 1);
    QCOMPARE(left.first().status, TransferTask::Completed);
    QVERIFY(QFile::exists(absolute(QStringLiteral("/dest/q0.bin"))));
    QVERIFY(!QFile::exists(absolute(QStringLiteral("/dest/q1.bin"))));
    QVERIFY(!QFile::exists(absolute(QStringLiteral("/dest/q2.bin"))));
}

void TestTransfer::downloadsIntoConnectionFolder()
{
    const QByteArray payload = patternedBytes(1024 * 1024 + 77, 11);
    writeLocal(QStringLiteral("/src/movie.bin"), payload);

    QSignalSpy downloaded(&m_transfers, &TransferManager::downloaded);
    const int added = m_transfers.enqueueDownloads(
        m_adapter.get(), QStringLiteral("c-test"), QStringLiteral("测试源"),
        {QStringLiteral("/src/movie.bin")}, absolute(QStringLiteral("/downloads")));
    QCOMPARE(added, 1);
    QTRY_COMPARE_WITH_TIMEOUT(downloaded.count(), 1, 15000);

    // <根>/<连接名>/<远端路径>
    const QString target = absolute(QStringLiteral("/downloads/测试源/src/movie.bin"));
    QVERIFY(QFile::exists(target));
    QFile file(target);
    QVERIFY(file.open(QIODevice::ReadOnly));
    QCOMPARE(file.readAll(), payload);
    QCOMPARE(downloaded.first().at(2).toString(), QDir::cleanPath(target));
    // .part 中间文件已清理
    QVERIFY(!QFile::exists(target + QStringLiteral(".myhub-part")));
}

void TestTransfer::downloadAppendsIndexWhenNameExists()
{
    writeLocal(QStringLiteral("/src/movie.bin"), QByteArrayLiteral("remote-new"));
    writeLocal(QStringLiteral("/downloads/测试源/src/movie.bin"), QByteArrayLiteral("local-old"));

    QSignalSpy downloaded(&m_transfers, &TransferManager::downloaded);
    m_transfers.enqueueDownloads(m_adapter.get(), QStringLiteral("c-test"),
                                 QStringLiteral("测试源"), {QStringLiteral("/src/movie.bin")},
                                 absolute(QStringLiteral("/downloads")));
    QTRY_COMPARE_WITH_TIMEOUT(downloaded.count(), 1, 15000);

    QCOMPARE(readLocal(QStringLiteral("/downloads/测试源/src/movie.bin")),
             QByteArrayLiteral("local-old"));
    QCOMPARE(readLocal(QStringLiteral("/downloads/测试源/src/movie (1).bin")),
             QByteArrayLiteral("remote-new"));
}

void TestTransfer::downloadResumesFromPartFile()
{
    const QByteArray payload = QByteArray(kOneMiB, 'A') + QByteArray(kOneMiB, 'B');
    writeLocal(QStringLiteral("/src/resume.bin"), payload);

    const QString target = absolute(QStringLiteral("/out/resume.bin"));
    QDir().mkpath(QFileInfo(target).absolutePath());
    // 预置半截 .part：内容故意与源不同，用来证明「从断点继续」而非从头覆盖
    {
        QFile part(target + QStringLiteral(".myhub-part"));
        QVERIFY(part.open(QIODevice::WriteOnly));
        QCOMPARE(part.write(QByteArray(kOneMiB, 'X')), kOneMiB);
    }

    QSignalSpy downloaded(&m_transfers, &TransferManager::downloaded);
    m_transfers.enqueueDownloadAs(m_adapter.get(), QStringLiteral("c-test"),
                                  QStringLiteral("测试源"), QStringLiteral("/src/resume.bin"),
                                  target);
    QTRY_COMPARE_WITH_TIMEOUT(downloaded.count(), 1, 15000);

    QFile file(target);
    QVERIFY(file.open(QIODevice::ReadOnly));
    const QByteArray result = file.readAll();
    QCOMPARE(result.size(), payload.size());
    QCOMPARE(result.left(kOneMiB), QByteArray(kOneMiB, 'X')); // 前半段保留断点内容
    QCOMPARE(result.mid(kOneMiB), QByteArray(kOneMiB, 'B'));  // 后半段新拉取
}

void TestTransfer::failedDownloadCanBeRetried()
{
    QSignalSpy changed(&m_transfers, &TransferManager::taskChanged);
    m_transfers.enqueueDownloads(m_adapter.get(), QStringLiteral("c-test"),
                                 QStringLiteral("测试源"), {QStringLiteral("/src/not-there.bin")},
                                 absolute(QStringLiteral("/downloads")));
    waitIdle();

    QList<TransferTask> tasks = m_transfers.tasks();
    QCOMPARE(tasks.size(), 1);
    QCOMPARE(tasks.first().status, TransferTask::Failed);
    QVERIFY(tasks.first().canRetry);
    QVERIFY(!tasks.first().error.isEmpty());

    // 重试仍失败，但不应该卡在「传输中」
    m_transfers.retry(tasks.first().id);
    waitIdle();
    tasks = m_transfers.tasks();
    QCOMPARE(tasks.size(), 1);
    QCOMPARE(tasks.first().status, TransferTask::Failed);
}

QTEST_GUILESS_MAIN(TestTransfer)

#include "tst_transfer.moc"
