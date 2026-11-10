#pragma once

#include "RangeSource.h"

#include <QByteArray>
#include <QHash>
#include <QList>
#include <QSet>
#include <QString>
#include <QVariantMap>

#include <functional>

namespace myhub {

class SegmentCache;

/**
 * 分片装配 + 请求合并 + 低优先级预读（§4.2）。
 *
 * 播放器（经回环代理）只会顺序/跳跃地要字节，本类负责把「连续字节请求」
 * 翻译成「整分片读取 + 缓存」，并保证：
 *
 *   - **in-flight 去重**：同一分片同时被多个请求（含预读）需要时只发一次源请求，
 *     结果回调给全部等待者。播放器 seek 后常出现「需求重叠」，不去重会把带宽翻倍。
 *   - **并发上限**：默认 3 个源请求在途；请求优先于预读，预读只在空闲槽位发出。
 *   - **预读窗口**：按 `preloadSeconds` 换算的分片数（上层算好传进来），
 *     只往前读、不回头补，避免和播放头抢带宽。
 *   - **会话注销立即失效**：`cancelAll()` 之后排队中的预读/去重请求一律不再发出，
 *     否则连续切换视频会残留上一部的请求把新视频拖慢（实测 4K 源下非常明显）。
 *   - **离线模式**：未命中区间直接失败，不重试、不预读（离线时重试只会拖长白屏）。
 */
class CachedRangeReader : public QObject
{
    Q_OBJECT
public:
    using Callback = std::function<void(QByteArray data, StorageError error)>;

    /// source / cache 均不接管所有权，且必须与本源同线程
    CachedRangeReader(RangeSource *source, SegmentCache *cache, QString cacheKey,
                      QObject *parent = nullptr);
    ~CachedRangeReader() override;

    qint64 size() const;

    /**
     * 无源（离线起播）时的总长度。
     * 只在 source 为空或 source 长度未知时生效，用于给回环代理回 Content-Length；
     * 有 source 时始终以 source 为准，避免缓存里的旧长度盖掉真实长度。
     */
    void setDeclaredSize(qint64 bytes);

    void setPrefetchSegments(int segments);
    int prefetchSegments() const { return m_prefetchSegments; }

    void setMaxConcurrent(int maxConcurrent);
    int maxConcurrent() const { return m_maxConcurrent; }

    void setOfflineMode(bool offline);
    bool offlineMode() const { return m_offlineMode; }

    /// 读取 `[start, start + length)`
    void read(qint64 start, qint64 length, Callback cb);

    /// 会话注销：丢弃排队任务，在途结果不再回调（但已到手的字节仍写缓存）
    void cancelAll();
    bool canceled() const { return m_canceled; }

    /// 诊断快照（设置 → 关于 / 日志）
    QVariantMap stats() const;

signals:
    /// 从源新抓到的字节数（不含缓存命中）
    void bytesFetched(qint64 bytes);

private:
    struct Request
    {
        quint64 id = 0;
        qint64 start = 0;
        qint64 length = 0;
        Callback cb;
    };

    struct Job
    {
        int index = -1;
        bool prefetch = false;
        bool inFlight = false;
    };

    int segmentBytes() const;
    int indexFor(qint64 offset) const;
    qint64 startOf(int index) const;
    int lastIndexFor(qint64 start, qint64 length) const;

    bool segmentAvailable(int index) const;
    QByteArray segmentData(int index);
    bool requestNeeds(quint64 id, int index) const;
    void ensureJob(int index, bool prefetch);
    void pump();
    void startJob(int index);
    void onSegmentFetched(int index, const QByteArray &data, const StorageError &error);
    void tryComplete(quint64 id);
    void failRequest(quint64 id, const StorageError &error);
    void schedulePrefetch(int fromIndex);
    void dropStalePrefetch();
    void rememberHot(int index, const QByteArray &data);

    RangeSource *m_source = nullptr;
    SegmentCache *m_cache = nullptr;
    QString m_key;
    qint64 m_declaredSize = -1;

    QHash<quint64, Request> m_requests;
    QHash<int, Job> m_jobs;
    QList<int> m_queue; ///< 待发起的索引（请求优先，预读在后）
    QHash<int, QByteArray> m_hot;
    QList<int> m_hotOrder;

    quint64 m_nextId = 0;
    int m_active = 0;
    int m_maxConcurrent = 3;
    int m_prefetchSegments = 0;
    bool m_offlineMode = false;
    bool m_canceled = false;

    qint64 m_fetchedBytes = 0;
    qint64 m_cacheHits = 0;
    int m_sourceRequests = 0;
    int m_deduped = 0;
};

} // namespace myhub
