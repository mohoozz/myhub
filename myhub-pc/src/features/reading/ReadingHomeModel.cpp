#include "ReadingHomeModel.h"

#include "core/history/ProgressRepository.h"

#include <QDateTime>
#include <QVariantList>
#include <QVariantMap>

#include <algorithm>
#include <functional>

#include "features/connections/ConnectionStore.h"

namespace myhub {
namespace {

/// 首页只展示最近 N 条（记录会一直保留，但不值得一次性全查出来）
constexpr int kRecentLimit = 200;

/// 连接源信息（首页徽标/可用性判定用），按 id 缓存一份
struct ConnectionInfo
{
    QString name;
    bool local = false;
    bool available = false;
};

} // namespace

ReadingHomeModel::ReadingHomeModel(QObject *parent)
    : QAbstractListModel(parent)
{
    auto &repository = ProgressRepository::instance();
    connect(&repository, &ProgressRepository::progressChanged, this,
            &ReadingHomeModel::onProgressChanged);
    connect(&repository, &ProgressRepository::progressRemoved, this,
            &ReadingHomeModel::onProgressRemoved);

    // 连接源改名 / 删除后，首页的名称与「可打开」状态要跟着变
    connect(&ConnectionStore::instance(), &ConnectionStore::connectionsChanged, this,
            &ReadingHomeModel::reload);

    reload();
}

int ReadingHomeModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : int(m_rows.size());
}

QVariant ReadingHomeModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_rows.size()) {
        return {};
    }

    const Row &row = m_rows.at(index.row());
    const ReadingEntry &entry = row.entry;
    switch (role) {
    case ConnectionIdRole:
        return entry.connectionId;
    case ConnectionNameRole:
        return row.connectionName;
    case ConnectionLocalRole:
        return row.connectionLocal;
    case ConnectionAvailableRole:
        return row.connectionAvailable;
    case PathRole:
        return entry.path;
    case TitleRole:
        return entry.title;
    case MediaKindRole:
        return entry.mediaKind;
    case KindTextRole:
        return entry.kindText;
    case PercentRole:
        return entry.percent;
    case PercentTextRole:
        return entry.percentText;
    case FinishedRole:
        return entry.finished;
    case FinishedTextRole:
        return entry.finishedText;
    case RelativeTimeRole:
        return entry.relativeTime;
    case UpdatedAtRole:
        return entry.updatedAt;
    case ResumeMsRole:
        return entry.resumeMs;
    default:
        return {};
    }
}

QHash<int, QByteArray> ReadingHomeModel::roleNames() const
{
    return {
        {ConnectionIdRole, "connectionId"},
        {ConnectionNameRole, "connectionName"},
        {ConnectionLocalRole, "connectionLocal"},
        {ConnectionAvailableRole, "connectionAvailable"},
        {PathRole, "filePath"},
        {TitleRole, "title"},
        {MediaKindRole, "mediaKind"},
        {KindTextRole, "kindText"},
        {PercentRole, "percent"},
        {PercentTextRole, "percentText"},
        {FinishedRole, "finished"},
        {FinishedTextRole, "finishedText"},
        {RelativeTimeRole, "relativeTime"},
        {UpdatedAtRole, "updatedAt"},
        {ResumeMsRole, "resumeMs"},
    };
}

void ReadingHomeModel::refresh()
{
    reload();
}

void ReadingHomeModel::reload()
{
    const auto &store = ConnectionStore::instance();

    const QList<ProgressRecord> records = ProgressRepository::instance().recent(kRecentLimit);
    const QList<ReadingEntry> entries =
        ReadingEntry::fromRecords(records, QDateTime::currentMSecsSinceEpoch());

    QVector<Row> rows;
    rows.reserve(entries.size());
    for (const auto &entry : entries) {
        Row row;
        row.entry = entry;
        const ConnectionRecord connection = store.byId(entry.connectionId);
        row.connectionAvailable = connection.isValid();
        row.connectionLocal = connection.type == ConnectionType::Local;
        row.connectionName = connection.isValid() ? connection.name : QString();
        rows.append(row);
    }

    const bool wasEmpty = m_rows.isEmpty();
    beginResetModel();
    m_rows = std::move(rows);
    endResetModel();

    emit countChanged();
    if (wasEmpty != m_rows.isEmpty()) {
        emit stateChanged();
    }
}

void ReadingHomeModel::onProgressChanged(const QString &connectionId, const QString &path)
{
    const int row = indexOf(connectionId, path);
    if (row < 0) {
        // 新记录：位置由 updatedAt 决定，直接整体重排
        reload();
        return;
    }

    ProgressRecord record;
    if (!ProgressRepository::instance().find(connectionId, path, &record)) {
        return;
    }

    // 只改这一行：播放中每 5s 都会走到这里，重整列表会让首页持续跳动
    m_rows[row].entry = ReadingEntry::fromRecord(record, QDateTime::currentMSecsSinceEpoch());
    const QModelIndex changed = index(row);
    emit dataChanged(changed, changed);
}

void ReadingHomeModel::onProgressRemoved(const QString &connectionId, const QString &path)
{
    const int row = indexOf(connectionId, path);
    if (row < 0) {
        return;
    }

    const bool wasEmpty = m_rows.isEmpty();
    beginRemoveRows({}, row, row);
    m_rows.removeAt(row);
    endRemoveRows();

    emit countChanged();
    if (wasEmpty != m_rows.isEmpty()) {
        emit stateChanged();
    }
}

int ReadingHomeModel::indexOf(const QString &connectionId, const QString &path) const
{
    for (int i = 0; i < m_rows.size(); ++i) {
        if (m_rows.at(i).entry.connectionId == connectionId && m_rows.at(i).entry.path == path) {
            return i;
        }
    }
    return -1;
}

QVariantMap ReadingHomeModel::get(int row) const
{
    if (row < 0 || row >= m_rows.size()) {
        return {};
    }

    const Row &entry = m_rows.at(row);
    QVariantMap map;
    map.insert(QStringLiteral("connectionId"), entry.entry.connectionId);
    map.insert(QStringLiteral("connectionName"), entry.connectionName);
    map.insert(QStringLiteral("connectionAvailable"), entry.connectionAvailable);
    map.insert(QStringLiteral("filePath"), entry.entry.path);
    map.insert(QStringLiteral("title"), entry.entry.title);
    map.insert(QStringLiteral("mediaKind"), entry.entry.mediaKind);
    map.insert(QStringLiteral("kindText"), entry.entry.kindText);
    map.insert(QStringLiteral("percent"), entry.entry.percent);
    map.insert(QStringLiteral("percentText"), entry.entry.percentText);
    map.insert(QStringLiteral("finished"), entry.entry.finished);
    map.insert(QStringLiteral("finishedText"), entry.entry.finishedText);
    map.insert(QStringLiteral("relativeTime"), entry.entry.relativeTime);
    map.insert(QStringLiteral("resumeMs"), entry.entry.resumeMs);
    return map;
}

bool ReadingHomeModel::removeAt(int row)
{
    return removeRows({row}) > 0;
}

int ReadingHomeModel::removeRows(const QVariantList &rows)
{
    QList<int> targets;
    for (const auto &value : rows) {
        const int row = value.toInt();
        if (row >= 0 && row < m_rows.size() && !targets.contains(row)) {
            targets.append(row);
        }
    }
    // 降序删除：每删一行，后面的行号都会前移，倒着删才不会被带偏
    std::sort(targets.begin(), targets.end(), std::greater<int>());

    int removed = 0;
    for (const int row : targets) {
        const QString connectionId = m_rows.at(row).entry.connectionId;
        const QString path = m_rows.at(row).entry.path;
        if (ProgressRepository::instance().remove(connectionId, path)) {
            ++removed;
        }
    }
    return removed;
}

} // namespace myhub
