#pragma once

#include "FileEntry.h"
#include "StorageError.h"

#include <QObject>
#include <functional>
#include <optional>

class QIODevice;

namespace myhub {

/**
 * 异步结果包装：值 + 错误二选一。
 *
 * 与需求文档 §4.4 的差异说明：文档示例使用 `QFuture<QList<FileEntry>>`，
 * 但 QFuture 无法承载 StorageError（只能抛异常），而 PC-708 的路由自愈逻辑
 * 必须按错误种类（Offline / InvalidResponse / 5xx）精确分支。
 * 因此改用 Result + 回调，语义等价且错误可判别。
 */
template <typename T>
struct Result
{
    T value{};
    StorageError error;

    bool ok() const { return error.isNull(); }

    static Result success(T v) { return Result{std::move(v), StorageError()}; }
    static Result failure(StorageError e) { return Result{T{}, std::move(e)}; }
};

using ListResult = Result<FileEntryList>;
using StatResult = Result<FileEntry>;
using DataResult = Result<QByteArray>;

using ListCallback = std::function<void(ListResult)>;
using StatCallback = std::function<void(StatResult)>;
using DataCallback = std::function<void(DataResult)>;
using ErrorCallback = std::function<void(StorageError)>;

/**
 * 存储适配器统一接口（需求文档 §4.4）。
 *
 * 线程约定：所有方法可从 GUI 线程调用且**立即返回**；
 * 实际 IO 在内部异步执行（WebDAV 走 QNAM 异步；Local/SMB 走线程池），
 * 回调一律投递回调用者线程，保证「GUI 线程零阻塞」（§4.3 线程模型）。
 */
class StorageAdapter : public QObject
{
    Q_OBJECT
public:
    explicit StorageAdapter(QObject *parent = nullptr);
    ~StorageAdapter() override;

    /// 适配器类型标识（local / webdav / smb）
    virtual QString typeName() const = 0;

    /// 列举目录
    virtual void list(const QString &dir, ListCallback cb) = 0;

    /// 读取单个条目的元信息
    virtual void stat(const QString &path, StatCallback cb) = 0;

    /// 读取字节范围；start/end 均为空表示整文件。用于封面提取、文本预览等
    virtual void readRange(const QString &path, std::optional<qint64> start,
                           std::optional<qint64> end, DataCallback cb) = 0;

    /// 连接测试（会清除地址锁定并重新判定）
    virtual void testConnection(ErrorCallback cb) = 0;

    // ---- 写操作（M1 文件管理启用，M0 先提供接口与基础实现）----
    virtual void writeFile(const QString &path, const QByteArray &data, ErrorCallback cb);

    /// 上传进度回调：已发送字节数。**可能在后台线程调用**，调用方需自行投递/节流。
    using UploadProgress = std::function<void(qint64 sent)>;
    /// 取消探针：返回 true 表示调用方要求尽快中止。
    using CancelProbe = std::function<bool()>;

    /**
     * 从本地文件流式上传（PC-103）。
     *
     * 与 writeFile 的区别：整块 `QByteArray` 既撑不住大文件（内存翻倍），
     * 也无法给出字节级进度。本接口由适配器自行分块读源文件、边读边写，
     * 通过 progress 回报已发送字节；isCancelled 为真时应尽早中止并返回 Cancelled。
     *
     * 默认实现返回 UnsupportedProtocol（SMB 等只读实现）。
     */
    virtual void uploadFile(const QString &path, const QString &localPath, UploadProgress progress,
                            CancelProbe isCancelled, ErrorCallback cb);

    /**
     * 流式写入（跨源中转，PC-104）。
     *
     * 与 uploadFile 的区别：数据源不是本地文件，而是另一侧连接源的读取管道
     * （`RelayStream`）。适配器自己决定在哪个线程读（本地走线程池、
     * WebDAV 走 QNAM 的 http 线程），因此 source 必须是线程安全的顺序设备。
     *
     * 纪律：**不落大临时文件**（边读边写）；读到 EOF 时已写入字节数必须等于 totalBytes，
     * 否则视为失败（源被截断不能当作成功）。
     *
     * 默认实现返回 UnsupportedProtocol（SMB 等只读实现）。
     */
    virtual void writeFrom(const QString &path, QIODevice *source, qint64 totalBytes,
                           UploadProgress progress, CancelProbe isCancelled, ErrorCallback cb);

    virtual void makeDirectory(const QString &path, ErrorCallback cb);
    virtual void remove(const QString &path, ErrorCallback cb);
    virtual void move(const QString &src, const QString &dst, ErrorCallback cb);
    virtual void copy(const QString &src, const QString &dst, ErrorCallback cb);

    /// 是否支持回收站（挂载点下 .trash）
    virtual bool supportsTrash() const { return true; }

protected:
    /// 把回调投递回 receiver 所在线程（避免跨线程直接触达 UI 模型）
    template <typename F>
    static void postTo(QObject *receiver, F &&fn)
    {
        QMetaObject::invokeMethod(receiver, std::forward<F>(fn), Qt::QueuedConnection);
    }
};

} // namespace myhub
