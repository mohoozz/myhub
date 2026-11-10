#pragma once

#include "core/storage/StorageAdapterFactory.h"

#include <QHash>
#include <QObject>
#include <QQmlEngine>
#include <QVariantMap>

namespace myhub {

class StorageAdapter;

/**
 * 连接源仓库（PC-101 / PC-501）—— 全局唯一数据源。
 *
 * 关键纪律（iOS 实战经验）：
 *   - **浏览页卡片与设置页列表必须显示同一状态**：一处刷新两处同步，
 *     故这里是唯一数据源，UI 全部由此驱动（§14.9）
 *   - **连接测试状态持久化缓存**：进入页面不重复探测，
 *     仅手动「测试连接」或重启应用才重新判定（PC-101）
 *   - **新增连接源后浏览页立即可见**（无需重启，§14.10）
 *   - 凭据持久保存，**仅删除连接源时**才清除（§2.4）
 */
class ConnectionStore : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(bool loaded READ isLoaded NOTIFY loadedChanged)
    /// 最近一次 upsert 产生的 id（新建后供表单继续操作）
    Q_PROPERTY(QString lastUpsertedId READ lastUpsertedId NOTIFY connectionsChanged)
public:
    static ConnectionStore *create(QQmlEngine *, QJSEngine *);
    static ConnectionStore &instance();

    QString lastUpsertedId() const { return m_lastUpsertedId; }

    /**
     * QML 友好的新增/更新接口。
     * @param id 空字符串表示新建
     * @param password 空字符串表示不修改已存密码
     * @return 成功返回连接 id，失败返回空字符串
     */
    Q_INVOKABLE QString upsertFromQml(const QString &id, const QString &name, const QString &type,
                                      const QVariantMap &config, const QString &mountPoint,
                                      bool enabled, const QString &password);

    Q_INVOKABLE bool removeById(const QString &id) { return remove(id); }
    Q_INVOKABLE bool setEnabledById(const QString &id, bool enabled)
    {
        return setEnabled(id, enabled);
    }

    /// 必须在数据库就绪后调用（否则冷启动读到空列表）
    void load();
    bool isLoaded() const { return m_loaded; }

    QList<ConnectionRecord> connections() const { return m_records; }
    ConnectionRecord byId(const QString &id) const;
    int indexOf(const QString &id) const;

    /// 新增或更新；成功返回 true。密码非空时写入系统凭据库
    bool upsert(const ConnectionRecord &record, const QString &password = QString());

    /// 删除连接源（同时清除凭据与该连接的目录缓存）
    bool remove(const QString &id);

    bool setEnabled(const QString &id, bool enabled);

    /**
     * 获取或创建适配器（按连接 id 缓存复用，避免重复竞速）。
     * 返回的指针由 Store 持有，调用方不得 delete。
     */
    StorageAdapter *adapterFor(const QString &id, StorageError *error = nullptr);

    /// 配置变更后丢弃缓存的适配器（下次使用时重建）
    void invalidateAdapter(const QString &id);

    // ---- 连接测试 ----
    /**
     * 手动测试连接（清锁重判）。结果写入持久化缓存并广播。
     * @param passwordOverride 表单未保存时的密码
     */
    Q_INVOKABLE void testConnection(const QString &id, const QString &passwordOverride = QString());

    /// 应用启动时对全部启用的连接源做一次探测（§2.2.4 启动流程）
    void probeAllOnStartup();

    /// 读取持久化的测试状态：{ reachable, scope, message, at }
    Q_INVOKABLE QVariantMap testState(const QString &id) const;

    /// 是否正在测试（UI 显示转圈）
    Q_INVOKABLE bool isTesting(const QString &id) const;

signals:
    void loadedChanged();
    /// 列表结构变化（新增/删除/启用状态）
    void connectionsChanged();
    /// 单个连接的测试状态变化 —— 浏览页与设置页同时刷新
    void testStateChanged(const QString &id);
    void testStarted(const QString &id);

private:
    explicit ConnectionStore(QObject *parent = nullptr);
    ~ConnectionStore() override;
    Q_DISABLE_COPY_MOVE(ConnectionStore)

    void applyTestResult(const QString &id, const StorageError &error,
                         const ConnectionRecord &record);

    QList<ConnectionRecord> m_records;
    QHash<QString, StorageAdapter *> m_adapters;
    QHash<QString, bool> m_testing;
    QString m_lastUpsertedId;
    bool m_loaded = false;
};

} // namespace myhub
