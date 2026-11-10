#include "TransferListModel.h"

#include "core/transfer/TransferManager.h"
#include "core/utils/Formatters.h"

namespace myhub {

namespace {

/// role → 快照字段名（data() 直接查 map，避免每次拷任务表）
const QHash<int, QByteArray> &roleKeys()
{
    static const QHash<int, QByteArray> keys = {
        // 角色名不用 "id"：QML 委托里 `id` 是保留标识符，绑定会失效
        {Qt::UserRole + 1, QByteArrayLiteral("transferId")},
        {Qt::UserRole + 2, QByteArrayLiteral("kind")},
        {Qt::UserRole + 3, QByteArrayLiteral("fileName")},
        {Qt::UserRole + 4, QByteArrayLiteral("connectionName")},
        {Qt::UserRole + 5, QByteArrayLiteral("targetText")},
        {Qt::UserRole + 6, QByteArrayLiteral("progress")},
        {Qt::UserRole + 7, QByteArrayLiteral("percentText")},
        {Qt::UserRole + 8, QByteArrayLiteral("bytesText")},
        {Qt::UserRole + 9, QByteArrayLiteral("status")},
        {Qt::UserRole + 10, QByteArrayLiteral("statusText")},
        {Qt::UserRole + 11, QByteArrayLiteral("error")},
        {Qt::UserRole + 12, QByteArrayLiteral("canRetry")},
        {Qt::UserRole + 13, QByteArrayLiteral("localPath")},
    };
    return keys;
}

} // namespace

TransferListModel::TransferListModel(QObject *parent)
    : QAbstractListModel(parent)
{
    auto &manager = TransferManager::instance();
    connect(&manager, &TransferManager::taskAdded, this, &TransferListModel::onTaskAdded);
    connect(&manager, &TransferManager::taskChanged, this, &TransferListModel::onTaskChanged);
    connect(&manager, &TransferManager::taskRemoved, this, &TransferListModel::onTaskRemoved);
}

int TransferListModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : m_rows.size();
}

QVariant TransferListModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_rows.size())
        return QVariant();
    const QByteArray key = roleKeys().value(role);
    if (key.isEmpty())
        return QVariant();
    return m_rows.at(index.row()).value(QString::fromLatin1(key));
}

QHash<int, QByteArray> TransferListModel::roleNames() const
{
    return roleKeys();
}

int TransferListModel::activeCount() const
{
    return TransferManager::instance().activeCount();
}

QVariantMap TransferListModel::currentTask() const
{
    const QList<TransferTask> tasks = TransferManager::instance().tasks();
    for (const TransferTask &task : tasks) {
        if (task.status == TransferTask::Running)
            return buildRow(task);
    }
    for (const TransferTask &task : tasks) {
        if (task.status == TransferTask::Pending)
            return buildRow(task);
    }
    return {};
}

QVariantMap TransferListModel::lastFinished() const
{
    return m_lastFinished;
}

void TransferListModel::cancel(const QString &id)
{
    TransferManager::instance().cancel(id);
}

void TransferListModel::cancelAll()
{
    TransferManager::instance().cancelAll();
}

void TransferListModel::retry(const QString &id)
{
    TransferManager::instance().retry(id);
}

void TransferListModel::clearFinished()
{
    TransferManager::instance().clearFinished();
}

QString TransferListModel::statusTextFor(const TransferTask &task) const
{
    switch (task.status) {
    case TransferTask::Pending:
        return tr("等待传输");
    case TransferTask::Running:
        return task.kind == TransferTask::Upload ? tr("正在上传") : tr("正在下载");
    case TransferTask::Completed:
        return task.kind == TransferTask::Upload ? tr("上传完成") : tr("下载完成");
    case TransferTask::Failed:
        return tr("传输失败");
    case TransferTask::Cancelled:
        return tr("已取消");
    }
    return QString();
}

QVariantMap TransferListModel::buildRow(const TransferTask &task) const
{
    const double ratio =
        task.totalBytes > 0 ? double(task.transferred) / double(task.totalBytes) : 0.0;

    QVariantMap row;
    row.insert(QStringLiteral("transferId"), task.id);
    row.insert(QStringLiteral("kind"), int(task.kind));
    row.insert(QStringLiteral("fileName"), task.displayName);
    row.insert(QStringLiteral("connectionName"), task.connectionName);
    row.insert(QStringLiteral("targetText"), task.parentPath);
    row.insert(QStringLiteral("progress"), qBound(0.0, ratio, 1.0));
    row.insert(QStringLiteral("percentText"), Formatters::percent(ratio));
    row.insert(QStringLiteral("bytesText"),
               task.totalBytes > 0
                   ? QStringLiteral("%1 / %2").arg(Formatters::fileSize(task.transferred),
                                                   Formatters::fileSize(task.totalBytes))
                   : Formatters::fileSize(task.transferred));
    row.insert(QStringLiteral("status"), int(task.status));
    row.insert(QStringLiteral("statusText"), statusTextFor(task));
    row.insert(QStringLiteral("error"), task.error);
    row.insert(QStringLiteral("canRetry"), task.canRetry);
    row.insert(QStringLiteral("localPath"), task.localPath);
    return row;
}

void TransferListModel::onTaskAdded(int row)
{
    const QList<TransferTask> tasks = TransferManager::instance().tasks();
    if (row < 0 || row >= tasks.size())
        return;
    beginInsertRows(QModelIndex(), row, row);
    m_rows.insert(row, buildRow(tasks.at(row)));
    endInsertRows();
    refreshDerived();
}

void TransferListModel::onTaskChanged(int row)
{
    const QList<TransferTask> tasks = TransferManager::instance().tasks();
    if (row < 0 || row >= tasks.size() || row >= m_rows.size())
        return;
    const TransferTask &task = tasks.at(row);
    m_rows[row] = buildRow(task);
    const QModelIndex idx = index(row);
    emit dataChanged(idx, idx);
    if (task.status == TransferTask::Completed || task.status == TransferTask::Failed
        || task.status == TransferTask::Cancelled) {
        m_lastFinished = m_rows.at(row);
        emit lastFinishedChanged();
    }
    refreshDerived();
}

void TransferListModel::onTaskRemoved(int row)
{
    if (row < 0 || row >= m_rows.size())
        return;
    beginRemoveRows(QModelIndex(), row, row);
    m_rows.removeAt(row);
    endRemoveRows();
    refreshDerived();
}

void TransferListModel::refreshDerived()
{
    emit countChanged();
    emit currentTaskChanged();
}

} // namespace myhub
