// 传输队列 QML 视图模型单测（PC-103）：
//   - 角色名契约（transferId 而非 id：QML 委托里 id 是保留标识符）
//   - 任务增删改的镜像（横幅依赖 count / activeCount / currentTask）
//   - lastFinished 语义（全部结束后横幅展示最后一条结果）
//
// 走真实代码路径（LocalAdapter + TransferManager），用临时目录隔离。

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QTemporaryDir>
#include <QtTest>
#include <memory>

#include "TransferListModel.h"
#include "core/storage/LocalAdapter.h"
#include "core/transfer/TransferManager.h"

using namespace myhub;

namespace {

/// 1 KiB：写成 qsizetype 常量，避免 int 乘法在调用点被隐式拓宽（clang-tidy）
constexpr qsizetype kOneKiB = 1024;

/// 按角色名取角色号：直接写 UserRole+n 会在角色顺序调整时静默错位
int roleOf(const QAbstractItemModel &model, const QByteArray &name)
{
    const QHash<int, QByteArray> names = model.roleNames();
    for (auto it = names.cbegin(); it != names.cend(); ++it) {
        if (it.value() == name) {
            return it.key();
        }
    }
    return -1;
}

} // namespace

class TestTransferModel : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void init();
    void exposesTransferIdRole();
    void mirrorsQueuedTasks();
    void reportsLastFinishedWhenIdle();
    void clearsRowsWhenFinishedCleared();

private:
    QString absolute(const QString &rel) const { return m_root.path() + rel; }
    void writeLocal(const QString &rel, const QByteArray &data);

    QTemporaryDir m_root;
    std::unique_ptr<LocalAdapter> m_adapter;
    TransferManager &m_transfers = TransferManager::instance();
};

void TestTransferModel::initTestCase()
{
    QVERIFY(m_root.isValid());
    m_adapter = std::make_unique<LocalAdapter>(m_root.path());
}

void TestTransferModel::init()
{
    m_transfers.cancelAll();
    m_transfers.clearFinished();
    QTRY_VERIFY_WITH_TIMEOUT(!m_transfers.busy(), 5000);

    QDir(m_root.path()).removeRecursively();
    QVERIFY(QDir().mkpath(absolute(QStringLiteral("/src"))));
}

void TestTransferModel::writeLocal(const QString &rel, const QByteArray &data)
{
    const QString path = absolute(rel);
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile file(path);
    QVERIFY2(file.open(QIODevice::WriteOnly | QIODevice::Truncate), qPrintable(path));
    QCOMPARE(file.write(data), data.size());
}

void TestTransferModel::exposesTransferIdRole()
{
    TransferListModel model;

    const QHash<int, QByteArray> names = model.roleNames();
    QVERIFY(names.values().contains(QByteArrayLiteral("transferId")));
    QVERIFY(names.values().contains(QByteArrayLiteral("progress")));
    QVERIFY(names.values().contains(QByteArrayLiteral("canRetry")));
    // `id` 在 QML 委托中是保留标识符，不能作为角色名
    QVERIFY(!names.values().contains(QByteArrayLiteral("id")));
}

void TestTransferModel::mirrorsQueuedTasks()
{
    TransferListModel model;
    writeLocal(QStringLiteral("/src/one.bin"), QByteArray(256 * kOneKiB, 'A'));
    writeLocal(QStringLiteral("/src/two.bin"), QByteArray(256 * kOneKiB, 'B'));

    // pump() 是异步调度的：入队后、事件循环转起来之前都还是 Pending
    const int added = m_transfers.enqueueUploads(
        m_adapter.get(), QStringLiteral("c-test"), QStringLiteral("测试源"),
        QStringLiteral("/dest"),
        {absolute(QStringLiteral("/src/one.bin")), absolute(QStringLiteral("/src/two.bin"))});
    QCOMPARE(added, 2);

    QCOMPARE(model.rowCount(), 2);
    QCOMPARE(model.activeCount(), 2);

    const QVariantMap current = model.currentTask();
    QCOMPARE(current.value(QStringLiteral("status")).toInt(), int(TransferTask::Pending));
    QCOMPARE(current.value(QStringLiteral("connectionName")).toString(), QStringLiteral("测试源"));

    QTRY_VERIFY_WITH_TIMEOUT(!m_transfers.busy(), 15000);
    QCOMPARE(model.activeCount(), 0);
    QCOMPARE(model.rowCount(), 2);

    // 全部完成后每行都是 100%
    for (int row = 0; row < model.rowCount(); ++row) {
        const QModelIndex index = model.index(row);
        QCOMPARE(index.data(roleOf(model, "status")).toInt(), int(TransferTask::Completed));
        QCOMPARE(index.data(roleOf(model, "progress")).toDouble(), 1.0);
        QVERIFY(!index.data(roleOf(model, "fileName")).toString().isEmpty());
        QVERIFY(!index.data(roleOf(model, "localPath")).toString().isEmpty());
    }
}

void TestTransferModel::reportsLastFinishedWhenIdle()
{
    TransferListModel model;
    writeLocal(QStringLiteral("/src/done.bin"), QByteArray(64 * kOneKiB, 'C'));

    QVERIFY(m_transfers.enqueueUploads(m_adapter.get(), QStringLiteral("c-test"),
                                       QStringLiteral("测试源"), QStringLiteral("/dest"),
                                       {absolute(QStringLiteral("/src/done.bin"))})
            == 1);
    QTRY_VERIFY_WITH_TIMEOUT(!m_transfers.busy(), 15000);

    // 没有活动任务时横幅看 lastFinished
    QVERIFY(model.currentTask().isEmpty());
    const QVariantMap finished = model.lastFinished();
    QCOMPARE(finished.value(QStringLiteral("fileName")).toString(), QStringLiteral("done.bin"));
    QCOMPARE(finished.value(QStringLiteral("status")).toInt(), int(TransferTask::Completed));
    QVERIFY(!finished.value(QStringLiteral("canRetry")).toBool());
}

void TestTransferModel::clearsRowsWhenFinishedCleared()
{
    TransferListModel model;
    writeLocal(QStringLiteral("/src/gone.bin"), QByteArray(32 * kOneKiB, 'D'));

    QVERIFY(m_transfers.enqueueUploads(m_adapter.get(), QStringLiteral("c-test"),
                                       QStringLiteral("测试源"), QStringLiteral("/dest"),
                                       {absolute(QStringLiteral("/src/gone.bin"))})
            == 1);
    QTRY_VERIFY_WITH_TIMEOUT(!m_transfers.busy(), 15000);
    QCOMPARE(model.rowCount(), 1);

    model.clearFinished();
    QCOMPARE(model.rowCount(), 0);
}

QTEST_MAIN(TestTransferModel)
#include "tst_transfermodel.moc"
