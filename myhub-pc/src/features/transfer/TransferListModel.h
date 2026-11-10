#pragma once

#include <QAbstractListModel>
#include <QQmlEngine>
#include <QVariantMap>
#include <QVector>

namespace myhub {

struct TransferTask;

/**
 * 传输队列的 QML 视图模型（单例名 `Transfers`）。
 *
 * 只是 `TransferManager` 的只读镜像 + 角色翻译：所有状态流转都在 core，
 * 这样队列逻辑能被 QTest 覆盖，而 QML 只负责把角色画出来。
 */
class TransferListModel : public QAbstractListModel
{
    Q_OBJECT
    QML_NAMED_ELEMENT(Transfers)
    QML_SINGLETON

    Q_PROPERTY(int count READ rowCount NOTIFY countChanged)
    /// 排队中 + 传输中的数量（>0 时横幅常驻）
    Q_PROPERTY(int activeCount READ activeCount NOTIFY countChanged)
    /// 当前正在跑（或队首待跑）的任务快照（无则空 map）
    Q_PROPERTY(QVariantMap currentTask READ currentTask NOTIFY currentTaskChanged)
    /// 最近一条已完成 / 失败的任务快照（队列清空后横幅展示它）
    Q_PROPERTY(QVariantMap lastFinished READ lastFinished NOTIFY lastFinishedChanged)

public:
    explicit TransferListModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    int activeCount() const;
    QVariantMap currentTask() const;
    QVariantMap lastFinished() const;

    Q_INVOKABLE void cancel(const QString &id);
    Q_INVOKABLE void cancelAll();
    Q_INVOKABLE void retry(const QString &id);
    Q_INVOKABLE void clearFinished();

signals:
    void countChanged();
    void currentTaskChanged();
    void lastFinishedChanged();

private:
    enum Role
    {
        IdRole = Qt::UserRole + 1,
        KindRole,
        FileNameRole,
        ConnectionNameRole,
        TargetTextRole,
        ProgressRole,
        PercentTextRole,
        BytesTextRole,
        StatusRole,
        StatusTextRole,
        ErrorRole,
        CanRetryRole,
        LocalPathRole,
    };

    void onTaskAdded(int row);
    void onTaskChanged(int row);
    void onTaskRemoved(int row);
    void refreshDerived();

    QVariantMap buildRow(const TransferTask &task) const;
    QString statusTextFor(const TransferTask &task) const;

    /// 角色快照：避免每次 data() 都去 core 拷整张任务表（delegate 会反复取值）
    QVector<QVariantMap> m_rows;
    QVariantMap m_lastFinished;
};

} // namespace myhub
