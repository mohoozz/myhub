#pragma once

#include "RangeSource.h"

#include <QString>

#include <functional>
#include <memory>

namespace myhub {

class StorageAdapter;

/**
 * 把任意 `StorageAdapter` 的分块读统一成可 Range 的字节源（§4.2）。
 *
 * 现状与取舍：
 *   - WebDAV 走 `GET` + `Range`，SMB 走 `lseek + read`，二者都只提供
 *     「一次请求返回一段字节」的**批量**接口，没有真正的流式进度回调。
 *     因此本类把读取粒度压到 `blockBytes`（默认 256 KB）：
 *     **断点以数据块为单位**——连接中断最多重下当前 256 KB，已完成的块不重下。
 *   - 每个请求都有停滞看门狗（默认 15s）。批量接口拿不到中途进度，
 *     所以看门狗是「单块请求超时」而不是「连续 15s 无数据」；
 *     块足够小，两者在体感上等价。
 *   - 连续 `zeroProgressLimit` 次零进展才退避重试，并触发地址锁定失效
 *     （WebDAV 内外网竞速锁错了地址时，这是唯一的自愈入口）。
 */
class AdapterRangeSource : public RangeSource
{
    Q_OBJECT
public:
    struct Policy
    {
        /// 单次请求的最大字节数，也是断点续传的粒度
        int blockBytes = 256 * 1024;
        /// 单块请求的超时（毫秒）
        int stallTimeoutMs = 15000;
        /// 单块的最大尝试次数（含首次）
        int maxAttempts = 3;
        /// 退避基数（毫秒），按尝试次数线性放大
        int backoffMs = 400;
        /// 连续零进展多少次后执行 invalidateRoute
        int zeroProgressLimit = 3;
    };

    /// adapter 不接管所有权；要求与本源同线程（回调直接落在该线程）
    AdapterRangeSource(StorageAdapter *adapter, QString path, qint64 fileSize,
                       QObject *parent = nullptr);
    ~AdapterRangeSource() override;

    void setPolicy(const Policy &policy) { m_policy = policy; }
    const Policy &policy() const { return m_policy; }

    /// 连续零进展时调用（WebDAV 路由装饰器传 invalidateRoute，其余可留空）
    void setInvalidateRoute(std::function<void()> fn) { m_invalidateRoute = std::move(fn); }

    qint64 size() const override { return m_size; }
    void readRange(qint64 start, qint64 length, Callback cb) override;

    /// 诊断：累计请求次数 / 重试次数 / 连续零进展次数
    int requestCount() const { return m_requestCount; }
    int retryCount() const { return m_retryCount; }
    int zeroProgress() const { return m_zeroProgress; }

private:
    struct Fetch;

    void fetch(const std::shared_ptr<Fetch> &state);
    void retryOrFail(const std::shared_ptr<Fetch> &state, const StorageError &error);

    StorageAdapter *m_adapter = nullptr;
    QString m_path;
    qint64 m_size = -1;
    Policy m_policy;
    std::function<void()> m_invalidateRoute;

    int m_requestCount = 0;
    int m_retryCount = 0;
    int m_zeroProgress = 0;
};

} // namespace myhub
