#pragma once

#include "CacheStore.h"

#include <QDateTime>
#include <QMutex>
#include <QObject>
#include <QSet>
#include <QString>

#include <memory>

namespace myhub {

/**
 * 缓存清理的调度层：把阻塞的磁盘扫描丢到线程池，并节流合并请求。
 *
 * 触发点有两类：
 *   - **启动预热**（`AppState::continueBoot`）：首屏渲染后跑一次全局兜底，
 *     上次异常退出 / 设置改小留下的超额缓存在这里收口
 *   - **写入后请求**（漫画页、缩略图、目录列表）：走 `requestCleanup()`，
 *     60 秒内只真跑一次——每写一个文件就全盘扫一遍是不划算的
 *
 * 纪律：`enforce()` 是阻塞 IO，**只能在后台线程**；本类保证同一时刻只有一个任务在跑，
 * 期间到来的请求合并成一次补跑（不丢）。
 */
class CacheCleaner : public QObject
{
    Q_OBJECT
public:
    static CacheCleaner &instance();

    /// 建引擎并触发一次启动清理（主线程调用，内部立刻返回）
    void initialize();

    /// 请求一次清理（任意线程可调，节流 60 秒）
    void requestCleanup();

    /// 设置页改了 `cache.totalLimitMB`：换配额并立刻安排一次收口
    void applyTotalLimit();

    /// 手工清空分区（空 = 全部）。**阻塞 IO**，只能在后台线程调用
    CacheStore::Result purge(const QString &dir);

    /// 保护/解除保护（路径前缀匹配）：正在下载的 `.part`、正在播放的分片目录
    void protect(const QString &prefix);
    void unprotect(const QString &prefix);

    /// 当前占用快照（阻塞 IO，调用方自行保证不在 UI 线程）
    CacheStore::Scan snapshot() const;
    qint64 totalLimitBytes() const;

    /// 是否已初始化（测试 / 未装好设置时用来跳过）
    bool ready() const { return m_store != nullptr; }

signals:
    void cleaned(qint64 bytesBefore, qint64 bytesAfter, int removedFiles);

private:
    explicit CacheCleaner(QObject *parent = nullptr);

    void schedule(bool force);
    void start();

    std::unique_ptr<CacheStore> m_store;
    mutable QMutex m_protectMutex;
    QSet<QString> m_protected;
    bool m_running = false;
    bool m_pending = false;
    QDateTime m_lastFinished;
};

} // namespace myhub
