#include "AdapterRangeSource.h"

#include "core/storage/StorageAdapter.h"
#include "core/utils/AppLogger.h"

#include <QPointer>
#include <QTimer>

namespace myhub {

namespace {

/// 单次读写请求的运行态（跨重试共享，保证已下载字节不丢）
struct FetchState
{
    qint64 offset = 0; ///< 下一次请求的起点
    qint64 want = 0;   ///< 本次调用的总字节数
    QByteArray acc;    ///< 已攒到的字节（重试时保留）
    int attempts = 0;  ///< 本块已发起的请求次数
    int failures = 0;  ///< 连续失败次数（成功后清零，用于重试上限）
    qint64 gainedThisAttempt = 0;
    int generation = 0; ///< 超时/重试换代，丢弃迟到的响应
    bool done = false;
    QPointer<QTimer> timer;
    RangeSource::Callback cb;
};

} // namespace

struct AdapterRangeSource::Fetch : FetchState
{};

AdapterRangeSource::AdapterRangeSource(StorageAdapter *adapter, QString path, qint64 fileSize,
                                       QObject *parent)
    : RangeSource(parent)
    , m_adapter(adapter)
    , m_path(std::move(path))
    , m_size(fileSize)
{}

AdapterRangeSource::~AdapterRangeSource() = default;

void AdapterRangeSource::readRange(qint64 start, qint64 length, Callback cb)
{
    if (!cb)
        return;

    if (canceled()) {
        cb({}, StorageError(StorageError::Cancelled, QStringLiteral("播放会话已结束")));
        return;
    }
    if (!m_adapter || start < 0 || length <= 0) {
        cb({}, StorageError(StorageError::InvalidPath, QStringLiteral("非法的读取范围")));
        return;
    }
    if (m_size >= 0 && start >= m_size) {
        // 恰好读到文件尾：正常返回空，不得当作错误（mpv 会多次探测末尾）
        cb({}, StorageError());
        return;
    }

    auto state = std::make_shared<Fetch>();
    state->offset = start;
    state->want = length;
    if (m_size >= 0)
        state->want = qMin(state->want, m_size - start);
    state->cb = std::move(cb);

    fetch(state);
}

void AdapterRangeSource::fetch(const std::shared_ptr<Fetch> &state)
{
    if (state->done)
        return;

    if (canceled()) {
        state->done = true;
        state->cb({}, StorageError(StorageError::Cancelled, QStringLiteral("播放会话已结束")));
        return;
    }
    if (!m_adapter) {
        state->done = true;
        state->cb({}, StorageError(StorageError::Underlying, QStringLiteral("存储适配器不可用")));
        return;
    }

    const qint64 remaining = state->want - state->acc.size();
    if (remaining <= 0) {
        state->done = true;
        QByteArray data = state->acc;
        state->acc.clear();
        state->cb(std::move(data), StorageError());
        return;
    }

    const int generation = ++state->generation;
    ++m_requestCount;
    ++state->attempts;
    state->gainedThisAttempt = 0;
    state->timer = new QTimer(this);
    state->timer->setSingleShot(true);
    connect(state->timer, &QTimer::timeout, this, [this, state]() {
        if (!state || state->done)
            return;
        state->generation++;
        retryOrFail(
            state,
            StorageError(StorageError::Offline,
                         QStringLiteral("读取超时（%1s）").arg(m_policy.stallTimeoutMs / 1000)));
    });
    state->timer->start(m_policy.stallTimeoutMs);

    // 每次只发一个数据块：断点粒度 = blockBytes，失败重试只重下当前块
    const qint64 chunk = qMin<qint64>(remaining, m_policy.blockBytes);
    const qint64 start = state->offset;
    const qint64 end = start + chunk - 1;
    QPointer<AdapterRangeSource> self(this);
    m_adapter->readRange(m_path, start, end, [self, state, generation](DataResult result) {
        if (!self || !state || state->done || generation != state->generation)
            return;
        if (state->timer) {
            state->timer->stop();
            state->timer->deleteLater();
            state->timer = nullptr;
        }

        if (!result.ok()) {
            self->retryOrFail(state, result.error);
            return;
        }

        QByteArray data = result.value;
        const qint64 wanted = state->want - state->acc.size();
        if (data.size() > wanted)
            data.truncate(wanted);

        if (data.isEmpty()) {
            if (self->m_size < 0) {
                // 长度未知且读空了：视为 EOF
                state->done = true;
                QByteArray out = state->acc;
                state->acc.clear();
                state->cb(std::move(out), StorageError());
                return;
            }
            self->retryOrFail(
                state, StorageError(StorageError::Offline, QStringLiteral("服务器返回空响应")));
            return;
        }

        state->offset += data.size();
        state->gainedThisAttempt += data.size();
        state->acc += data;
        state->failures = 0;
        emit self->progressed(data.size());

        if (state->acc.size() >= state->want) {
            state->done = true;
            QByteArray out = state->acc;
            state->acc.clear();
            self->m_zeroProgress = 0;
            state->cb(std::move(out), StorageError());
            return;
        }

        // 短读但未到目标：同一块接着补，不计入失败
        state->attempts = 0;
        self->fetch(state);
    });
}

void AdapterRangeSource::retryOrFail(const std::shared_ptr<Fetch> &state, const StorageError &error)
{
    if (!state || state->done)
        return;

    // 路由自愈埋点：连续多次零进展说明当前锁定的地址可能已经不可用
    if (state->gainedThisAttempt == 0)
        ++m_zeroProgress;
    else
        m_zeroProgress = 0;

    if (m_zeroProgress >= m_policy.zeroProgressLimit) {
        m_zeroProgress = 0;
        if (m_invalidateRoute)
            m_invalidateRoute();
        MH_WARN(Stream, QStringLiteral("连续零进展，已使地址锁定失效：%1").arg(m_path));
    }

    state->gainedThisAttempt = 0;
    ++state->failures;

    const bool retryable = error.isTransient() || error.kind() == StorageError::Offline
        || error.kind() == StorageError::InvalidResponse
        || error.kind() == StorageError::Underlying;

    if (!retryable || state->failures >= m_policy.maxAttempts) {
        state->done = true;
        if (state->timer) {
            state->timer->stop();
            state->timer->deleteLater();
            state->timer = nullptr;
        }
        MH_WARN(Stream,
                QStringLiteral("分块读取失败（第 %1 次）：%2 %3")
                    .arg(state->failures)
                    .arg(m_path, error.message()));
        state->cb({}, error);
        return;
    }

    ++m_retryCount;
    const int delay = m_policy.backoffMs * state->failures;
    QPointer<AdapterRangeSource> self(this);
    QTimer::singleShot(delay, this, [self, state]() {
        if (!self || state->done)
            return;
        self->fetch(state);
    });
}

} // namespace myhub
