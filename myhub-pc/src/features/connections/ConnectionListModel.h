#pragma once

#include <QAbstractListModel>
#include <QQmlEngine>

namespace myhub {

/**
 * 连接源列表模型（供浏览首页卡片与设置页列表共用）。
 *
 * 两处 UI 由**同一数据源**驱动，保证状态实时一致（§14.9）。
 */
class ConnectionListModel : public QAbstractListModel
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(int count READ rowCount NOTIFY countChanged)
    /// 只列出已启用的连接（浏览页用 true，设置页用 false）
    Q_PROPERTY(bool enabledOnly READ enabledOnly WRITE setEnabledOnly NOTIFY enabledOnlyChanged)

public:
    enum Roles
    {
        IdRole = Qt::UserRole + 1,
        NameRole,
        TypeRole,        ///< local / webdav / smb
        TypeDisplayRole, ///< 本地路径 / WebDAV / SMB
        MountPointRole,
        EnabledRole,
        ReachableRole, ///< QVariant(): 未知；true/false: 绿点/红点
        TestingRole,
        StatusTextRole, ///< 「内网可达」/「外网可达」/ 失败原因
        SummaryRole,    ///< 地址摘要，表单回显与卡片副标题
    };
    Q_ENUM(Roles)

    explicit ConnectionListModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    bool enabledOnly() const { return m_enabledOnly; }
    void setEnabledOnly(bool v);

    /// 行索引 → 连接 id
    Q_INVOKABLE QString idAt(int row) const;
    Q_INVOKABLE int rowOf(const QString &id) const;

    /// 整行数据（设置页表单回显）
    Q_INVOKABLE QVariantMap get(int row) const;

signals:
    void countChanged();
    void enabledOnlyChanged();

private:
    void rebuild();
    void refreshRow(const QString &id);

    bool m_enabledOnly = false;
    QList<QString> m_ids;
};

} // namespace myhub
