#pragma once

#include "CachePartition.h"

#include <QList>
#include <QMutex>
#include <QSet>
#include <QString>

namespace myhub {

/**
 * 缓存容量治理（需求文档 §5.5）：分区配额 + 跨分区全局兜底 + 文件粒度 LRU。
 *
 * 纪律：
 *   - 淘汰依据是 **mtime**（命中时 `touch` 刷新），不是 atime：Linux 的 atime 常被挂载
 *     选项关掉，Windows 的 lastAccess 要一小时后才落盘，两者都不能当 LRU 时钟
 *   - 先按分区配额压，再按全局上限兜底；两次都压到 **90%**，避免贴着上限反复抖动
 *   - `.part` 半截文件优先淘汰（下载中断的残骸），但**正在下载**的由调用方放进保护集
 *   - `selfManaged` 分区（音视频分片）只统计不代删，它的淘汰要看播放点
 *   - 扫描是阻塞 IO，只在后台线程用；`enforce()` 自身加锁，多入口共用也安全
 */
class CacheStore
{
public:
    struct Entry
    {
        QString path;
        qint64 bytes = 0;
        qint64 mtimeMs = 0;
        bool partial = false; ///< `.part` 之类的半截文件：最先淘汰
        bool gone = false;    ///< 已删除：统计时跳过
    };

    struct PartitionUsage
    {
        QString dir;
        QString label;
        qint64 bytes = 0;
        int files = 0;
        qint64 limitBytes = 0;
        bool selfManaged = false;
    };

    struct Scan
    {
        QList<PartitionUsage> partitions;
        qint64 totalBytes = 0;
        int totalFiles = 0;
    };

    struct Result
    {
        Scan before;
        Scan after;
        int removedFiles = 0;
        qint64 removedBytes = 0;
    };

    /// @param partitions 分区表覆盖（空 = 用 `CachePartitions::all()`；测试用小配额）
    explicit CacheStore(QString rootDir, qint64 totalLimitBytes,
                        QList<CachePartition> partitions = QList<CachePartition>());

    QString rootDir() const { return m_rootDir; }
    qint64 totalLimitBytes() const { return m_totalLimitBytes; }

    /// 设置页改上限后立即生效：下一次 `enforce()` 就按新上限收口
    void setTotalLimitBytes(qint64 bytes);

    /// 只统计不删（设置页 / 日志用）
    Scan scan() const;

    /**
     * 执行容量约束。
     * @param protectedPrefixes 路径前缀：**正在使用的文件或目录**，一律不删
     */
    Result enforce(const QSet<QString> &protectedPrefixes = QSet<QString>());

    /**
     * 手工清空（设置页「单项清理 / 全部清理」）。
     * @param dir 分区目录名；**空串 = 清空全部已登记的与未登记的一级目录**
     * @param protectedPrefixes 正在播放 / 正在下载的前缀，一律保留
     *
     * 与 `enforce()` 的区别：不看配额，直接删；删完顺手清掉空子目录
     * （漫画整包、音视频分片都是一文件一子目录，留着空壳会让设置页看着像没清干净）。
     */
    Result purge(const QString &dir, const QSet<QString> &protectedPrefixes = QSet<QString>());

    /// 命中缓存时刷新 mtime（LRU 依据）；失败静默
    static bool touch(const QString &filePath);

private:
    struct Bucket
    {
        QString dir;
        QString label;
        qint64 limitBytes = 0;
        bool selfManaged = false;
        QList<Entry> files;
        qint64 bytes = 0;
    };

    QList<Bucket> collect() const;
    static Scan summarize(const QList<Bucket> &buckets);
    static bool isProtected(const QString &path, const QSet<QString> &prefixes);
    /// LRU 顺序删到 `targetBytes` 以内（含 90% 余量由调用方给），返回释放的字节数
    static qint64 evictTo(Bucket &bucket, qint64 targetBytes, const QSet<QString> &prefixes,
                          int *removedFiles);

    QString m_rootDir;
    qint64 m_totalLimitBytes = 0;
    QList<CachePartition> m_partitions;
    mutable QMutex m_mutex;
};

} // namespace myhub
