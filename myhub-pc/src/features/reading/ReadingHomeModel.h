#pragma once

#include "core/history/ReadingEntry.h"

#include <QAbstractListModel>
#include <QQmlEngine>
#include <QVector>

class QTimer;

namespace myhub {

class ConnectionStore;

/**
 * 「正在阅读」首页列表模型（PC-209 / PC-705）。
 *
 * 数据源是 `readingProgress` 表（`ProgressRepository::recent`），不做镜像缓存：
 * 进度每秒都在变，镜像只会带来过期。
 *
 * 刷新纪律：
 *   - 首次构造时同步读库（数据库在 bootstrap 阶段就已就绪）
 *   - 每次进度落盘（`progressChanged`）**只更新对应那行**，不重整列表，
 *     否则 mini 播放条里播着视频、用户正在首页找东西时列表每 5s 跳一次
 *   - 新记录出现 / 记录被删 / 连接源变化才整体重建
 *   - 重新进入模块（`AppRouter.reselected`）时整体重排一次，恢复「最近优先」
 */
class ReadingHomeModel : public QAbstractListModel
{
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(int count READ rowCount NOTIFY countChanged)
    Q_PROPERTY(State state READ state NOTIFY stateChanged)

public:
    enum State
    {
        Ready, ///< 有记录
        Empty, ///< 一条记录都没有 → 首页空态
    };
    Q_ENUM(State)

    enum Roles
    {
        ConnectionIdRole = Qt::UserRole + 1,
        ConnectionNameRole,
        ConnectionLocalRole,
        ConnectionAvailableRole,
        PathRole,
        TitleRole,
        MediaKindRole,
        KindTextRole,
        PercentRole,
        PercentTextRole,
        FinishedRole,
        FinishedTextRole,
        RelativeTimeRole,
        UpdatedAtRole,
        ResumeMsRole,
    };
    Q_ENUM(Roles)

    explicit ReadingHomeModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    State state() const { return m_rows.isEmpty() ? Empty : Ready; }

    /// 整体重读（手动刷新 / 进入模块 / 记录增删）
    Q_INVOKABLE void refresh();

    /// 行数据（右键菜单 / 属性面板）
    Q_INVOKABLE QVariantMap get(int row) const;

    /// 删除一条记录（不影响源文件）
    Q_INVOKABLE bool removeAt(int row);

    /// 批量删除；入参是行号列表，返回实际删除条数
    Q_INVOKABLE int removeRows(const QVariantList &rows);

signals:
    void countChanged();
    void stateChanged();

private:
    struct Row
    {
        ReadingEntry entry;
        QString connectionName;
        bool connectionLocal = false;
        bool connectionAvailable = false;
    };

    void reload();
    void onProgressChanged(const QString &connectionId, const QString &path);
    void onProgressRemoved(const QString &connectionId, const QString &path);
    int indexOf(const QString &connectionId, const QString &path) const;

    QVector<Row> m_rows;
};

} // namespace myhub
