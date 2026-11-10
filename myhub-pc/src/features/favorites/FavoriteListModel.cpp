#include "FavoriteListModel.h"

#include "core/storage/StoragePath.h"
#include "core/utils/Formatters.h"
#include "core/utils/MediaType.h"

#include <QDateTime>
#include <QVariantMap>

#include "features/connections/ConnectionStore.h"

namespace myhub {

FavoriteListModel::FavoriteListModel(QObject *parent)
    : QAbstractListModel(parent)
{
    connect(&FavoriteRepository::instance(), &FavoriteRepository::favoriteChanged, this,
            &FavoriteListModel::onFavoriteChanged);

    // 连接源改名 / 删除后，收藏行的名称与「可打开」状态要跟着变
    connect(&ConnectionStore::instance(), &ConnectionStore::connectionsChanged, this,
            &FavoriteListModel::reload);

    reload();
}

int FavoriteListModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : int(m_rows.size());
}

QVariant FavoriteListModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_rows.size()) {
        return {};
    }

    const Row &row = m_rows.at(index.row());
    switch (role) {
    case ConnectionIdRole:
        return row.record.connectionId;
    case ConnectionNameRole:
        return row.connectionName;
    case ConnectionAvailableRole:
        return row.connectionAvailable;
    case ConnectionLocalRole:
        return row.connectionLocal;
    case PathRole:
        return row.record.filePath;
    case NameRole:
        return row.name;
    case MediaKindRole:
        return row.record.mediaType;
    case MediaKindTextRole:
        return MediaType::displayNameForBadge(row.record.mediaType);
    case IsDirRole:
        return row.record.isDir();
    case SizeRole:
        return row.record.size;
    case SizeTextRole:
        return row.sizeText;
    case CreatedAtRole:
        return row.record.createdAt;
    case CreatedAtTextRole:
        return row.createdAtText;
    default:
        return {};
    }
}

QHash<int, QByteArray> FavoriteListModel::roleNames() const
{
    return {
        {ConnectionIdRole, "connectionId"},
        {ConnectionNameRole, "connectionName"},
        {ConnectionAvailableRole, "connectionAvailable"},
        {ConnectionLocalRole, "connectionLocal"},
        {PathRole, "filePath"},
        {NameRole, "name"},
        {MediaKindRole, "mediaKind"},
        {MediaKindTextRole, "mediaKindText"},
        {IsDirRole, "isDir"},
        {SizeRole, "size"},
        {SizeTextRole, "sizeText"},
        {CreatedAtRole, "createdAt"},
        {CreatedAtTextRole, "createdAtText"},
    };
}

void FavoriteListModel::refresh()
{
    reload();
}

void FavoriteListModel::reload()
{
    const auto &store = ConnectionStore::instance();
    const QList<FavoriteRecord> records = FavoriteRepository::instance().list();

    QVector<Row> rows;
    rows.reserve(records.size());
    for (const FavoriteRecord &record : records) {
        Row row;
        row.record = record;
        row.name = StoragePath::baseName(record.filePath);
        if (row.name.isEmpty()) {
            row.name = record.filePath;
        }
        const ConnectionRecord connection = store.byId(record.connectionId);
        row.connectionAvailable = connection.isValid();
        row.connectionLocal = connection.type == ConnectionType::Local;
        row.connectionName = connection.isValid() ? connection.name : QString();
        row.sizeText =
            record.isDir() || record.size <= 0 ? QString() : Formatters::fileSize(record.size);
        row.createdAtText = record.createdAt > 0
            ? Formatters::absoluteTime(QDateTime::fromMSecsSinceEpoch(record.createdAt))
            : QString();
        rows.append(row);
    }

    beginResetModel();
    m_rows = std::move(rows);
    endResetModel();
    emit countChanged();
}

void FavoriteListModel::onFavoriteChanged(const QString &connectionId, const QString &filePath,
                                          bool favorite)
{
    const int row = indexOf(connectionId, filePath);

    if (favorite) {
        // 新收藏：位置由收藏时间决定（倒序），整体重排最省心；
        // 已存在的行（重复收藏只刷新类型/大小）也要跟着刷新类型徽标
        reload();
        return;
    }

    if (row < 0) {
        return;
    }

    beginRemoveRows({}, row, row);
    m_rows.removeAt(row);
    endRemoveRows();
    emit countChanged();
}

int FavoriteListModel::indexOf(const QString &connectionId, const QString &filePath) const
{
    for (int i = 0; i < m_rows.size(); ++i) {
        if (m_rows.at(i).record.connectionId == connectionId
            && m_rows.at(i).record.filePath == filePath) {
            return i;
        }
    }
    return -1;
}

QVariantMap FavoriteListModel::get(int row) const
{
    if (row < 0 || row >= m_rows.size()) {
        return {};
    }

    const Row &entry = m_rows.at(row);
    QVariantMap map;
    map.insert(QStringLiteral("connectionId"), entry.record.connectionId);
    map.insert(QStringLiteral("connectionName"), entry.connectionName);
    map.insert(QStringLiteral("connectionAvailable"), entry.connectionAvailable);
    map.insert(QStringLiteral("filePath"), entry.record.filePath);
    map.insert(QStringLiteral("name"), entry.name);
    map.insert(QStringLiteral("mediaKind"), entry.record.mediaType);
    map.insert(QStringLiteral("mediaKindText"),
               MediaType::displayNameForBadge(entry.record.mediaType));
    map.insert(QStringLiteral("isDir"), entry.record.isDir());
    map.insert(QStringLiteral("size"), entry.record.size);
    map.insert(QStringLiteral("sizeText"), entry.sizeText);
    map.insert(QStringLiteral("createdAtText"), entry.createdAtText);
    return map;
}

bool FavoriteListModel::removeAt(int row)
{
    if (row < 0 || row >= m_rows.size()) {
        return false;
    }
    const Row &entry = m_rows.at(row);
    return FavoriteRepository::instance().remove(entry.record.connectionId, entry.record.filePath);
}

} // namespace myhub
