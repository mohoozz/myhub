#include "CachedRangeReader.h"

#include "SegmentCache.h"

namespace myhub {

namespace {
constexpr int kHotSegments = 8;
}

CachedRangeReader::CachedRangeReader(RangeSource *source, SegmentCache *cache, QString cacheKey,
                                     QObject *parent)
    : QObject(parent)
    , m_source(source)
    , m_cache(cache)
    , m_key(std::move(cacheKey))
{}

CachedRangeReader::~CachedRangeReader() = default;

qint64 CachedRangeReader::size() const
{
    if (m_source && m_source->size() > 0)
        return m_source->size();
    return m_declaredSize;
}

void CachedRangeReader::setDeclaredSize(qint64 bytes)
{
    m_declaredSize = bytes > 0 ? bytes : -1;
}

void CachedRangeReader::setPrefetchSegments(int segments)
{
    m_prefetchSegments = qMax(0, segments);
}

void CachedRangeReader::setMaxConcurrent(int maxConcurrent)
{
    m_maxConcurrent = qBound(1, maxConcurrent, 8);
}

void CachedRangeReader::setOfflineMode(bool offline)
{
    m_offlineMode = offline;
}

int CachedRangeReader::segmentBytes() const
{
    return m_cache ? m_cache->segmentBytes() : 0;
}

int CachedRangeReader::indexFor(qint64 offset) const
{
    const int bytes = segmentBytes();
    if (bytes <= 0)
        return 0;
    return static_cast<int>(qMax<qint64>(0, offset) / bytes);
}

qint64 CachedRangeReader::startOf(int index) const
{
    return static_cast<qint64>(index) * segmentBytes();
}

int CachedRangeReader::lastIndexFor(qint64 start, qint64 length) const
{
    return indexFor(start + qMax<qint64>(0, length - 1));
}

bool CachedRangeReader::segmentAvailable(int index) const
{
    if (m_hot.contains(index))
        return true;
    return m_cache && m_cache->contains(m_key, index);
}

QByteArray CachedRangeReader::segmentData(int index)
{
    if (auto it = m_hot.constFind(index); it != m_hot.constEnd()) {
        ++m_cacheHits;
        return it.value();
    }
    if (!m_cache)
        return {};
    const QByteArray data = m_cache->readSegment(m_key, index);
    if (!data.isEmpty()) {
        ++m_cacheHits;
        rememberHot(index, data);
    }
    return data;
}

void CachedRangeReader::rememberHot(int index, const QByteArray &data)
{
    if (!m_hot.contains(index))
        m_hotOrder.append(index);
    m_hot.insert(index, data);
    while (m_hotOrder.size() > kHotSegments) {
        const int victim = m_hotOrder.takeFirst();
        m_hot.remove(victim);
    }
}

void CachedRangeReader::read(qint64 start, qint64 length, Callback cb)
{
    if (!cb)
        return;

    if (m_canceled) {
        cb({}, StorageError(StorageError::Cancelled, QStringLiteral("播放会话已结束")));
        return;
    }
    if (start < 0 || length <= 0) {
        cb({}, StorageError(StorageError::InvalidPath, QStringLiteral("非法的读取范围")));
        return;
    }

    const qint64 total = size();
    if (total >= 0) {
        if (start >= total) {
            cb({}, StorageError());
            return;
        }
        length = qMin(length, total - start);
    }

    const int first = indexFor(start);
    const int last = lastIndexFor(start, length);

    if (m_offlineMode) {
        for (int i = first; i <= last; ++i) {
            if (!segmentAvailable(i)) {
                cb({},
                   StorageError(StorageError::Offline,
                                QStringLiteral("离线模式下没有该区间的缓存")));
                return;
            }
        }
    }

    Request request;
    request.id = ++m_nextId;
    request.start = start;
    request.length = length;
    request.cb = std::move(cb);
    m_requests.insert(request.id, request);

    // seek 之后旧的预读窗口全部作废，避免往回预读抢带宽
    dropStalePrefetch();

    for (int i = first; i <= last; ++i) {
        if (!segmentAvailable(i))
            ensureJob(i, false);
    }

    if (m_cache)
        m_cache->setPlayhead(m_key, start);

    tryComplete(request.id);
    // 预读只从本次请求的尾部往前铺，不会因为「每读完一片再往前铺」而把整部文件拉下来
    schedulePrefetch(last);
    pump();
}

void CachedRangeReader::ensureJob(int index, bool prefetch)
{
    if (m_canceled || index < 0)
        return;
    // 离线：只吃缓存，排任务只会挂在无源的 startJob 上把请求拖死
    if (m_offlineMode)
        return;
    if (segmentAvailable(index))
        return;
    if (size() >= 0 && startOf(index) >= size())
        return;

    if (auto it = m_jobs.find(index); it != m_jobs.end()) {
        // 去重：已有任务在排队/在途，只提升优先级，不重复发请求
        ++m_deduped;
        if (!prefetch && it->prefetch)
            it->prefetch = false;
        return;
    }

    Job job;
    job.index = index;
    job.prefetch = prefetch;
    m_jobs.insert(index, job);
    m_queue.append(index);
}

bool CachedRangeReader::requestNeeds(quint64 id, int index) const
{
    const auto it = m_requests.constFind(id);
    if (it == m_requests.constEnd())
        return false;
    return indexFor(it->start) <= index && index <= lastIndexFor(it->start, it->length);
}

void CachedRangeReader::pump()
{
    if (m_canceled)
        return;

    // 先清理没人需要的请求型任务（请求失败后残留的排队项）
    for (int i = 0; i < m_queue.size();) {
        const int index = m_queue.at(i);
        const auto jobIt = m_jobs.find(index);
        if (jobIt == m_jobs.end()) {
            m_queue.removeAt(i);
            continue;
        }
        if (!jobIt->inFlight && !jobIt->prefetch) {
            bool needed = false;
            for (auto it = m_requests.constBegin(); it != m_requests.constEnd(); ++it) {
                if (requestNeeds(it.key(), index)) {
                    needed = true;
                    break;
                }
            }
            if (!needed) {
                m_jobs.erase(jobIt);
                m_queue.removeAt(i);
                continue;
            }
        }
        ++i;
    }

    while (m_active < m_maxConcurrent) {
        int pick = -1;
        for (int i = 0; i < m_queue.size(); ++i) {
            const int index = m_queue.at(i);
            const auto jobIt = m_jobs.find(index);
            if (jobIt == m_jobs.end() || jobIt->inFlight)
                continue;
            if (!jobIt->prefetch) {
                pick = i;
                break;
            }
            if (pick < 0)
                pick = i; // 预读候选：只在没有请求型任务时才用
        }
        if (pick < 0)
            break;
        startJob(m_queue.takeAt(pick));
    }
}

void CachedRangeReader::startJob(int index)
{
    auto it = m_jobs.find(index);
    if (it == m_jobs.end() || it->inFlight)
        return;
    if (!m_source) {
        m_jobs.erase(it);
        return;
    }

    it->inFlight = true;
    ++m_active;
    ++m_sourceRequests;

    qint64 length = segmentBytes();
    if (size() >= 0)
        length = qMin(length, size() - startOf(index));

    const qint64 start = startOf(index);
    m_source->readRange(start, length, [this, index](QByteArray data, StorageError error) {
        onSegmentFetched(index, data, error);
    });
}

void CachedRangeReader::onSegmentFetched(int index, const QByteArray &data,
                                         const StorageError &error)
{
    --m_active;

    const auto jobIt = m_jobs.find(index);
    if (jobIt != m_jobs.end())
        m_jobs.erase(jobIt);

    if (m_canceled) {
        // 会话已注销：结果直接丢弃，但已到手的字节仍落缓存，下次复用
        if (error.isNull() && !data.isEmpty() && m_cache)
            m_cache->writeSegment(m_key, index, data);
        return;
    }

    if (!error.isNull() || data.isEmpty()) {
        const StorageError failure = error.isNull()
            ? StorageError(StorageError::Offline, QStringLiteral("分片为空"))
            : error;
        const QList<quint64> ids = m_requests.keys();
        for (quint64 id : ids) {
            if (requestNeeds(id, index))
                failRequest(id, failure);
        }
        pump();
        return;
    }

    if (m_cache)
        m_cache->writeSegment(m_key, index, data);
    rememberHot(index, data);
    m_fetchedBytes += data.size();
    emit bytesFetched(data.size());

    // 该分片到手的请求继续装配；其余请求不受影响
    const QList<quint64> ids = m_requests.keys();
    for (quint64 id : ids)
        tryComplete(id);

    pump();
}

void CachedRangeReader::tryComplete(quint64 id)
{
    const auto it = m_requests.find(id);
    if (it == m_requests.end())
        return;

    const qint64 start = it->start;
    const qint64 length = it->length;
    const int first = indexFor(start);
    const int last = lastIndexFor(start, length);

    QByteArray out;
    out.reserve(static_cast<int>(qMin<qint64>(length, 4 * 1024 * 1024)));

    for (int i = first; i <= last; ++i) {
        if (!segmentAvailable(i))
            return; // 还缺分片，等后续回调
        const QByteArray segment = segmentData(i);
        if (segment.isEmpty())
            return;
        const qint64 segmentStart = startOf(i);
        const qint64 from = qMax<qint64>(0, start - segmentStart);
        const qint64 to = qMin<qint64>(segment.size(), start + length - segmentStart);
        if (to <= from)
            return;
        out.append(segment.constData() + from, static_cast<int>(to - from));
    }

    Callback cb = it->cb;
    m_requests.erase(it);
    cb(std::move(out), StorageError());
}

void CachedRangeReader::failRequest(quint64 id, const StorageError &error)
{
    const auto it = m_requests.find(id);
    if (it == m_requests.end())
        return;
    Callback cb = it->cb;
    m_requests.erase(it);
    cb({}, error);
}

void CachedRangeReader::schedulePrefetch(int fromIndex)
{
    if (m_canceled || m_offlineMode || m_prefetchSegments <= 0)
        return;

    for (int i = 1; i <= m_prefetchSegments; ++i) {
        const int index = fromIndex + i;
        if (size() >= 0 && startOf(index) >= size())
            break;
        ensureJob(index, true);
    }
}

void CachedRangeReader::dropStalePrefetch()
{
    for (auto it = m_jobs.begin(); it != m_jobs.end();) {
        if (it->prefetch && !it->inFlight)
            it = m_jobs.erase(it);
        else
            ++it;
    }

    m_queue.clear();
    for (auto it = m_jobs.constBegin(); it != m_jobs.constEnd(); ++it) {
        if (!it->inFlight)
            m_queue.append(it.key());
    }
}

void CachedRangeReader::cancelAll()
{
    if (m_canceled)
        return;
    m_canceled = true;

    m_queue.clear();
    m_jobs.clear();

    const QList<quint64> ids = m_requests.keys();
    for (quint64 id : ids)
        failRequest(id, StorageError(StorageError::Cancelled, QStringLiteral("播放会话已结束")));

    if (m_source)
        m_source->cancel();
}

QVariantMap CachedRangeReader::stats() const
{
    return QVariantMap{
        {QStringLiteral("key"), m_key},
        {QStringLiteral("requests"), m_requests.size()},
        {QStringLiteral("queued"), m_queue.size()},
        {QStringLiteral("active"), m_active},
        {QStringLiteral("maxConcurrent"), m_maxConcurrent},
        {QStringLiteral("prefetchSegments"), m_prefetchSegments},
        {QStringLiteral("offline"), m_offlineMode},
        {QStringLiteral("canceled"), m_canceled},
        {QStringLiteral("fetchedBytes"), m_fetchedBytes},
        {QStringLiteral("cacheHits"), m_cacheHits},
        {QStringLiteral("sourceRequests"), m_sourceRequests},
        {QStringLiteral("deduped"), m_deduped},
    };
}

} // namespace myhub
