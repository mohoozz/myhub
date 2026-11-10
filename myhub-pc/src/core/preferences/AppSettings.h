#pragma once

#include <QObject>
#include <QVariant>

class QSettings;

namespace myhub {

/**
 * 偏好设置（需求文档 §5.4）。
 *
 * 键名与 iOS 端 UserDefaults **完全对齐**，便于配置导入导出互导。
 * 所有设置项改动必须即时生效（§14.16），故一律通过信号广播。
 */
class AppSettings : public QObject
{
    Q_OBJECT

    // ---- 外观 ----
    Q_PROPERTY(QString themeMode READ themeMode WRITE setThemeMode NOTIFY themeModeChanged)

    // ---- 浏览（§5.4 browse.*）----
    Q_PROPERTY(QString sortKey READ sortKey WRITE setSortKey NOTIFY sortKeyChanged)
    Q_PROPERTY(
        bool sortAscending READ sortAscending WRITE setSortAscending NOTIFY sortAscendingChanged)
    Q_PROPERTY(QString viewMode READ viewMode WRITE setViewMode NOTIFY viewModeChanged)
    Q_PROPERTY(
        int fileNameLines READ fileNameLines WRITE setFileNameLines NOTIFY fileNameLinesChanged)
    Q_PROPERTY(bool openOnSingleClick READ openOnSingleClick WRITE setOpenOnSingleClick NOTIFY
                   openOnSingleClickChanged)

    // ---- 缓存 ----
    Q_PROPERTY(int cacheTotalLimitMB READ cacheTotalLimitMB WRITE setCacheTotalLimitMB NOTIFY
                   cacheTotalLimitMBChanged)
    Q_PROPERTY(bool contentCachingEnabled READ contentCachingEnabled WRITE setContentCachingEnabled
                   NOTIFY contentCachingEnabledChanged)

    // ---- 回收站 ----
    Q_PROPERTY(int trashRetentionDays READ trashRetentionDays WRITE setTrashRetentionDays NOTIFY
                   trashRetentionDaysChanged)

public:
    static AppSettings &instance();

    void initialize();
    void sync();

    // ---- 通用读写（供尚未单独建 Q_PROPERTY 的键使用）----
    Q_INVOKABLE QVariant value(const QString &key, const QVariant &defaultValue = {}) const;
    Q_INVOKABLE void setValue(const QString &key, const QVariant &value);
    Q_INVOKABLE bool contains(const QString &key) const;
    Q_INVOKABLE void remove(const QString &key);

    // ---- 外观 ----
    QString themeMode() const; ///< auto / light / dark
    void setThemeMode(const QString &v);

    // ---- 浏览 ----
    QString sortKey() const; ///< name / size / time
    void setSortKey(const QString &v);
    bool sortAscending() const;
    void setSortAscending(bool v);
    QString viewMode() const; ///< grid / list
    void setViewMode(const QString &v);
    int fileNameLines() const; ///< 1~5，默认 3
    void setFileNameLines(int v);
    bool openOnSingleClick() const;
    void setOpenOnSingleClick(bool v);

    // ---- 缓存 ----
    int cacheTotalLimitMB() const;
    void setCacheTotalLimitMB(int v);
    bool contentCachingEnabled() const;
    void setContentCachingEnabled(bool v);

    // ---- 回收站 ----
    int trashRetentionDays() const;
    void setTrashRetentionDays(int v);

    // ---- 每目录排序偏好（browse.sortPreferences.v1，上限 500 条 LRU）----
    Q_INVOKABLE QVariantMap directorySortPreference(const QString &connectionId,
                                                    const QString &path) const;
    Q_INVOKABLE void setDirectorySortPreference(const QString &connectionId, const QString &path,
                                                const QString &key, bool ascending);

    // ---- 连接测试状态缓存（connectionTestStates.v1）----
    /// 状态持久化：列表进入时不重复探测，仅手动测试或重启才重判（PC-101）
    Q_INVOKABLE QVariantMap connectionTestState(const QString &connectionId) const;
    Q_INVOKABLE void setConnectionTestState(const QString &connectionId, bool reachable,
                                            const QString &scope, const QString &message);
    Q_INVOKABLE void clearConnectionTestState(const QString &connectionId);

    // ---- 窗口（window.*）----
    QRect windowBounds() const;
    void setWindowBounds(const QRect &r);
    bool windowMaximized() const;
    void setWindowMaximized(bool v);
    bool sidebarCollapsed() const;
    void setSidebarCollapsed(bool v);

signals:
    void themeModeChanged();
    void sortKeyChanged();
    void sortAscendingChanged();
    void viewModeChanged();
    void fileNameLinesChanged();
    void openOnSingleClickChanged();
    void cacheTotalLimitMBChanged();
    void contentCachingEnabledChanged();
    void trashRetentionDaysChanged();
    /// 任意键变更的通用广播（便于局部刷新）
    void settingChanged(const QString &key);

private:
    explicit AppSettings(QObject *parent = nullptr);
    ~AppSettings() override;
    Q_DISABLE_COPY_MOVE(AppSettings)

    void pruneSortPreferences();

    QSettings *m_settings = nullptr;
};

} // namespace myhub
