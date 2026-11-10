#pragma once

#include "core/storage/StorageError.h"

#include <QByteArray>
#include <QIODevice>
#include <QMutex>
#include <QWaitCondition>

namespace myhub {

/**
 * 跨源中转的单文件「管道」（PC-104）。
 *
 * 形态：一个**只读顺序设备**，由生产者（GUI 线程，从源连接源分块读）灌数据，
 * 由消费者（适配器内部）按序读出并写成目标文件。
 *
 * 为什么要设备而不是缓冲区：WebDAV 的 PUT 需要 `QIODevice*` 才能边读边发
 * （`QNAM` 在 http 线程上读），本地适配器也在线程池线程上读。
 * **两处读取都不在 GUI 线程**，故这里必须做成线程安全的阻塞队列。
 *
 * 纪律：
 *   - `readData` 只阻塞在条件变量上，超时仅用于让取消/失败更及时，**绝不把超时当 EOF**
 *   - 上游结束（finish）或中止（abort）都会唤醒消费者；中止时 `readData` 返回 -1
 *   - 任何一侧失败都要 `abort()`，否则对侧会一直等下去
 */
class RelayStream : public QIODevice
{
    Q_OBJECT
public:
    /// totalBytes <= 0 表示长度未知（仅 finish() 后才算读完）
    explicit RelayStream(qint64 totalBytes, QObject *parent = nullptr);

    bool isSequential() const override { return true; }

    // ---- 生产者侧（GUI 线程）----

    /// 追加一段数据；已中止或已结束时丢弃并返回 false（生产者据此停止上游读取）
    bool append(const QByteArray &chunk);
    /// 上游已读完，届时消费侧读到末尾返回 0
    void finish();
    /// 中止（取消 / 上游失败 / 下游失败）；消费侧立刻拿到错误
    void abort(const StorageError &error);

    // ---- 两侧共享 ----

    StorageError error() const;
    qint64 consumedBytes() const;
    qint64 bufferedBytes() const;

    qint64 bytesAvailable() const override;

protected:
    qint64 readData(char *data, qint64 maxlen) override;
    qint64 writeData(const char *data, qint64 maxlen) override;

private:
    mutable QMutex m_mutex;
    QWaitCondition m_cond;
    QByteArray m_buffer;
    qint64 m_bufferOffset = 0;
    qint64 m_totalBytes = 0;
    qint64 m_consumed = 0;
    bool m_finished = false;
    bool m_aborted = false;
    StorageError m_error;
};

} // namespace myhub
