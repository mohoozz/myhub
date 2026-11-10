#include "PlaybackStreamService.h"

#include "core/preferences/AppSettings.h"
#include "core/storage/RoutedWebDAVAdapter.h"
#include "core/storage/StorageAdapter.h"
#include "core/stream/AdapterRangeSource.h"
#include "core/stream/CachedRangeReader.h"
#include "core/stream/SegmentCache.h"
#include "core/utils/AppLogger.h"
#include "core/utils/AppPaths.h"
#include "features/connections/ConnectionStore.h"

#include <QFileInfo>
#include <QPointer>
#include <QStringList>

namespace myhub {

namespace {

constexpr int kSegmentBytes = 1024 * 1024;
constexpr int kMaxConcurrentReads = 3;
/// 预读上限：即使 preloadSeconds 给得很大，也不会一次把整部 4K 拉下来
constexpr int kMaxPrefetchSegments = 16;

QString displayFileName(const QString &path, const QString &displayName)
{
    if (!displayName.trimmed().isEmpty())
        return displayName;
    const QString name = QFileInfo(path).fileName();
    return name.isEmpty() ? QStringLiteral("stream") : name;
}

} // namespace

PlaybackStreamService &PlaybackStreamService::instance()
{
    static PlaybackStreamService service;
    return service;
}

PlaybackStreamService::PlaybackStreamService()
    : m_proxy(std::make_unique<LocalStreamProxy>())
{
    SegmentCache::Config config;
    config.rootDir = AppPaths::cachePartition(QStringLiteral("stream"));
    config.segmentBytes = kSegmentBytes;
    config.totalLimitBytes =
        qint64(qMax(128, AppSettings::instance().cacheTotalLimitMB())) * 1024 * 1024;
    m_cache = std::make_unique<SegmentCache>(config);

    connect(m_proxy.get(), &LocalStreamProxy::listenerRebuilt, this,
            &PlaybackStreamService::onListenerRebuilt);
    // 不在构造期起监听：真起播时 prepare() 再 start(0)，
    // 免得上层把「启动期首次监听」误当成「换端口重建」而重开播放
}

PlaybackStreamService::~PlaybackStreamService() = default;

PlaybackStreamService::Prepared
PlaybackStreamService::prepare(const QString &connectionId, const QString &path,
                               const QString &displayName, qint64 size, const QString &fingerprint)
{
    Prepared out;
    if (connectionId.isEmpty() || path.isEmpty()) {
        out.error = tr("缺少连接源或文件路径");
        return out;
    }
    if (size <= 0) {
        out.error = tr("无法获取文件大小，暂不支持边下边播");
        return out;
    }

    if (!m_proxy->isRunning() && !m_proxy->start(0)) {
        out.error = tr("本地代流服务启动失败（端口被占用）");
        return out;
    }

    StorageError error;
    StorageAdapter *adapter = ConnectionStore::instance().adapterFor(connectionId, &error);
    if (!adapter) {
        // 连接源不可用 → 离线兜底：只播「缓存已完整」的文件，半截缓存宁可报错
        return prepareOffline(connectionId, path, displayName,
                              error.message().isEmpty() ? QString() : error.message());
    }

    // 缓存总量随设置变化：重建索引，最坏只是下次重新扫目录
    const qint64 limitBytes =
        qint64(qMax(128, AppSettings::instance().cacheTotalLimitMB())) * 1024 * 1024;
    if (m_cache->config().totalLimitBytes != limitBytes) {
        SegmentCache::Config config = m_cache->config();
        config.totalLimitBytes = limitBytes;
        m_cache = std::make_unique<SegmentCache>(config);
    }

    const QString effectiveFingerprint =
        fingerprint.isEmpty() ? QStringLiteral("%1").arg(size) : fingerprint;
    const QString key = SegmentCache::keyFor(connectionId, path, effectiveFingerprint);

    // 同一文件的旧会话先注销：避免两条管线同时拉流
    releaseByKey(key);

    auto *source = new AdapterRangeSource(adapter, path, size, this);
    if (auto *routed = qobject_cast<RoutedWebDAVAdapter *>(adapter)) {
        // 内外网竞速锁错地址时，连续零进展要能让下一块重新选路
        source->setInvalidateRoute([routed]() { routed->invalidateRoute(); });
    }

    auto *reader = new CachedRangeReader(source, m_cache.get(), key, this);
    const int preloadSeconds =
        AppSettings::instance().value(QStringLiteral("player.preloadSeconds"), 30).toInt();
    reader->setPrefetchSegments(qBound(2, preloadSeconds, kMaxPrefetchSegments));
    reader->setMaxConcurrent(kMaxConcurrentReads);

    Session session;
    session.key = key;
    session.fileName = displayFileName(path, displayName);
    session.size = size;
    session.source = source;
    session.reader = reader;

    const QString streamId = QStringLiteral("%1-%2").arg(key).arg(++m_seq);
    m_sessions.insert(streamId, session);

    out.streamId = streamId;
    out.url = registerStream(streamId);
    if (!out.url.isValid()) {
        release(streamId);
        out.error = tr("本地代流服务未就绪");
        return out;
    }

    m_activeStream = streamId;

    // 缓存身份：断网后凭它反查（findCachedIdentity）仍可起播已完整缓存的文件
    QVariantMap meta;
    meta.insert(QStringLiteral("connectionId"), connectionId);
    meta.insert(QStringLiteral("path"), path);
    meta.insert(QStringLiteral("name"), session.fileName);
    meta.insert(QStringLiteral("size"), size);
    meta.insert(QStringLiteral("fingerprint"), effectiveFingerprint);
    m_cache->writeMeta(key, meta);

    MH_INFO(
        Stream,
        QStringLiteral("边下边播会话建立：%1（%2 字节，缓存键 %3）").arg(path).arg(size).arg(key));
    return out;
}

PlaybackStreamService::Prepared PlaybackStreamService::prepareOffline(const QString &connectionId,
                                                                      const QString &path,
                                                                      const QString &displayName,
                                                                      const QString &reason)
{
    Prepared out;

    QVariantMap meta;
    if (!m_cache->findCachedIdentity(connectionId, path, &meta)) {
        out.error = reason.isEmpty() ? tr("连接源当前不可用，且本地没有该文件的缓存") : reason;
        return out;
    }

    const QString key = meta.value(QStringLiteral("key")).toString();
    const qint64 size = meta.value(QStringLiteral("size")).toLongLong();
    const int segmentBytes = m_cache->segmentBytes();
    const int expected = (segmentBytes > 0 && size > 0)
        ? static_cast<int>((size + segmentBytes - 1) / segmentBytes)
        : 0;

    // 优先用缓存里记的文件名（离线时它比调用方更可信，调用方可能只给了路径）
    const QString cachedName = meta.value(QStringLiteral("name")).toString();
    const QString fileName = displayFileName(path, cachedName.isEmpty() ? displayName : cachedName);
    if (expected <= 0 || m_cache->segmentCount(key) < expected) {
        // 半截缓存播下去只会中途卡死，起播前就说清楚
        out.error = tr("连接源当前不可用，且「%1」的缓存不完整").arg(fileName);
        return out;
    }

    releaseByKey(key);

    // 没有源可读：只跑缓存分支（offlineMode 下缺片直接失败、也不预读）
    auto *reader = new CachedRangeReader(nullptr, m_cache.get(), key, this);
    reader->setDeclaredSize(size);
    reader->setOfflineMode(true);

    Session session;
    session.key = key;
    session.fileName = fileName;
    session.size = size;
    session.reader = reader;

    const QString streamId = QStringLiteral("%1-%2").arg(key).arg(++m_seq);
    m_sessions.insert(streamId, session);

    out.streamId = streamId;
    out.url = registerStream(streamId);
    if (!out.url.isValid()) {
        release(streamId);
        out.error = tr("本地代流服务未就绪");
        return out;
    }

    m_activeStream = streamId;
    MH_INFO(Stream,
            QStringLiteral("离线起播（缓存完整）：%1（%2 字节，缓存键 %3）")
                .arg(path)
                .arg(size)
                .arg(key));
    return out;
}

void PlaybackStreamService::releaseByKey(const QString &key)
{
    QStringList stale;
    for (auto it = m_sessions.constBegin(); it != m_sessions.constEnd(); ++it) {
        if (it->key == key)
            stale.append(it.key());
    }
    for (const QString &id : stale)
        release(id);
}

void PlaybackStreamService::release(const QString &streamId)
{
    const auto it = m_sessions.find(streamId);
    if (it == m_sessions.end())
        return;

    if (it->reader) {
        it->reader->cancelAll();
        it->reader->deleteLater();
    }
    if (it->source)
        it->source->deleteLater();

    m_proxy->unregisterStream(streamId);
    m_sessions.erase(it);

    if (m_activeStream == streamId)
        m_activeStream.clear();
}

void PlaybackStreamService::releaseAll()
{
    const QStringList ids = m_sessions.keys();
    for (const QString &id : ids)
        release(id);
}

QUrl PlaybackStreamService::registerStream(const QString &streamId)
{
    const auto it = m_sessions.constFind(streamId);
    if (it == m_sessions.constEnd() || !it->reader)
        return {};

    // 会话可能比连接活得短（切视频时立即注销），用 QPointer 兜住
    QPointer<CachedRangeReader> guard(it->reader);
    LocalStreamProxy::Stream stream;
    stream.size = it->size;
    stream.fileName = it->fileName;
    stream.read = [guard](qint64 start, qint64 length, LocalStreamProxy::ReadCallback cb) {
        if (!guard) {
            cb({}, StorageError(StorageError::Cancelled, QStringLiteral("播放会话已结束")));
            return;
        }
        guard->read(start, length, std::move(cb));
    };

    return QUrl(m_proxy->registerStream(streamId, std::move(stream)));
}

void PlaybackStreamService::onListenerRebuilt(quint16 oldPort, quint16 newPort)
{
    Q_UNUSED(oldPort)
    Q_UNUSED(newPort)

    const QStringList ids = m_sessions.keys();
    for (const QString &id : ids) {
        const QUrl url = registerStream(id);
        if (url.isValid())
            emit streamUrlRebuilt(id, url);
    }
}

QVariantMap PlaybackStreamService::snapshot() const
{
    QVariantMap result = m_proxy->healthSnapshot();
    result.insert(QStringLiteral("sessions"), m_sessions.size());
    result.insert(QStringLiteral("activeStream"), m_activeStream);
    result.insert(QStringLiteral("cache"), m_cache->stats());
    if (!m_activeStream.isEmpty()) {
        const auto it = m_sessions.constFind(m_activeStream);
        if (it != m_sessions.constEnd() && it->reader)
            result.insert(QStringLiteral("reader"), it->reader->stats());
    }
    return result;
}

} // namespace myhub
