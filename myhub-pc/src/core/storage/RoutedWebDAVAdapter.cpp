#include "RoutedWebDAVAdapter.h"
#include "../network/NetworkHeuristics.h"
#include "../utils/AppLogger.h"

#include <QPointer>
#include <QTimer>

namespace myhub {

namespace {
/// 外网延迟发车间隔（Happy Eyeballs），§14.9 要求竞速 ~700ms 完成
constexpr int kExternalDelayMs = 700;
/// 清锁冷却，避免网络抖动导致反复切换
constexpr int kLockCooldownMs = 8000;
} // namespace

RoutedWebDAVAdapter::RoutedWebDAVAdapter(WebDAVConfig config, QObject *parent)
    : StorageAdapter(parent)
    , m_config(std::move(config))
{
    m_adapter = new WebDAVAdapter(m_config, this);
    m_lockClearedAt.invalidate();
}

RoutedWebDAVAdapter::~RoutedWebDAVAdapter() = default;

bool RoutedWebDAVAdapter::canClearLock() const
{
    if (!m_lockClearedAt.isValid())
        return true;
    return m_lockClearedAt.elapsed() >= kLockCooldownMs;
}

void RoutedWebDAVAdapter::applyLock(const QString &url, bool isInternal)
{
    if (m_lockedURL == url)
        return;
    m_lockedURL = url;
    m_lockedIsInternal = isInternal;
    m_adapter->setActiveBaseURL(url);
    MH_INFO(NetworkRoute,
            QStringLiteral("route locked: %1 (%2)")
                .arg(url, isInternal ? QStringLiteral("internal") : QStringLiteral("external")));
    emit routeLocked(url, isInternal);
}

void RoutedWebDAVAdapter::invalidateRoute()
{
    if (m_lockedURL.isEmpty())
        return;
    MH_WARN(NetworkRoute, QStringLiteral("route lock invalidated (was %1)").arg(m_lockedURL));
    m_lockedURL.clear();
    m_lockedIsInternal = false;
    m_lockClearedAt.start();
}

void RoutedWebDAVAdapter::resolveRoute(std::function<void(const QString &, StorageError)> done)
{
    if (!m_lockedURL.isEmpty()) {
        done(m_lockedURL, StorageError());
        return;
    }

    // 无内网地址时无需竞速
    if (m_config.internalBaseURL.isEmpty()) {
        if (m_config.baseURL.isEmpty()) {
            done(QString(),
                 StorageError(StorageError::InvalidConfig, QStringLiteral("服务器地址为空")));
            return;
        }
        applyLock(m_config.baseURL, NetworkHeuristics::isPrivateHost(m_config.baseURL));
        done(m_lockedURL, StorageError());
        return;
    }

    m_pendingRace.append(std::move(done));
    if (!m_raceInFlight)
        startRace(nullptr);
}

void RoutedWebDAVAdapter::startRace(std::function<void(const QString &, StorageError)> done)
{
    if (done)
        m_pendingRace.append(std::move(done));

    m_raceInFlight = true;

    // 竞速状态在多个回调间共享
    struct RaceState
    {
        bool settled = false;
        int finished = 0;
        StorageError firstError;
        QElapsedTimer timer;
    };
    auto state = std::make_shared<RaceState>();
    state->timer.start();

    QPointer<RoutedWebDAVAdapter> self(this);

    auto settle = [self, state](const QString &url, bool isInternal, StorageError err) {
        if (!self || state->settled)
            return;

        if (err.isNull()) {
            state->settled = true;
            self->m_lastRaceMs = state->timer.elapsed();
            self->m_lastRaceWinner =
                isInternal ? QStringLiteral("internal") : QStringLiteral("external");
            self->applyLock(url, isInternal);

            auto pending = std::move(self->m_pendingRace);
            self->m_pendingRace.clear();
            self->m_raceInFlight = false;
            for (auto &cb : pending)
                cb(url, StorageError());
            return;
        }

        // 记录首个错误，两路都失败时回报
        if (state->firstError.isNull())
            state->firstError = err;

        if (++state->finished >= 2) {
            state->settled = true;
            self->m_raceInFlight = false;
            MH_WARN(
                NetworkRoute,
                QStringLiteral("race failed on both routes: %1").arg(state->firstError.message()));
            auto pending = std::move(self->m_pendingRace);
            self->m_pendingRace.clear();
            for (auto &cb : pending)
                cb(QString(), state->firstError);
        }
    };

    // 内网先发
    const QString internalURL = m_config.internalBaseURL;
    {
        WebDAVConfig c = m_config;
        c.baseURL = internalURL;
        auto *probe = new WebDAVAdapter(c, this);
        probe->testConnection([probe, settle, internalURL](StorageError err) {
            probe->deleteLater();
            settle(internalURL, true, err);
        });
    }

    // 外网延迟 ~700ms 并发兜底
    const QString externalURL = m_config.baseURL;
    if (!externalURL.isEmpty()) {
        QTimer::singleShot(kExternalDelayMs, this, [self, settle, externalURL, state]() {
            if (!self || state->settled)
                return;
            WebDAVConfig c = self->m_config;
            c.baseURL = externalURL;
            auto *probe = new WebDAVAdapter(c, self);
            probe->testConnection([probe, settle, externalURL](StorageError err) {
                probe->deleteLater();
                settle(externalURL, false, err);
            });
        });
    } else {
        // 没有外网地址，计一次失败以便两路计数正确
        QTimer::singleShot(kExternalDelayMs, this, [settle]() {
            settle(QString(), false,
                   StorageError(StorageError::InvalidConfig, QStringLiteral("无外网地址")));
        });
    }
}

/**
 * 执行一次带自愈的操作。
 * invoke(retrying) 负责实际调用；onFail 在最终失败时回报错误。
 */
template <typename Invoke, typename Fail>
void RoutedWebDAVAdapter::withRoute(Invoke invoke, Fail onFail)
{
    QPointer<RoutedWebDAVAdapter> self(this);
    resolveRoute([self, invoke, onFail](const QString &url, StorageError err) mutable {
        if (!self)
            return;
        if (!err.isNull()) {
            onFail(err);
            return;
        }
        Q_UNUSED(url);
        // 第一次尝试；失败且可恢复则清锁后重试一次
        invoke([self, invoke, onFail](StorageError opErr) mutable {
            if (!self) {
                return;
            }
            if (opErr.isNull() || !opErr.isRouteRecoverable()) {
                if (!opErr.isNull())
                    onFail(opErr);
                return;
            }
            if (!self->canClearLock()) {
                onFail(opErr);
                return;
            }
            MH_WARN(
                NetworkRoute,
                QStringLiteral("recoverable failure (%1), re-racing route").arg(opErr.message()));
            self->invalidateRoute();
            self->resolveRoute([self, invoke, onFail](const QString &, StorageError e2) mutable {
                if (!self)
                    return;
                if (!e2.isNull()) {
                    onFail(e2);
                    return;
                }
                // 第二次尝试：无论成败都直接回报，不再重试
                invoke([onFail](StorageError finalErr) {
                    if (!finalErr.isNull())
                        onFail(finalErr);
                });
            });
        });
    });
}

void RoutedWebDAVAdapter::list(const QString &dir, ListCallback cb)
{
    if (!cb)
        return;
    auto shared = std::make_shared<ListCallback>(std::move(cb));
    QPointer<RoutedWebDAVAdapter> self(this);

    withRoute(
        [self, dir, shared](std::function<void(StorageError)> report) {
            if (!self)
                return;
            self->m_adapter->list(dir, [shared, report](ListResult r) {
                if (r.ok()) {
                    (*shared)(std::move(r));
                    report(StorageError());
                } else {
                    report(r.error); // 交给自愈逻辑判断是否重试
                }
            });
        },
        [shared](StorageError err) { (*shared)(ListResult::failure(err)); });
}

void RoutedWebDAVAdapter::stat(const QString &path, StatCallback cb)
{
    if (!cb)
        return;
    auto shared = std::make_shared<StatCallback>(std::move(cb));
    QPointer<RoutedWebDAVAdapter> self(this);

    withRoute(
        [self, path, shared](std::function<void(StorageError)> report) {
            if (!self)
                return;
            self->m_adapter->stat(path, [shared, report](StatResult r) {
                if (r.ok()) {
                    (*shared)(std::move(r));
                    report(StorageError());
                } else {
                    report(r.error);
                }
            });
        },
        [shared](StorageError err) { (*shared)(StatResult::failure(err)); });
}

void RoutedWebDAVAdapter::readRange(const QString &path, std::optional<qint64> start,
                                    std::optional<qint64> end, DataCallback cb)
{
    if (!cb)
        return;
    // 流式读取：**先解析路由再选址**，流不可中途换址（PC-708）
    auto shared = std::make_shared<DataCallback>(std::move(cb));
    QPointer<RoutedWebDAVAdapter> self(this);

    resolveRoute([self, path, start, end, shared](const QString &, StorageError err) {
        if (!self)
            return;
        if (!err.isNull()) {
            (*shared)(DataResult::failure(err));
            return;
        }
        self->m_adapter->readRange(path, start, end,
                                   [shared](DataResult r) { (*shared)(std::move(r)); });
    });
}

void RoutedWebDAVAdapter::testConnection(ErrorCallback cb)
{
    if (!cb)
        return;
    // 连接测试必须清锁重判（§2.4 PC-101）
    m_lockedURL.clear();
    m_lockedIsInternal = false;
    m_lockClearedAt.invalidate(); // 手动测试不受冷却限制

    auto shared = std::make_shared<ErrorCallback>(std::move(cb));
    QPointer<RoutedWebDAVAdapter> self(this);
    resolveRoute([shared, self](const QString &, StorageError err) {
        Q_UNUSED(self);
        (*shared)(err);
    });
}

void RoutedWebDAVAdapter::writeFile(const QString &path, const QByteArray &data, ErrorCallback cb)
{
    if (!cb)
        return;
    auto shared = std::make_shared<ErrorCallback>(std::move(cb));
    QPointer<RoutedWebDAVAdapter> self(this);
    resolveRoute([self, path, data, shared](const QString &, StorageError err) {
        if (!self)
            return;
        if (!err.isNull()) {
            (*shared)(err);
            return;
        }
        self->m_adapter->writeFile(path, data, [shared](StorageError e) { (*shared)(e); });
    });
}

void RoutedWebDAVAdapter::uploadFile(const QString &path, const QString &localPath,
                                     UploadProgress progress, CancelProbe isCancelled,
                                     ErrorCallback cb)
{
    if (!cb)
        return;
    auto shared = std::make_shared<ErrorCallback>(std::move(cb));
    QPointer<RoutedWebDAVAdapter> self(this);
    resolveRoute(
        [self, path, localPath, progress, isCancelled, shared](const QString &, StorageError err) {
            if (!self)
                return;
            if (!err.isNull()) {
                (*shared)(err);
                return;
            }
            self->m_adapter->uploadFile(path, localPath, progress, isCancelled,
                                        [shared](StorageError e) { (*shared)(e); });
        });
}

void RoutedWebDAVAdapter::writeFrom(const QString &path, QIODevice *source, qint64 totalBytes,
                                    UploadProgress progress, CancelProbe isCancelled,
                                    ErrorCallback cb)
{
    if (!cb)
        return;
    auto shared = std::make_shared<ErrorCallback>(std::move(cb));
    QPointer<RoutedWebDAVAdapter> self(this);
    resolveRoute([self, path, source, totalBytes, progress, isCancelled, shared](const QString &,
                                                                                 StorageError err) {
        if (!self)
            return;
        if (!err.isNull()) {
            (*shared)(err);
            return;
        }
        // 源设备生命周期由调用方负责（回调返回前不得销毁）
        self->m_adapter->writeFrom(path, source, totalBytes, progress, isCancelled,
                                   [shared](StorageError e) { (*shared)(e); });
    });
}

void RoutedWebDAVAdapter::makeDirectory(const QString &path, ErrorCallback cb)
{
    if (!cb)
        return;
    auto shared = std::make_shared<ErrorCallback>(std::move(cb));
    QPointer<RoutedWebDAVAdapter> self(this);
    resolveRoute([self, path, shared](const QString &, StorageError err) {
        if (!self)
            return;
        if (!err.isNull()) {
            (*shared)(err);
            return;
        }
        self->m_adapter->makeDirectory(path, [shared](StorageError e) { (*shared)(e); });
    });
}

void RoutedWebDAVAdapter::remove(const QString &path, ErrorCallback cb)
{
    if (!cb)
        return;
    auto shared = std::make_shared<ErrorCallback>(std::move(cb));
    QPointer<RoutedWebDAVAdapter> self(this);
    resolveRoute([self, path, shared](const QString &, StorageError err) {
        if (!self)
            return;
        if (!err.isNull()) {
            (*shared)(err);
            return;
        }
        self->m_adapter->remove(path, [shared](StorageError e) { (*shared)(e); });
    });
}

void RoutedWebDAVAdapter::move(const QString &src, const QString &dst, ErrorCallback cb)
{
    if (!cb)
        return;
    auto shared = std::make_shared<ErrorCallback>(std::move(cb));
    QPointer<RoutedWebDAVAdapter> self(this);
    resolveRoute([self, src, dst, shared](const QString &, StorageError err) {
        if (!self)
            return;
        if (!err.isNull()) {
            (*shared)(err);
            return;
        }
        self->m_adapter->move(src, dst, [shared](StorageError e) { (*shared)(e); });
    });
}

void RoutedWebDAVAdapter::copy(const QString &src, const QString &dst, ErrorCallback cb)
{
    if (!cb)
        return;
    auto shared = std::make_shared<ErrorCallback>(std::move(cb));
    QPointer<RoutedWebDAVAdapter> self(this);
    resolveRoute([self, src, dst, shared](const QString &, StorageError err) {
        if (!self)
            return;
        if (!err.isNull()) {
            (*shared)(err);
            return;
        }
        self->m_adapter->copy(src, dst, [shared](StorageError e) { (*shared)(e); });
    });
}

QVariantMap RoutedWebDAVAdapter::lockSnapshot() const
{
    QVariantMap m;
    m.insert(QStringLiteral("lockedURL"), m_lockedURL);
    m.insert(QStringLiteral("lockedIsInternal"), m_lockedIsInternal);
    m.insert(QStringLiteral("hasInternalURL"), !m_config.internalBaseURL.isEmpty());
    m.insert(QStringLiteral("externalURL"), m_config.baseURL);
    m.insert(QStringLiteral("internalURL"), m_config.internalBaseURL);
    m.insert(QStringLiteral("lastRaceMs"), m_lastRaceMs);
    m.insert(QStringLiteral("lastRaceWinner"), m_lastRaceWinner);
    m.insert(QStringLiteral("coolingDown"), !canClearLock());
    return m;
}

} // namespace myhub
