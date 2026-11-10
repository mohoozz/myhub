#include "ConnectionListModel.h"
#include "ConnectionStore.h"

namespace myhub {

ConnectionListModel::ConnectionListModel(QObject *parent)
    : QAbstractListModel(parent)
{
    auto &store = ConnectionStore::instance();

    connect(&store, &ConnectionStore::connectionsChanged, this, &ConnectionListModel::rebuild);
    connect(&store, &ConnectionStore::testStateChanged, this, &ConnectionListModel::refreshRow);

    rebuild();
}

void ConnectionListModel::setEnabledOnly(bool v)
{
    if (m_enabledOnly == v)
        return;
    m_enabledOnly = v;
    emit enabledOnlyChanged();
    rebuild();
}

void ConnectionListModel::rebuild()
{
    beginResetModel();
    m_ids.clear();
    for (const ConnectionRecord &r : ConnectionStore::instance().connections()) {
        if (m_enabledOnly && !r.enabled)
            continue;
        m_ids.append(r.id);
    }
    endResetModel();
    emit countChanged();
}

void ConnectionListModel::refreshRow(const QString &id)
{
    const int row = m_ids.indexOf(id);
    if (row < 0)
        return;
    const QModelIndex idx = index(row, 0);
    emit dataChanged(idx, idx, {ReachableRole, TestingRole, StatusTextRole});
}

int ConnectionListModel::rowCount(const QModelIndex &parent) const
{
    if (parent.isValid())
        return 0;
    return m_ids.size();
}

QHash<int, QByteArray> ConnectionListModel::roleNames() const
{
    return {
        {IdRole, QByteArrayLiteral("connectionId")},
        {NameRole, QByteArrayLiteral("name")},
        {TypeRole, QByteArrayLiteral("type")},
        {TypeDisplayRole, QByteArrayLiteral("typeDisplay")},
        {MountPointRole, QByteArrayLiteral("mountPoint")},
        {EnabledRole, QByteArrayLiteral("enabled")},
        {ReachableRole, QByteArrayLiteral("reachable")},
        {TestingRole, QByteArrayLiteral("testing")},
        {StatusTextRole, QByteArrayLiteral("statusText")},
        {SummaryRole, QByteArrayLiteral("summary")},
    };
}

/// 地址摘要：卡片副标题与表单回显
static QString summaryOf(const ConnectionRecord &r)
{
    switch (r.type) {
    case ConnectionType::Local:
        return r.config.value(QStringLiteral("path")).toString();
    case ConnectionType::WebDAV: {
        const QString external = r.config.value(QStringLiteral("baseURL")).toString();
        const QString internal = r.config.value(QStringLiteral("internalBaseURL")).toString();
        if (!internal.isEmpty() && !external.isEmpty())
            return QStringLiteral("%1 / %2").arg(internal, external);
        return external.isEmpty() ? internal : external;
    }
    case ConnectionType::SMB:
        return QStringLiteral("\\\\%1\\%2")
            .arg(r.config.value(QStringLiteral("host")).toString(),
                 r.config.value(QStringLiteral("share")).toString());
    default:
        break;
    }
    return {};
}

QVariant ConnectionListModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_ids.size())
        return {};

    auto &store = ConnectionStore::instance();
    const QString id = m_ids.at(index.row());
    const ConnectionRecord r = store.byId(id);
    if (!r.isValid())
        return {};

    switch (role) {
    case IdRole:
        return r.id;
    case NameRole:
        return r.name;
    case TypeRole:
        return StorageAdapterFactory::typeToString(r.type);
    case TypeDisplayRole:
        return StorageAdapterFactory::typeDisplayName(r.type);
    case MountPointRole:
        return r.mountPoint;
    case EnabledRole:
        return r.enabled;
    case ReachableRole: {
        const QVariantMap st = store.testState(id);
        return st.value(QStringLiteral("reachable"));
    }
    case TestingRole:
        return store.isTesting(id);
    case StatusTextRole: {
        const QVariantMap st = store.testState(id);
        if (store.isTesting(id))
            return tr("测试中…");
        return st.value(QStringLiteral("message"));
    }
    case SummaryRole:
        return summaryOf(r);
    default:
        break;
    }
    return {};
}

QString ConnectionListModel::idAt(int row) const
{
    if (row < 0 || row >= m_ids.size())
        return {};
    return m_ids.at(row);
}

int ConnectionListModel::rowOf(const QString &id) const
{
    return m_ids.indexOf(id);
}

QVariantMap ConnectionListModel::get(int row) const
{
    QVariantMap out;
    if (row < 0 || row >= m_ids.size())
        return out;

    const ConnectionRecord r = ConnectionStore::instance().byId(m_ids.at(row));
    if (!r.isValid())
        return out;

    out.insert(QStringLiteral("connectionId"), r.id);
    out.insert(QStringLiteral("name"), r.name);
    out.insert(QStringLiteral("type"), StorageAdapterFactory::typeToString(r.type));
    out.insert(QStringLiteral("mountPoint"), r.mountPoint);
    out.insert(QStringLiteral("enabled"), r.enabled);
    // 展开配置字段供表单直接绑定
    for (auto it = r.config.constBegin(); it != r.config.constEnd(); ++it)
        out.insert(it.key(), it.value().toVariant());
    return out;
}

} // namespace myhub
