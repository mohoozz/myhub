#include "RelayStream.h"

#include <QMutexLocker>

#include <cstring>

namespace myhub {

namespace {
/// 等待粒度：毫秒级轮询让「另一侧失败/取消」能及时打断阻塞
constexpr int kWaitSliceMs = 100;
} // namespace

RelayStream::RelayStream(qint64 totalBytes, QObject *parent)
    : QIODevice(parent)
    , m_totalBytes(totalBytes)
{
    open(QIODevice::ReadOnly);
}

bool RelayStream::append(const QByteArray &chunk)
{
    const QMutexLocker locker(&m_mutex);
    if (m_aborted || m_finished) {
        return false;
    }
    if (chunk.isEmpty()) {
        return true;
    }
    // 消费过的前缀先丢掉，避免缓冲区随大文件无限增长
    if (m_bufferOffset > 0) {
        m_buffer.remove(0, int(m_bufferOffset));
        m_bufferOffset = 0;
    }
    m_buffer.append(chunk);
    m_cond.wakeAll();
    return true;
}

void RelayStream::finish()
{
    const QMutexLocker locker(&m_mutex);
    m_finished = true;
    m_cond.wakeAll();
}

void RelayStream::abort(const StorageError &error)
{
    const QMutexLocker locker(&m_mutex);
    if (m_aborted) {
        return;
    }
    m_aborted = true;
    m_error = error;
    m_cond.wakeAll();
}

StorageError RelayStream::error() const
{
    const QMutexLocker locker(&m_mutex);
    return m_error;
}

qint64 RelayStream::consumedBytes() const
{
    const QMutexLocker locker(&m_mutex);
    return m_consumed;
}

qint64 RelayStream::bufferedBytes() const
{
    const QMutexLocker locker(&m_mutex);
    return m_buffer.size() - m_bufferOffset;
}

qint64 RelayStream::bytesAvailable() const
{
    return bufferedBytes() + QIODevice::bytesAvailable();
}

qint64 RelayStream::readData(char *data, qint64 maxlen)
{
    const QMutexLocker locker(&m_mutex);
    for (;;) {
        if (m_aborted) {
            return -1;
        }
        const qint64 available = m_buffer.size() - m_bufferOffset;
        if (available > 0) {
            const qint64 take = qMin(maxlen, available);
            std::memcpy(data, m_buffer.constData() + m_bufferOffset, size_t(take));
            m_bufferOffset += take;
            m_consumed += take;
            if (m_bufferOffset >= m_buffer.size()) {
                m_buffer.clear();
                m_bufferOffset = 0;
            }
            return take;
        }
        if (m_finished) {
            return 0;
        }
        // 只等「再来一块」，超时后继续等：超时不是 EOF
        m_cond.wait(&m_mutex, kWaitSliceMs);
    }
}

qint64 RelayStream::writeData(const char *, qint64)
{
    return -1; // 只读
}

} // namespace myhub
