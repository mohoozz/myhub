#pragma once

#include <QObject>
#include <QString>
#include <QVariantList>
#include <QVariantMap>

struct sqlite3;

namespace myhub {

/**
 * SQLite 封装（PC-002）。
 *
 * 直接使用 sqlite3 C API 而非 Qt SQL（需求文档 §4.1）：
 *   - 绕开 Qt SQL 驱动插件的分发问题
 *   - 与 iOS 端 GRDB 的 Schema 同构，迁移脚本可对照复用
 *
 * 线程约定：本类自带互斥，可跨线程调用；但长事务应尽量在 worker 线程执行。
 */
class AppDatabase : public QObject
{
    Q_OBJECT
public:
    static AppDatabase &instance();

    /// 打开数据库并执行版本化迁移；返回是否就绪
    bool open(const QString &filePath = QString());
    void close();
    bool isOpen() const;

    /// 当前 schema 版本
    int schemaVersion() const;

    // ---- 基础执行接口 ----
    /// 执行无返回语句；失败时 lastError() 可取原因
    bool execute(const QString &sql, const QVariantList &params = {});

    /// 查询多行；每行为「列名 → 值」
    QList<QVariantMap> query(const QString &sql, const QVariantList &params = {}) const;

    /// 查询单值
    QVariant queryScalar(const QString &sql, const QVariantList &params = {}) const;

    qint64 lastInsertRowId() const;
    QString lastError() const;

    // ---- 事务 ----
    bool beginTransaction();
    bool commit();
    bool rollback();

    /**
     * 定期自动备份到 backup/（保留 7 份）。
     * 需求文档 §2.3：每日/每次启动备份一次。
     */
    bool backupIfNeeded();

    /// 立即备份（设置页手动触发）
    bool backupNow();

signals:
    /// 数据库就绪后发出；依赖数据库的 Store 必须等待此信号再装载
    /// （§8.3 PC-403：历史与快捷入口必须在 DB 就绪后装载，否则冷启动读到空列表）
    void ready();

private:
    explicit AppDatabase(QObject *parent = nullptr);
    ~AppDatabase() override;
    Q_DISABLE_COPY_MOVE(AppDatabase)

    void pruneBackups();

    struct Private;
    Private *d;

    friend class Migrations;
};

} // namespace myhub
