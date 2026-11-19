#pragma once

#include "core/cache/CacheStore.h"

#include <QFutureWatcher>
#include <QObject>
#include <QQmlEngine>
#include <QVariantList>

namespace myhub {

/**
 * 设置页「缓存与存储」的 QML 门面（§10 / PC-504）。
 *
 * 纪律：
 *   - 扫盘与清空都是**阻塞 IO**，一律丢到线程池，UI 线程只收结果
 *   - 同一时刻只跑一个扫描 / 一个清空；期间的重复请求合并成一次补跑
 *   - 清空**不看配额**，但尊重 `CacheCleaner` 的保护前缀（正在播放的分片、
 *     正在下载的 `.part`），否则用户点一下「清理」就把正在播的视频删了
 *   - 分区表来自 `CachePartitions`，这里不重复定义任何目录名
 */
class CacheBridge : public QObject
{
    Q_OBJECT
    QML_NAMED_ELEMENT(Cache)
    QML_SINGLETON

    /// 分区占用（每项：dir / label / bytes / files / limitBytes / selfManaged / ratio）
    Q_PROPERTY(QVariantList partitions READ partitions NOTIFY usageChanged)
    Q_PROPERTY(qint64 totalBytes READ totalBytes NOTIFY usageChanged)
    Q_PROPERTY(int totalFiles READ totalFiles NOTIFY usageChanged)
    Q_PROPERTY(qint64 totalLimitBytes READ totalLimitBytes NOTIFY usageChanged)
    /// 扫描进行中
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    /// 清空进行中（与 loading 分开：清空时禁用按钮文案要不同）
    Q_PROPERTY(bool clearing READ clearing NOTIFY clearingChanged)

public:
    /// 默认参数不是装饰：`QML_SINGLETON` 没给 create() 时引擎要默认构造，
    /// 少了它类型会被注册成「编译期单例、运行期不是单例」，QML 里一律 undefined
    explicit CacheBridge(QObject *parent = nullptr);

    QVariantList partitions() const { return m_partitions; }
    qint64 totalBytes() const { return m_totalBytes; }
    int totalFiles() const { return m_totalFiles; }
    qint64 totalLimitBytes() const { return m_totalLimitBytes; }
    bool loading() const { return m_scanWatcher != nullptr; }
    bool clearing() const { return m_purgeWatcher != nullptr; }

    /// 重新统计（设置页切到本分区时调用；清空完成后自动调用）
    Q_INVOKABLE void refresh();

    /// 清空一个分区（`dir` 为空 = 全部）
    Q_INVOKABLE void clearPartition(const QString &dir);
    Q_INVOKABLE void clearAll();

signals:
    void usageChanged();
    void loadingChanged();
    void clearingChanged();

    /// 清空完成：label 是给提示用的分区名（全部清理时为「全部」）
    void cleared(const QString &label, int removedFiles, qint64 removedBytes);

private:
    void applyScan(const CacheStore::Scan &scan);
    void startScan();

    QVariantList m_partitions;
    qint64 m_totalBytes = 0;
    int m_totalFiles = 0;
    qint64 m_totalLimitBytes = 0;

    QFutureWatcher<CacheStore::Scan> *m_scanWatcher = nullptr;
    QFutureWatcher<CacheStore::Result> *m_purgeWatcher = nullptr;
    /// 扫描期间又收到刷新请求：结束后补跑一次（不丢）
    bool m_scanPending = false;
};

} // namespace myhub
