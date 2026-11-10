#pragma once

#include "core/storage/StorageError.h"

#include <QByteArray>
#include <QObject>

#include <functional>

namespace myhub {

/**
 * 可随机读取的字节源（边下边播的数据来源抽象，§4.2）。
 *
 * 为什么要有这一层：播放器只认「本地回环 HTTP」这一个入口，而实际数据可能来自
 * WebDAV 的 Range 请求、SMB 的分块读，将来还可能是离线缓存。播放管线只依赖本接口，
 * 因此换传输方式不需要动 `LocalStreamProxy` / `CachedRangeReader`。
 *
 * 纪律：
 *   - **回调必须在调用者线程执行**（适配器已保证），读取方据此直接访问缓存与 UI 状态
 *   - 读到文件尾允许短读；**网络中断必须报错，不得用短读冒充 EOF**
 *     （短读冒充 EOF 会让 mpv 把半截文件当完整文件，表现为「播到某处就结束」）
 *   - `cancel()` 后不得再发起新请求；在途结果由上层丢弃
 */
class RangeSource : public QObject
{
    Q_OBJECT
public:
    /// data 为读到的字节；error 非空时 data 无意义
    using Callback = std::function<void(QByteArray data, StorageError error)>;

    explicit RangeSource(QObject *parent = nullptr);
    ~RangeSource() override;

    /// 文件总长度；-1 表示未知（未知时上层不做分段预读，只顺序读）
    virtual qint64 size() const = 0;

    /// 读取 `[start, start + length)`；length <= 0 视为非法请求（回调空数据 + InvalidPath）
    virtual void readRange(qint64 start, qint64 length, Callback cb) = 0;

    /// 会话注销：阻断后续请求
    virtual void cancel();
    bool canceled() const { return m_canceled; }

signals:
    /// 本次成功追加的字节数（用于「边下边播」的进度/诊断埋点）
    void progressed(qint64 bytes);

protected:
    void setCanceled(bool canceled);

private:
    bool m_canceled = false;
};

} // namespace myhub
