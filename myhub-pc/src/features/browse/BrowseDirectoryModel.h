#pragma once

#include "core/history/ProgressRepository.h"
#include "core/storage/FileEntry.h"
#include "core/storage/StorageError.h"

#include <QAbstractListModel>
#include <QHash>
#include <QQmlEngine>

namespace myhub {

/**
 * 目录列表模型（PC-102）。
 *
 * 关键纪律（iOS 实战经验）：
 *   - **stale-while-revalidate**：先出缓存秒开，后台刷新覆盖
 *   - **刷新失败保留旧内容**并给轻提示，不得清空列表（§14.10）
 *   - **并发刷新登记补刷**，不得静默吞掉（§3.1）
 *   - 操作成功后**本地立即更新**，不依赖网络刷新
 */
class BrowseDirectoryModel : public QAbstractListModel
{
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(
        QString connectionId READ connectionId WRITE setConnectionId NOTIFY connectionIdChanged)
    Q_PROPERTY(QString path READ path NOTIFY pathChanged)
    Q_PROPERTY(QString directoryName READ directoryName NOTIFY pathChanged)
    Q_PROPERTY(State state READ state NOTIFY stateChanged)
    Q_PROPERTY(QString errorText READ errorText NOTIFY stateChanged)
    Q_PROPERTY(bool refreshing READ isRefreshing NOTIFY refreshingChanged)
    Q_PROPERTY(int count READ rowCount NOTIFY countChanged)
    /// 内容版本号：任何一次列表重建都自增。
    /// QML 里 `get()` 是方法调用，绑定不会自动追踪行数据变化，
    /// 因此「由模型行派生的选中快照」必须显式依赖这个属性（否则拿到陈旧名字/路径）。
    Q_PROPERTY(int revision READ revision NOTIFY revisionChanged)
    Q_PROPERTY(QString searchText READ searchText WRITE setSearchText NOTIFY searchTextChanged)
    Q_PROPERTY(QString sortKey READ sortKey WRITE setSortKey NOTIFY sortChanged)
    Q_PROPERTY(bool sortAscending READ sortAscending WRITE setSortAscending NOTIFY sortChanged)
    Q_PROPERTY(bool canGoUp READ canGoUp NOTIFY pathChanged)
    /// 轻提示：刷新失败但保留了旧内容时展示
    Q_PROPERTY(QString transientNotice READ transientNotice NOTIFY transientNoticeChanged)

public:
    /// 四态（§3.1）
    enum State
    {
        Loading,
        Ready,
        EmptyDirectory,
        NoSearchResult,
        Error,
    };
    Q_ENUM(State)

    enum Roles
    {
        NameRole = Qt::UserRole + 1,
        PathRole,
        IsDirRole,
        SizeRole,
        SizeTextRole,
        ModTimeRole,
        ExtRole,
        MediaKindRole, ///< video/audio/novel/comic/image/text/folder
        BadgeRole,
        DurationTextRole, ///< 视频时长（M2 接入抽帧后填充）
        FingerprintRole,
        /// 阅读进度 0~1；无记录（或目录）返回 -1，QML 据此决定画不画进度环
        ProgressPercentRole,
        ProgressFinishedRole,
    };
    Q_ENUM(Roles)

    explicit BrowseDirectoryModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    QString connectionId() const { return m_connectionId; }
    void setConnectionId(const QString &id);

    int revision() const { return m_revision; }

    QString path() const { return m_path; }
    QString directoryName() const;
    State state() const { return m_state; }
    QString errorText() const { return m_errorText; }
    bool isRefreshing() const { return m_refreshing; }
    bool canGoUp() const;
    QString transientNotice() const { return m_transientNotice; }

    QString searchText() const { return m_searchText; }
    void setSearchText(const QString &text);

    QString sortKey() const { return m_sortKey; }
    void setSortKey(const QString &key);
    bool sortAscending() const { return m_sortAscending; }
    void setSortAscending(bool asc);

    // ---- 导航 ----
    Q_INVOKABLE void navigateTo(const QString &path);
    Q_INVOKABLE void goUp();
    Q_INVOKABLE void refresh();
    Q_INVOKABLE void clearNotice();
    /// 页面自定义轻提示（如「定位失败」）；与刷新失败共用同一条提示位
    Q_INVOKABLE void notify(const QString &text);

    /// 行数据（右键菜单 / 属性面板）
    Q_INVOKABLE QVariantMap get(int row) const;

    /// 可见行里某路径的下标（定位到原路径用，PC-109）；找不到返回 -1
    Q_INVOKABLE int indexOfPath(const QString &path) const;

    /// 当前目录下是否已有同名条目（大小写不敏感：本地盘 / SMB 普遍如此）
    Q_INVOKABLE bool hasEntry(const QString &name) const;

    // ---- 文件操作成功后的本地即时更新（§3.2：不依赖网络刷新）----
    /// 新建成功后调用：parentPath 是当前目录则就地插入，否则只让该目录缓存失效
    Q_INVOKABLE void applyCreated(const QString &parentPath, const QString &path, bool isDir);
    /// 重命名/移动成功后调用：同步条目路径，必要时在当前目录内增删
    Q_INVOKABLE void applyRenamed(const QString &oldPath, const QString &newPath);
    /// 删除（进回收站或永久）成功后调用：就地移除条目
    Q_INVOKABLE void applyRemoved(const QStringList &paths);

signals:
    void connectionIdChanged();
    void pathChanged();
    void stateChanged();
    void refreshingChanged();
    void countChanged();
    void revisionChanged();
    void searchTextChanged();
    void sortChanged();
    void transientNoticeChanged();

private:
    void loadDirectory(const QString &path, bool useCache);
    void applyEntries(const FileEntryList &entries, bool fromCache);
    void rebuildVisible();
    void setState(State s, const QString &error = QString());
    void setRefreshing(bool v);
    void setNotice(const QString &text);
    void loadSortPreference();

    /// 拉取当前连接源的全量进度摘要（切连接源时重来一次）
    void reloadProgressBriefs();
    /// 进度写入/删除后就地更新摘要，只通知真正受影响的那一行
    void onProgressChanged(const QString &connectionId, const QString &path);
    void onProgressRemoved(const QString &connectionId, const QString &path);
    void notifyProgressRow(const QString &path);

    QString m_connectionId;
    QString m_path = QStringLiteral("/");
    QString m_searchText;
    QString m_sortKey = QStringLiteral("name");
    bool m_sortAscending = true;

    FileEntryList m_all;     ///< 全量条目
    FileEntryList m_visible; ///< 过滤 + 排序后的可见条目

    State m_state = Loading;
    QString m_errorText;
    QString m_transientNotice;
    bool m_refreshing = false;
    int m_revision = 0;

    /// 并发刷新登记补刷（不得静默吞掉）
    bool m_pendingRefresh = false;
    quint64 m_requestToken = 0;

    /// 当前连接源的进度摘要（path → percent/finished），供状态角标
    QHash<QString, ProgressBrief> m_briefs;
};

} // namespace myhub
