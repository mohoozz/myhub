#pragma once

#include "core/favorites/FavoriteRepository.h"

#include <QAbstractListModel>
#include <QQmlEngine>
#include <QVector>

namespace myhub {

class ConnectionStore;

/**
 * 收藏页列表模型（PC-107）。
 *
 * 数据源是 `favorite` 表（`FavoriteRepository::list`），**不做内容镜像**；
 * 只缓存「行 → 展示字段」的派生结果（名称、连接源名、大小文本…），
 * 并在以下事件上就地更新，保证与浏览页星标双向实时同步：
 *
 *   - 新增收藏（浏览页点星）→ 整体重排（收藏时间倒序，新行落在最前）
 *   - 取消收藏 → `beginRemoveRows` 只摘掉那一行
 *   - 连接源改名/删除 → 整体重排（名称与「可打开」状态要跟着变）
 *
 * 收藏本身没有「内容更新」（不像阅读进度每秒都变），所以不存在只刷单行的场景。
 */
class FavoriteListModel : public QAbstractListModel
{
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(int count READ rowCount NOTIFY countChanged)
    Q_PROPERTY(bool empty READ isEmpty NOTIFY countChanged)

public:
    enum Roles
    {
        ConnectionIdRole = Qt::UserRole + 1,
        ConnectionNameRole,
        ConnectionAvailableRole,
        ConnectionLocalRole,
        PathRole,
        NameRole,
        MediaKindRole,
        MediaKindTextRole,
        IsDirRole,
        SizeRole,
        SizeTextRole,
        CreatedAtRole,
        CreatedAtTextRole,
    };
    Q_ENUM(Roles)

    explicit FavoriteListModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    bool isEmpty() const { return m_rows.isEmpty(); }

    /// 整体重读（进入收藏页 / 连接源变化）
    Q_INVOKABLE void refresh();

    /// 行数据（右键菜单 / 属性面板）
    Q_INVOKABLE QVariantMap get(int row) const;

    /// 取消收藏一行；成功返回 true（行由 favoriteChanged 信号移除）
    Q_INVOKABLE bool removeAt(int row);

signals:
    void countChanged();

private:
    struct Row
    {
        FavoriteRecord record;
        QString name;
        QString connectionName;
        bool connectionAvailable = false;
        bool connectionLocal = false;
        QString sizeText;
        QString createdAtText;
    };

    void reload();
    void onFavoriteChanged(const QString &connectionId, const QString &filePath, bool favorite);
    int indexOf(const QString &connectionId, const QString &filePath) const;

    QVector<Row> m_rows;
};

} // namespace myhub
