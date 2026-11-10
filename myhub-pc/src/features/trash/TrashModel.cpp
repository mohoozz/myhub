#include "TrashModel.h"

#include "core/cache/DirectoryCache.h"
#include "core/files/FileOperations.h"
#include "core/files/TrashStore.h"
#include "core/preferences/AppSettings.h"
#include "core/storage/StorageAdapter.h"
#include "core/storage/StoragePath.h"
#include "core/utils/AppLogger.h"
#include "core/utils/MediaType.h"
#include "features/connections/ConnectionStore.h"

#include <QDateTime>

#include <algorithm>
#include <functional>

namespace myhub {

namespace {

constexpr int kDefaultRetentionDays = 30;
constexpr int kMinRetentionDays = 1;
constexpr int kMaxRetentionDays = 365;
/// 元数据只有几十字节，给个上限即可（同时防止把大文件误当 meta 读进来）
constexpr qint64 kMetaReadLimit = 64LL * 1024;
constexpr qint64 kMsPerDay = 24LL * 60 * 60 * 1000;

/// 展示用文件名：去掉回收站内的顺延序号后缀（`a (1).mkv` → `a.mkv`）
QString displayNameFor(const QString &trashName, const QString &originalPath)
{
    if (!originalPath.isEmpty()) {
        const QString name = StoragePath::fileName(originalPath);
        if (!name.isEmpty()) {
            return name;
        }
    }
    return trashName;
}

} // namespace

/**
 * 一次扫描的共享状态。
 *
 * 结构是「连接源 → 条目 → meta 读取」三层异步，任何一层失败都不能中断整体：
 * 单个连接源不可用只影响它自己那部分条目。
 */
struct TrashModel::Scan
{
    struct ConnectionState
    {
        QString id;
        QString name;
        QVector<Item> items;
        int pendingMeta = 0;
        bool ready = false;
    };

    QVector<ConnectionState> connections;
    int nextConnection = 0;
    int failedConnections = 0;
    QVector<Item> collected;
};

QString TrashModel::Item::originalDir() const
{
    if (originalPath.isEmpty()) {
        return {};
    }
    return StoragePath::parent(originalPath);
}

int TrashModel::Item::daysLeft(int retentionDays) const
{
    if (!hasMeta || deletedAtMs <= 0 || retentionDays <= 0) {
        return -1;
    }
    const qint64 expireAt = deletedAtMs + retentionDays * kMsPerDay;
    const qint64 remaining = expireAt - QDateTime::currentMSecsSinceEpoch();
    if (remaining <= 0) {
        return 0;
    }
    // 向上取整：还剩 3 小时也显示「1 天后清理」，避免出现「0 天后」
    return static_cast<int>((remaining + kMsPerDay - 1) / kMsPerDay);
}

bool TrashModel::Item::expired(int retentionDays) const
{
    if (!hasMeta || deletedAtMs <= 0 || retentionDays <= 0) {
        return false; // 无元数据的条目不参与自动清理，避免误删用户数据
    }
    return QDateTime::currentMSecsSinceEpoch() >= deletedAtMs + retentionDays * kMsPerDay;
}

TrashModel::TrashModel(QObject *parent)
    : QAbstractListModel(parent)
{
    // 删除/还原都经 FileOperations，成功后本地移除行（不整页刷新）
    connect(
        &FileOperations::instance(), &FileOperations::restored, this,
        [this](const QString &connectionId, const QString &trashName, const QString &targetPath) {
            const int row = indexOfTrashName(connectionId, trashName);
            QString name = trashName;
            if (row >= 0) {
                name = m_items.at(row).name;
                removeRowsAt({row});
            }
            emit restored(name, targetPath);
        });
    connect(&FileOperations::instance(), &FileOperations::purged, this,
            [this](const QString &connectionId, const QStringList &trashNames) {
                QList<int> rows;
                rows.reserve(trashNames.size());
                for (const QString &trashName : trashNames) {
                    const int row = indexOfTrashName(connectionId, trashName);
                    if (row >= 0) {
                        rows.append(row);
                    }
                }
                if (rows.isEmpty()) {
                    return;
                }
                removeRowsAt(rows);
                emit purged(static_cast<int>(rows.size()));
            });
    connect(&FileOperations::instance(), &FileOperations::busyChanged, this,
            [this]() { emit busyChanged(); });
}

TrashModel::~TrashModel() = default;

int TrashModel::rowCount(const QModelIndex &parent) const
{
    if (parent.isValid()) {
        return 0;
    }
    return static_cast<int>(m_items.size());
}

QVariant TrashModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_items.size()) {
        return {};
    }
    const Item &item = m_items.at(index.row());
    switch (role) {
    case TrashNameRole:
        return item.trashName;
    case NameRole:
        return item.name;
    case OriginalPathRole:
        return item.originalPath;
    case OriginalDirRole:
        return item.originalDir();
    case IsDirRole:
        return item.isDir;
    case SizeRole:
        return item.size;
    case DeletedAtRole:
        return item.deletedAtMs;
    case DaysLeftRole:
        return item.daysLeft(retentionDays());
    case ConnectionIdRole:
        return item.connectionId;
    case ConnectionNameRole:
        return item.connectionName;
    case MediaKindRole:
        return item.mediaKind;
    case RestorableRole:
        return item.restorable();
    case ExpiredRole:
        return item.expired(retentionDays());
    default:
        return {};
    }
}

QHash<int, QByteArray> TrashModel::roleNames() const
{
    return {
        {TrashNameRole, "trashName"},
        {NameRole, "name"},
        {OriginalPathRole, "originalPath"},
        {OriginalDirRole, "originalDir"},
        {IsDirRole, "isDir"},
        {SizeRole, "size"},
        {DeletedAtRole, "deletedAt"},
        {DaysLeftRole, "daysLeft"},
        {ConnectionIdRole, "connectionId"},
        {ConnectionNameRole, "connectionName"},
        {MediaKindRole, "mediaKind"},
        {RestorableRole, "restorable"},
        {ExpiredRole, "expired"},
    };
}

bool TrashModel::busy() const
{
    return FileOperations::instance().busy();
}

void TrashModel::setLoading(bool loading)
{
    if (m_loading == loading) {
        return;
    }
    m_loading = loading;
    emit loadingChanged();
}

void TrashModel::setStatusText(const QString &text)
{
    if (m_statusText == text) {
        return;
    }
    m_statusText = text;
    emit statusTextChanged();
}

int TrashModel::retentionDays() const
{
    const int days = AppSettings::instance().trashRetentionDays();
    if (days <= 0) {
        return kDefaultRetentionDays;
    }
    return qBound(kMinRetentionDays, days, kMaxRetentionDays);
}

void TrashModel::setRetentionDays(int days)
{
    const int clamped =
        qBound(kMinRetentionDays, days <= 0 ? kDefaultRetentionDays : days, kMaxRetentionDays);
    if (clamped == retentionDays()) {
        return;
    }
    AppSettings::instance().setTrashRetentionDays(clamped);
    emit retentionDaysChanged();
    // 保留期变化会影响「剩余天数」与过期判定
    if (!m_items.isEmpty()) {
        emit dataChanged(index(0), index(static_cast<int>(m_items.size()) - 1),
                         {DaysLeftRole, ExpiredRole});
    }
}

QVariantMap TrashModel::get(int row) const
{
    QVariantMap map;
    if (row < 0 || row >= m_items.size()) {
        return map;
    }
    const QModelIndex idx = index(row);
    const auto roles = roleNames();
    for (auto it = roles.constBegin(); it != roles.constEnd(); ++it) {
        map.insert(QString::fromUtf8(it.value()), data(idx, it.key()));
    }
    return map;
}

void TrashModel::refresh()
{
    if (m_loading) {
        return;
    }
    setLoading(true);
    setStatusText(QStringLiteral("正在读取回收站…"));

    auto scan = std::make_shared<Scan>();
    const QList<ConnectionRecord> records = ConnectionStore::instance().connections();
    for (const ConnectionRecord &record : records) {
        if (!record.enabled) {
            continue;
        }
        Scan::ConnectionState state;
        state.id = record.id;
        state.name = record.name;
        scan->connections.append(state);
    }
    if (scan->connections.isEmpty()) {
        finishScan(scan);
        return;
    }
    scanConnection(scan, 0);
}

void TrashModel::scanConnection(const ScanPtr &scan, int connectionIndex)
{
    if (connectionIndex >= scan->connections.size()) {
        finishScan(scan);
        return;
    }
    scan->nextConnection = connectionIndex;

    const QString connectionId = scan->connections.at(connectionIndex).id;
    StorageAdapter *adapter = adapterFor(connectionId);
    if (!adapter) {
        ++scan->failedConnections;
        scanConnection(scan, connectionIndex + 1);
        return;
    }

    adapter->list(TrashStore::trashDir(),
                  [this, scan, adapter, connectionIndex](ListResult result) {
                      auto &state = scan->connections[connectionIndex];
                      // 回收站目录还不存在是正常状态（从没删过东西）
                      if (!result.ok() && result.error.kind() != StorageError::NotFound) {
                          ++scan->failedConnections;
                          MH_WARN(Storage,
                                  QStringLiteral("读取回收站失败（%1）：%2")
                                      .arg(state.name, result.error.userMessage()));
                          scanConnection(scan, connectionIndex + 1);
                          return;
                      }
                      if (result.ok()) {
                          for (const FileEntry &entry : result.value) {
                              if (TrashStore::isMetaName(entry.name)) {
                                  continue;
                              }
                              Item item;
                              item.trashName = entry.name;
                              item.name = entry.name;
                              item.isDir = entry.isDir;
                              item.size = entry.size;
                              item.modTimeMs =
                                  entry.modTime.isValid() ? entry.modTime.toMSecsSinceEpoch() : 0;
                              item.connectionId = state.id;
                              item.connectionName = state.name;
                              item.mediaKind =
                                  MediaType::badgeId(MediaType::fromPath(entry.name, entry.isDir));
                              state.items.append(item);
                          }
                      }
                      {
                          const int pending = static_cast<int>(state.items.size());
                          state.pendingMeta = pending;
                      }
                      if (state.items.isEmpty()) {
                          scanConnection(scan, connectionIndex + 1);
                          return;
                      }
                      readEntryMeta(scan, connectionIndex, 0);
                  });
}

void TrashModel::readEntryMeta(const ScanPtr &scan, int connectionIndex, int entryIndex)
{
    auto &state = scan->connections[connectionIndex];
    if (entryIndex >= state.items.size()) {
        // 本连接源读完：并入总表，继续下一个连接源
        for (const Item &item : state.items) {
            scan->collected.append(item);
        }
        scanConnection(scan, connectionIndex + 1);
        return;
    }

    StorageAdapter *adapter = adapterFor(state.id);
    if (!adapter) {
        readEntryMeta(scan, connectionIndex, entryIndex + 1);
        return;
    }

    const QString trashName = state.items.at(entryIndex).trashName;
    adapter->readRange(TrashStore::metaPath(trashName), 0, kMetaReadLimit - 1,
                       [this, scan, connectionIndex, entryIndex](DataResult result) {
                           auto &state = scan->connections[connectionIndex];
                           Item &item = state.items[entryIndex];
                           if (result.ok()) {
                               const TrashStore::Meta meta = TrashStore::decodeMeta(result.value);
                               if (meta.isValid()) {
                                   item.hasMeta = true;
                                   item.originalPath = meta.originalPath;
                                   item.deletedAtMs = meta.deletedAtMs;
                                   item.name = displayNameFor(item.trashName, meta.originalPath);
                                   item.mediaKind = MediaType::badgeId(
                                       MediaType::fromPath(meta.originalPath, item.isDir));
                               }
                           }
                           readEntryMeta(scan, connectionIndex, entryIndex + 1);
                       });
}

void TrashModel::finishScan(const ScanPtr &scan)
{
    // 按删除时间倒序；无元数据的排最后（按名字），保证顺序稳定
    QVector<Item> items = scan->collected;
    std::sort(items.begin(), items.end(), [](const Item &a, const Item &b) {
        if (a.hasMeta != b.hasMeta) {
            return a.hasMeta;
        }
        if (a.deletedAtMs != b.deletedAtMs) {
            return a.deletedAtMs > b.deletedAtMs;
        }
        if (a.connectionName != b.connectionName) {
            return a.connectionName < b.connectionName;
        }
        return a.trashName < b.trashName;
    });

    replaceItems(std::move(items));
    setLoading(false);

    const int total = static_cast<int>(m_items.size());
    if (scan->failedConnections > 0) {
        setStatusText(QStringLiteral("%1 个条目（%2 个连接源读取失败）")
                          .arg(QString::number(total), QString::number(scan->failedConnections)));
    } else if (total == 0) {
        setStatusText(QStringLiteral("回收站是空的"));
    } else {
        setStatusText(QStringLiteral("%1 个条目").arg(total));
    }

    purgeExpired();
}

void TrashModel::replaceItems(QVector<Item> items)
{
    beginResetModel();
    m_items = std::move(items);
    endResetModel();
    emit countChanged();
}

void TrashModel::removeRowsAt(const QList<int> &rows)
{
    QList<int> sorted = rows;
    std::sort(sorted.begin(), sorted.end(), std::greater<int>());
    for (const int row : std::as_const(sorted)) {
        if (row < 0 || row >= m_items.size()) {
            continue;
        }
        beginRemoveRows(QModelIndex(), row, row);
        m_items.removeAt(row);
        endRemoveRows();
    }
    emit countChanged();
}

StorageAdapter *TrashModel::adapterFor(const QString &connectionId)
{
    StorageError error;
    StorageAdapter *adapter = ConnectionStore::instance().adapterFor(connectionId, &error);
    if (!adapter && !error.isNull()) {
        MH_WARN(
            Storage,
            QStringLiteral("回收站：连接源 %1 不可用：%2").arg(connectionId, error.userMessage()));
    }
    return adapter;
}

int TrashModel::indexOfTrashName(const QString &connectionId, const QString &trashName) const
{
    for (int i = 0; i < m_items.size(); ++i) {
        const Item &item = m_items.at(i);
        if (item.connectionId == connectionId && item.trashName == trashName) {
            return i;
        }
    }
    return -1;
}

void TrashModel::restoreRow(int row)
{
    if (row < 0 || row >= m_items.size()) {
        return;
    }
    const Item item = m_items.at(row);
    if (!item.hasMeta) {
        emit failed(
            QStringLiteral("还原失败"),
            QStringLiteral("%1：该条目缺少删除记录（元数据丢失），只能彻底删除").arg(item.name));
        return;
    }
    StorageAdapter *adapter = adapterFor(item.connectionId);
    if (!adapter) {
        emit failed(QStringLiteral("还原失败"), QStringLiteral("连接源不可用，请检查连接状态"));
        return;
    }
    FileOperations::instance().restoreFromTrash(adapter, item.connectionId, item.trashName,
                                                item.originalPath);
}

void TrashModel::purgeRow(int row)
{
    if (row < 0 || row >= m_items.size()) {
        return;
    }
    const Item item = m_items.at(row);
    StorageAdapter *adapter = adapterFor(item.connectionId);
    if (!adapter) {
        emit failed(QStringLiteral("彻底删除失败"), QStringLiteral("连接源不可用，请检查连接状态"));
        return;
    }
    FileOperations::instance().purgeTrash(adapter, item.connectionId, {item.trashName});
}

void TrashModel::purgeAll()
{
    if (m_items.isEmpty()) {
        return;
    }
    // 按连接源分组：每个连接一次批量调用（适配器各不相同）
    QHash<QString, QStringList> byConnection;
    for (const Item &item : std::as_const(m_items)) {
        byConnection[item.connectionId].append(item.trashName);
    }
    for (auto it = byConnection.constBegin(); it != byConnection.constEnd(); ++it) {
        StorageAdapter *adapter = adapterFor(it.key());
        if (!adapter) {
            emit failed(QStringLiteral("清空回收站失败"),
                        QStringLiteral("连接源不可用，请检查连接状态"));
            continue;
        }
        FileOperations::instance().purgeTrash(adapter, it.key(), it.value());
    }
}

void TrashModel::purgeExpired()
{
    const int days = retentionDays();
    QHash<QString, QStringList> byConnection;
    for (const Item &item : std::as_const(m_items)) {
        if (item.expired(days)) {
            byConnection[item.connectionId].append(item.trashName);
        }
    }
    if (byConnection.isEmpty()) {
        return;
    }
    for (auto it = byConnection.constBegin(); it != byConnection.constEnd(); ++it) {
        StorageAdapter *adapter = adapterFor(it.key());
        if (!adapter) {
            continue;
        }
        MH_INFO(Storage,
                QStringLiteral("清理过期回收站条目 %1 个（保留 %2 天）")
                    .arg(QString::number(it.value().size()), QString::number(days)));
        FileOperations::instance().purgeTrash(adapter, it.key(), it.value());
    }
}

} // namespace myhub
