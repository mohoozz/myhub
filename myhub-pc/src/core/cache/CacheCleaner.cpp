#include "CacheCleaner.h"

#include "CachePartition.h"
#include "../preferences/AppSettings.h"
#include "../utils/AppLogger.h"
#include "../utils/AppPaths.h"

#include <QFutureWatcher>
#include <QMutexLocker>
#include <QtConcurrent/QtConcurrentRun>

namespace myhub {

namespace {
/// 写缓存后触发的清理最短间隔：一次全盘扫描顶几十次写入，没必要每次都跑
constexpr qint64 kMinIntervalMs = 60LL * 1000;
} // namespace

CacheCleaner::CacheCleaner(QObject *parent)
    : QObject(parent)
{}

CacheCleaner &CacheCleaner::instance()
{
    static CacheCleaner s_instance;
    return s_instance;
}

void CacheCleaner::initialize()
{
    if (m_store) {
        return;
    }
    AppPaths::ensureDir(AppPaths::cacheDir());
    m_store =
        std::make_unique<CacheStore>(AppPaths::cacheDir(), CachePartitions::totalLimitBytes());

    // 设置页改上限 → 配额立即跟着换（AppSettings 是纯逻辑层的 QObject，信号可直连）
    connect(&AppSettings::instance(), &AppSettings::cacheTotalLimitMBChanged, this,
            &CacheCleaner::applyTotalLimit);

    // 启动预热：调用点在 `AppState::continueBoot`（首屏之后），这里只负责丢到后台
    schedule(/*force=*/true);
}

void CacheCleaner::applyTotalLimit()
{
    if (!m_store) {
        return;
    }
    m_store->setTotalLimitBytes(CachePartitions::totalLimitBytes());
    // 不 force：拖滑块会连续触发，节流后最多 60 秒收口一次；上限本身已即时生效
    schedule(/*force=*/false);
}

CacheStore::Result CacheCleaner::purge(const QString &dir)
{
    if (!m_store) {
        return {};
    }
    QSet<QString> prefixes;
    {
        QMutexLocker lock(&m_protectMutex);
        prefixes = m_protected;
    }
    return m_store->purge(dir, prefixes);
}

void CacheCleaner::requestCleanup()
{
    // 写缓存可能发生在工作线程，统一投递回主线程，避免 QFutureWatcher 跨线程
    QMetaObject::invokeMethod(this, [this] { schedule(false); }, Qt::QueuedConnection);
}

void CacheCleaner::protect(const QString &prefix)
{
    if (prefix.isEmpty()) {
        return;
    }
    QMutexLocker lock(&m_protectMutex);
    m_protected.insert(prefix);
}

void CacheCleaner::unprotect(const QString &prefix)
{
    QMutexLocker lock(&m_protectMutex);
    m_protected.remove(prefix);
}

CacheStore::Scan CacheCleaner::snapshot() const
{
    return m_store ? m_store->scan() : CacheStore::Scan{};
}

qint64 CacheCleaner::totalLimitBytes() const
{
    return m_store ? m_store->totalLimitBytes() : CachePartitions::totalLimitBytes();
}

void CacheCleaner::schedule(bool force)
{
    if (!m_store) {
        return;
    }
    if (m_running) {
        // 正在跑：合并成一次补跑，别丢掉这次请求
        m_pending = true;
        return;
    }
    if (!force && m_lastFinished.isValid()
        && m_lastFinished.msecsTo(QDateTime::currentDateTime()) < kMinIntervalMs) {
        return;
    }
    start();
}

void CacheCleaner::start()
{
    m_running = true;
    m_pending = false;

    QSet<QString> prefixes;
    {
        QMutexLocker lock(&m_protectMutex);
        prefixes = m_protected;
    }

    CacheStore *store = m_store.get();
    auto *watcher = new QFutureWatcher<CacheStore::Result>(this);
    connect(watcher, &QFutureWatcher<CacheStore::Result>::finished, this, [this, watcher] {
        const CacheStore::Result result = watcher->result();
        watcher->deleteLater();
        m_running = false;
        m_lastFinished = QDateTime::currentDateTime();
        MH_INFO(Cache,
                QStringLiteral("清理完成：%1 -> %2 字节（删除 %3 个文件，%4 字节）")
                    .arg(result.before.totalBytes)
                    .arg(result.after.totalBytes)
                    .arg(result.removedFiles)
                    .arg(result.removedBytes));
        emit cleaned(result.before.totalBytes, result.after.totalBytes, result.removedFiles);
        if (m_pending) {
            schedule(false);
        }
    });
    watcher->setFuture(QtConcurrent::run([store, prefixes] { return store->enforce(prefixes); }));
}

} // namespace myhub
