#include "BrowseDirectoryModel.h"

#include "features/connections/ConnectionStore.h"

#include "core/cache/DirectoryCache.h"
#include "core/preferences/AppSettings.h"
#include "core/storage/StorageAdapter.h"
#include "core/storage/StoragePath.h"
#include "core/utils/AppLogger.h"
#include "core/utils/Formatters.h"
#include "core/utils/MediaType.h"
#include "core/utils/NaturalSort.h"

#include <QPointer>
#include <algorithm>

namespace myhub {

BrowseDirectoryModel::BrowseDirectoryModel(QObject *parent)
    : QAbstractListModel(parent)
{
    auto &settings = AppSettings::instance();
    m_sortKey = settings.sortKey();
    m_sortAscending = settings.sortAscending();

    // 状态角标（阅读进度环）随播放/阅读进度实时更新：
    // 播放条在底部继续播时，目录里的进度环也要跟着动
    auto &repo = ProgressRepository::instance();
    connect(&repo, &ProgressRepository::progressChanged, this,
            &BrowseDirectoryModel::onProgressChanged);
    connect(&repo, &ProgressRepository::progressRemoved, this,
            &BrowseDirectoryModel::onProgressRemoved);
}

int BrowseDirectoryModel::rowCount(const QModelIndex &parent) const
{
    if (parent.isValid())
        return 0;
    return m_visible.size();
}

QHash<int, QByteArray> BrowseDirectoryModel::roleNames() const
{
    return {
        {NameRole, QByteArrayLiteral("name")},
        {PathRole, QByteArrayLiteral("filePath")},
        {IsDirRole, QByteArrayLiteral("isDir")},
        {SizeRole, QByteArrayLiteral("size")},
        {SizeTextRole, QByteArrayLiteral("sizeText")},
        {ModTimeRole, QByteArrayLiteral("modTime")},
        {ExtRole, QByteArrayLiteral("ext")},
        {MediaKindRole, QByteArrayLiteral("mediaKind")},
        {BadgeRole, QByteArrayLiteral("badge")},
        {DurationTextRole, QByteArrayLiteral("durationText")},
        {FingerprintRole, QByteArrayLiteral("fingerprint")},
        {ProgressPercentRole, QByteArrayLiteral("progressPercent")},
        {ProgressFinishedRole, QByteArrayLiteral("progressFinished")},
    };
}

QVariant BrowseDirectoryModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_visible.size())
        return {};

    const FileEntry &e = m_visible.at(index.row());
    const MediaType::Kind kind = MediaType::fromPath(e.path, e.isDir);

    switch (role) {
    case NameRole:
        return e.name;
    case PathRole:
        return e.path;
    case IsDirRole:
        return e.isDir;
    case SizeRole:
        return e.size;
    case SizeTextRole:
        // 目录不显示大小，也不显示子项数（§14.3）
        return e.isDir ? QString() : Formatters::fileSize(e.size);
    case ModTimeRole:
        return e.modTime;
    case ExtRole:
        return e.ext;
    case MediaKindRole:
        return MediaType::badgeId(kind);
    case BadgeRole:
        // 漫画徽标等（目录与普通文件无徽标）
        return (kind == MediaType::Comic) ? QStringLiteral("comic") : QString();
    case DurationTextRole:
        return QString(); // M2 接入视频抽帧后填充
    case FingerprintRole:
        return e.fingerprint();
    case ProgressPercentRole: {
        // 目录不显示进度（§3.1 状态指示）；无记录返回 -1 表示「不画环」
        if (e.isDir)
            return -1.0;
        const auto it = m_briefs.constFind(e.path);
        return it == m_briefs.cend() ? -1.0 : it->percent;
    }
    case ProgressFinishedRole: {
        if (e.isDir)
            return false;
        const auto it = m_briefs.constFind(e.path);
        return it != m_briefs.cend() && it->finished;
    }
    default:
        break;
    }
    return {};
}

QString BrowseDirectoryModel::directoryName() const
{
    // 顶部操作栏显示当前目录名；根目录显示连接名（§3.1）
    if (StoragePath::isRoot(m_path)) {
        const ConnectionRecord r = ConnectionStore::instance().byId(m_connectionId);
        return r.isValid() ? r.name : QString();
    }
    return StoragePath::fileName(m_path);
}

bool BrowseDirectoryModel::canGoUp() const
{
    return !StoragePath::isRoot(m_path);
}

void BrowseDirectoryModel::setConnectionId(const QString &id)
{
    if (m_connectionId == id)
        return;
    m_connectionId = id;
    emit connectionIdChanged();

    // 摘要按连接源取：换源必须换表，否则会拿上一个源的进度画环
    reloadProgressBriefs();

    m_path = QStringLiteral("/");
    m_searchText.clear();
    emit pathChanged();
    emit searchTextChanged();

    loadSortPreference();
    loadDirectory(m_path, true);
}

void BrowseDirectoryModel::setSearchText(const QString &text)
{
    if (m_searchText == text)
        return;
    m_searchText = text;
    emit searchTextChanged();
    rebuildVisible();
}

void BrowseDirectoryModel::loadSortPreference()
{
    // 每个目录独立记忆排序偏好；无记录回落全局默认（§3.1）
    auto &settings = AppSettings::instance();
    const QVariantMap pref = settings.directorySortPreference(m_connectionId, m_path);
    if (pref.isEmpty()) {
        m_sortKey = settings.sortKey();
        m_sortAscending = settings.sortAscending();
    } else {
        m_sortKey = pref.value(QStringLiteral("key"), settings.sortKey()).toString();
        m_sortAscending = pref.value(QStringLiteral("asc"), settings.sortAscending()).toBool();
    }
    emit sortChanged();
}

void BrowseDirectoryModel::setSortKey(const QString &key)
{
    if (m_sortKey == key)
        return;
    m_sortKey = key;
    AppSettings::instance().setDirectorySortPreference(m_connectionId, m_path, m_sortKey,
                                                       m_sortAscending);
    emit sortChanged();
    rebuildVisible();
}

void BrowseDirectoryModel::setSortAscending(bool asc)
{
    if (m_sortAscending == asc)
        return;
    m_sortAscending = asc;
    AppSettings::instance().setDirectorySortPreference(m_connectionId, m_path, m_sortKey,
                                                       m_sortAscending);
    emit sortChanged();
    rebuildVisible();
}

void BrowseDirectoryModel::navigateTo(const QString &path)
{
    const QString target = StoragePath::normalize(path);
    if (target == m_path && m_state == Ready)
        return;

    m_path = target;
    m_searchText.clear();
    emit pathChanged();
    emit searchTextChanged();

    loadSortPreference();
    loadDirectory(m_path, true);
}

void BrowseDirectoryModel::goUp()
{
    if (!canGoUp())
        return;
    navigateTo(StoragePath::parent(m_path));
}

void BrowseDirectoryModel::refresh()
{
    // 并发刷新 → 登记补刷，不得静默吞掉（§3.1）
    if (m_refreshing) {
        m_pendingRefresh = true;
        return;
    }
    loadDirectory(m_path, false);
}

void BrowseDirectoryModel::setState(State s, const QString &error)
{
    if (m_state == s && m_errorText == error)
        return;
    m_state = s;
    m_errorText = error;
    emit stateChanged();
}

void BrowseDirectoryModel::setRefreshing(bool v)
{
    if (m_refreshing == v)
        return;
    m_refreshing = v;
    emit refreshingChanged();
}

void BrowseDirectoryModel::setNotice(const QString &text)
{
    if (m_transientNotice == text)
        return;
    m_transientNotice = text;
    emit transientNoticeChanged();
}

void BrowseDirectoryModel::clearNotice()
{
    setNotice(QString());
}

void BrowseDirectoryModel::notify(const QString &text)
{
    setNotice(text);
}

void BrowseDirectoryModel::loadDirectory(const QString &path, bool useCache)
{
    if (m_connectionId.isEmpty())
        return;

    const quint64 token = ++m_requestToken;
    setNotice(QString());

    // 1) 先出缓存秒开（stale-while-revalidate）
    bool servedFromCache = false;
    if (useCache) {
        FileEntryList cached;
        if (DirectoryCache::instance().load(m_connectionId, path, &cached)) {
            applyEntries(cached, true);
            servedFromCache = true;
        }
    }
    if (!servedFromCache && m_all.isEmpty())
        setState(Loading);

    // 2) 后台刷新
    StorageError err;
    StorageAdapter *adapter = ConnectionStore::instance().adapterFor(m_connectionId, &err);
    if (!adapter) {
        if (!servedFromCache)
            setState(Error, err.userMessage());
        else
            setNotice(err.userMessage());
        return;
    }

    setRefreshing(true);
    const QString connId = m_connectionId;
    QPointer<BrowseDirectoryModel> self(this);

    adapter->list(path, [self, token, path, connId, servedFromCache](ListResult result) {
        if (!self || token != self->m_requestToken)
            return; // 已切换目录，丢弃过期结果

        self->setRefreshing(false);

        if (!result.ok()) {
            MH_WARN(Storage,
                    QStringLiteral("list %1 failed: %2").arg(path, result.error.message()));
            // 刷新失败：保留旧缓存内容并给轻提示，不得清空列表（§14.10）
            if (servedFromCache || !self->m_all.isEmpty())
                self->setNotice(result.error.userMessage());
            else
                self->setState(Error, result.error.userMessage());
        } else {
            // 成功才写缓存；空列表此时已被适配器严格校验过，可信为真空目录
            DirectoryCache::instance().store(connId, path, result.value,
                                             /*verifiedEmpty=*/true);
            self->applyEntries(result.value, false);
        }

        // 补刷登记
        if (self->m_pendingRefresh) {
            self->m_pendingRefresh = false;
            self->loadDirectory(self->m_path, false);
        }
    });
}

void BrowseDirectoryModel::applyEntries(const FileEntryList &entries, bool fromCache)
{
    Q_UNUSED(fromCache)
    m_all = entries;
    rebuildVisible();
}

void BrowseDirectoryModel::reloadProgressBriefs()
{
    m_briefs = ProgressRepository::instance().briefs(m_connectionId);
}

void BrowseDirectoryModel::onProgressChanged(const QString &connectionId, const QString &path)
{
    if (connectionId != m_connectionId || path.isEmpty())
        return;

    // 变化事件只带键，不值当为一行再查一次集合表：单条查回两个字段即可
    ProgressRecord record;
    if (ProgressRepository::instance().find(connectionId, path, &record))
        m_briefs.insert(path, {record.percent, record.finished});
    else
        m_briefs.remove(path);

    notifyProgressRow(path);
}

void BrowseDirectoryModel::onProgressRemoved(const QString &connectionId, const QString &path)
{
    if (connectionId != m_connectionId)
        return;
    if (m_briefs.remove(path) == 0)
        return;
    notifyProgressRow(path);
}

void BrowseDirectoryModel::notifyProgressRow(const QString &path)
{
    const int row = indexOfPath(path);
    if (row < 0)
        return; // 不在当前目录（或已被搜索过滤），无需惊动视图
    emit dataChanged(index(row), index(row), {ProgressPercentRole, ProgressFinishedRole});
}

void BrowseDirectoryModel::rebuildVisible()
{
    FileEntryList filtered;
    filtered.reserve(m_all.size());

    // 当前目录内搜索
    if (m_searchText.isEmpty()) {
        filtered = m_all;
    } else {
        for (const FileEntry &e : m_all) {
            if (e.name.contains(m_searchText, Qt::CaseInsensitive))
                filtered.append(e);
        }
    }

    // 排序：目录恒在文件之前
    const QString key = m_sortKey;
    const bool asc = m_sortAscending;
    std::sort(filtered.begin(), filtered.end(), [key, asc](const FileEntry &a, const FileEntry &b) {
        if (a.isDir != b.isDir)
            return a.isDir;

        int cmp = 0;
        if (key == QLatin1String("size")) {
            cmp = (a.size < b.size) ? -1 : (a.size > b.size ? 1 : 0);
        } else if (key == QLatin1String("time")) {
            if (a.modTime != b.modTime)
                cmp = (a.modTime < b.modTime) ? -1 : 1;
        }
        if (cmp == 0)
            cmp = NaturalSort::compare(a.name, b.name);
        return asc ? (cmp < 0) : (cmp > 0);
    });

    beginResetModel();
    m_visible = std::move(filtered);
    endResetModel();
    emit countChanged();
    // 行数据变了：QML 侧由行派生的快照（选中项名称/路径）靠这个版本号重新求值
    ++m_revision;
    emit revisionChanged();

    // 四态判定
    if (m_visible.isEmpty()) {
        if (!m_searchText.isEmpty())
            setState(NoSearchResult);
        else if (m_state != Error)
            setState(EmptyDirectory);
    } else {
        setState(Ready);
    }
}

bool BrowseDirectoryModel::hasEntry(const QString &name) const
{
    for (const FileEntry &e : m_all) {
        if (e.name.compare(name, Qt::CaseInsensitive) == 0) {
            return true;
        }
    }
    return false;
}

void BrowseDirectoryModel::applyCreated(const QString &parentPath, const QString &path, bool isDir)
{
    const QString parent = StoragePath::normalize(parentPath);
    if (parent != m_path) {
        // 不在当前目录：只让那个目录的缓存失效，下次进入时重新拉取
        DirectoryCache::instance().invalidate(m_connectionId, parent);
        return;
    }

    const QString normalized = StoragePath::normalize(path);
    for (const FileEntry &e : m_all) {
        if (e.path == normalized) {
            return; // 后台刷新抢先一步，列表里已经有了
        }
    }

    FileEntry entry;
    entry.name = StoragePath::fileName(normalized);
    entry.path = normalized;
    entry.isDir = isDir;
    entry.ext = isDir ? QString() : StoragePath::extension(normalized);
    m_all.append(entry);

    rebuildVisible();
    DirectoryCache::instance().store(m_connectionId, m_path, m_all);
}

void BrowseDirectoryModel::applyRenamed(const QString &oldPath, const QString &newPath)
{
    const QString source = StoragePath::normalize(oldPath);
    const QString target = StoragePath::normalize(newPath);
    const QString sourceParent = StoragePath::parent(source);
    const QString targetParent = StoragePath::parent(target);

    auto applyMove = [this](const QString &from, const QString &to) {
        for (FileEntry &e : m_all) {
            if (e.path != from) {
                continue;
            }
            e.path = to;
            e.name = StoragePath::fileName(to);
            e.ext = e.isDir ? QString() : StoragePath::extension(to);
            return true;
        }
        return false;
    };

    bool changed = false;
    if (sourceParent == m_path) {
        if (targetParent == m_path) {
            changed = applyMove(source, target); // 同目录改名
        } else {
            // 移动到别处：当前目录里就地移除
            for (int i = 0; i < m_all.size(); ++i) {
                if (m_all.at(i).path == source) {
                    m_all.removeAt(i);
                    changed = true;
                    break;
                }
            }
        }
    } else if (targetParent == m_path) {
        // 从别处移进来：条目类型/大小都未知，交给一次后台刷新校正
        DirectoryCache::instance().invalidate(m_connectionId, m_path);
        refresh();
        return;
    }

    if (changed) {
        rebuildVisible();
        DirectoryCache::instance().store(m_connectionId, m_path, m_all, m_all.isEmpty());
    }
    DirectoryCache::instance().invalidate(m_connectionId, sourceParent);
    DirectoryCache::instance().invalidate(m_connectionId, targetParent);
}

void BrowseDirectoryModel::applyRemoved(const QStringList &paths)
{
    bool changed = false;
    for (const QString &path : paths) {
        const QString normalized = StoragePath::normalize(path);
        for (int i = m_all.size() - 1; i >= 0; --i) {
            if (m_all.at(i).path == normalized) {
                m_all.removeAt(i);
                changed = true;
            }
        }
        DirectoryCache::instance().invalidate(m_connectionId, StoragePath::parent(normalized));
    }
    if (!changed) {
        return;
    }
    rebuildVisible();
    // 删到空时是「确认为空目录」，可以直接写缓存
    DirectoryCache::instance().store(m_connectionId, m_path, m_all, m_all.isEmpty());
}

int BrowseDirectoryModel::indexOfPath(const QString &path) const
{
    if (path.isEmpty())
        return -1;
    const QString target = StoragePath::normalize(path);
    for (int i = 0; i < m_visible.size(); ++i) {
        if (m_visible.at(i).path == target)
            return i;
    }
    return -1;
}

QVariantMap BrowseDirectoryModel::get(int row) const
{
    QVariantMap out;
    if (row < 0 || row >= m_visible.size())
        return out;

    const FileEntry &e = m_visible.at(row);
    out.insert(QStringLiteral("name"), e.name);
    out.insert(QStringLiteral("filePath"), e.path);
    out.insert(QStringLiteral("isDir"), e.isDir);
    out.insert(QStringLiteral("size"), e.size);
    out.insert(QStringLiteral("sizeText"), e.isDir ? QString() : Formatters::fileSize(e.size));
    out.insert(QStringLiteral("modTime"), e.modTime);
    out.insert(QStringLiteral("modTimeText"), Formatters::absoluteTime(e.modTime));
    out.insert(QStringLiteral("ext"), e.ext);
    out.insert(QStringLiteral("mediaKind"),
               MediaType::badgeId(MediaType::fromPath(e.path, e.isDir)));
    out.insert(QStringLiteral("mediaKindText"),
               MediaType::displayName(MediaType::fromPath(e.path, e.isDir)));
    // 是否可在线编辑（PC-103）：右键「编辑文本」仅对纯文本类出现
    out.insert(QStringLiteral("textEditable"), MediaType::isEditableText(e.path, e.isDir));
    out.insert(QStringLiteral("fingerprint"), e.fingerprint());
    out.insert(QStringLiteral("connectionId"), m_connectionId);
    return out;
}

} // namespace myhub
