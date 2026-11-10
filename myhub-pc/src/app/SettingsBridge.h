#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QVariant>

namespace myhub {

/**
 * AppSettings 的 QML 桥接。
 *
 * 为什么需要桥接：`core/preferences/AppSettings` 位于纯逻辑层，
 * 按分层约定（§5.2）**不得依赖 QtQml**，因此不能直接加 QML_ELEMENT。
 * 本类作为应用层的薄包装暴露给 QML，转发属性与信号。
 *
 * 纪律：所有设置项改动必须即时生效（§14.16），故一律通过信号广播。
 */
class SettingsBridge : public QObject
{
    Q_OBJECT
    QML_NAMED_ELEMENT(AppSettings)
    QML_SINGLETON

    // ---- 浏览（§5.4 browse.*）----
    Q_PROPERTY(QString viewMode READ viewMode WRITE setViewMode NOTIFY viewModeChanged)
    Q_PROPERTY(
        int fileNameLines READ fileNameLines WRITE setFileNameLines NOTIFY fileNameLinesChanged)
    Q_PROPERTY(bool openOnSingleClick READ openOnSingleClick WRITE setOpenOnSingleClick NOTIFY
                   openOnSingleClickChanged)
    Q_PROPERTY(QString sortKey READ sortKey WRITE setSortKey NOTIFY sortKeyChanged)
    Q_PROPERTY(
        bool sortAscending READ sortAscending WRITE setSortAscending NOTIFY sortAscendingChanged)

    // ---- 缓存 ----
    Q_PROPERTY(int cacheTotalLimitMB READ cacheTotalLimitMB WRITE setCacheTotalLimitMB NOTIFY
                   cacheTotalLimitMBChanged)
    Q_PROPERTY(bool contentCachingEnabled READ contentCachingEnabled WRITE setContentCachingEnabled
                   NOTIFY contentCachingEnabledChanged)

    // ---- 回收站 ----
    Q_PROPERTY(int trashRetentionDays READ trashRetentionDays WRITE setTrashRetentionDays NOTIFY
                   trashRetentionDaysChanged)

public:
    static SettingsBridge *create(QQmlEngine *, QJSEngine *);

    // 无默认参数：让 Qt 走 create() 工厂（否则默认构造会抢在工厂之前生效）
    explicit SettingsBridge(QObject *parent);

    QString viewMode() const;
    void setViewMode(const QString &v);

    int fileNameLines() const;
    void setFileNameLines(int v);

    bool openOnSingleClick() const;
    void setOpenOnSingleClick(bool v);

    QString sortKey() const;
    void setSortKey(const QString &v);

    bool sortAscending() const;
    void setSortAscending(bool v);

    int cacheTotalLimitMB() const;
    void setCacheTotalLimitMB(int v);

    bool contentCachingEnabled() const;
    void setContentCachingEnabled(bool v);

    int trashRetentionDays() const;
    void setTrashRetentionDays(int v);

    /// 通用读写（尚未单列属性的键）
    Q_INVOKABLE QVariant value(const QString &key, const QVariant &defaultValue = {}) const;
    Q_INVOKABLE void setValue(const QString &key, const QVariant &value);

signals:
    void viewModeChanged();
    void fileNameLinesChanged();
    void openOnSingleClickChanged();
    void sortKeyChanged();
    void sortAscendingChanged();
    void cacheTotalLimitMBChanged();
    void contentCachingEnabledChanged();
    void trashRetentionDaysChanged();
};

} // namespace myhub
