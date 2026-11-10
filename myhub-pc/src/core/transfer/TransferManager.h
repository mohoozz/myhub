#pragma once

#include "core/storage/StorageError.h"

#include <QElapsedTimer>
#include <QFile>
#include <QHash>
#include <QList>
#include <QSet>
#include <QObject>
#include <QString>
#include <QStringList>

#include <atomic>
#include <functional>
#include <memory>

namespace myhub {

class StorageAdapter;

/**
 * 一条传输任务（PC-103）。
 *
 * 字段刻意做成纯数据：UI 模型（TransferListModel）只读快照，
 * 核心逻辑不需要知道任何 QML 细节，便于 QTest 直接断言。
 */
struct TransferTask
{
    enum Kind
    {
        Upload = 0,
        Download = 1,
    };
    enum Status
    {
        Pending = 0,   ///< 排队中
        Running = 1,   ///< 传输中
        Completed = 2, ///< 成功
        Failed = 3,    ///< 失败（可重试）
        Cancelled = 4, ///< 用户取消（回调落地后即移除）
    };

    QString id;
    Kind kind = Upload;
    Status status = Pending;
    QString connectionId;
    QString connectionName;
    QString displayName; ///< 展示用短名（文件名；重名顺延后带序号）
    QString remotePath;  ///< 上传目标 / 下载来源
    QString parentPath;  ///< 上传落点目录（供列表就地插入）；下载为本地目录
    QString localPath;   ///< 上传源 / 下载目标（另存为时由调用方指定）
    qint64 totalBytes = -1;
    qint64 transferred = 0;
    QString error; ///< 失败原因（面向用户的中文描述）
    bool canRetry = false;
};

/**
 * 上传 / 下载任务队列（PC-103）。
 *
 * 设计要点：
 *   - **顺序执行**：同一时刻只有一个任务在跑（需求「多文件顺序队列」），
 *     避免多路并发把内网小带宽打满、也让进度文案唯一。
 *   - **进度节流**：适配器可能按 1MB 粒度回调，这里 100ms 才向外发一次，
 *     否则 1000 个文件会把 QML 事件循环刷爆。
 *   - **下载断点续传**：数据先写 `<目标>.myhub-part`，失败保留；
 *     重试时从 part 已有字节继续（Range 请求），成功后再原子改名。
 *   - **取消**：通过原子标志通知适配器，取消后不落任何残留（删除 part）。
 */
class TransferManager : public QObject
{
    Q_OBJECT
public:
    static TransferManager &instance();

    ~TransferManager() override;

    /**
     * 上传本地文件/文件夹到远端目录。
     * 文件夹会递归展开为多个文件任务（同一队列，顺序执行）。
     * @return 实际入队的任务数
     */
    int enqueueUploads(StorageAdapter *adapter, const QString &connectionId,
                       const QString &connectionName, const QString &dirPath,
                       const QStringList &localPaths);

    /// 下载到 localDir（空则用默认目录「下载/MyHub/<连接名>」）；遇同名自动加序号
    int enqueueDownloads(StorageAdapter *adapter, const QString &connectionId,
                         const QString &connectionName, const QStringList &remotePaths,
                         const QString &localDir = QString());

    /// 另存为：目标本地路径由调用方（系统保存对话框）指定
    int enqueueDownloadAs(StorageAdapter *adapter, const QString &connectionId,
                          const QString &connectionName, const QString &remotePath,
                          const QString &targetPath);

    void cancel(const QString &id);
    void cancelAll();
    void retry(const QString &id);
    /// 移除已完成 / 失败 / 取消的任务（入队前调用，避免横幅堆积历史）
    void clearFinished();

    QList<TransferTask> tasks() const { return m_tasks; }
    /// 排队中 + 传输中的数量
    int activeCount() const;
    bool busy() const { return activeCount() > 0; }

    /// 默认下载根目录：系统「下载」下的 MyHub
    static QString defaultDownloadDir();

    /// 重名顺延：name.ext → name (1).ext
    static QString appendIndex(const QString &fileName, int attempt);

signals:
    void taskAdded(int row);
    void taskChanged(int row);
    void taskRemoved(int row);
    void busyChanged();

    /// 上传完成（供浏览页就地插入条目）
    void uploaded(const QString &connectionId, const QString &parentPath,
                  const QString &remotePath);
    /// 下载完成（供 UI 提示「在文件夹中显示」）
    void downloaded(const QString &connectionId, const QString &remotePath,
                    const QString &localPath);

private:
    explicit TransferManager(QObject *parent = nullptr);

    struct Runtime
    {
        StorageAdapter *adapter = nullptr;
        std::shared_ptr<std::atomic_bool> cancelFlag;
        QElapsedTimer lastEmit;
        /// 下载时的落盘句柄（`.part`）与当前写入偏移（断点续传起点）
        QFile *outFile = nullptr;
        qint64 offset = 0;
    };

    void pump();
    void startTask(const QString &id);
    void startUpload(const QString &id);
    void startDownload(const QString &id);
    void resolveUploadTarget(const QString &id, int attempt);
    void performUpload(const QString &id);
    void requestNextChunk(const QString &id);
    void completeTask(const QString &id);
    void failTask(const QString &id, const StorageError &error);
    void dropTask(const QString &id);
    void updateProgress(const QString &id, qint64 transferred, qint64 total);
    void emitChanged(const QString &id);
    void notifyBusy();

    int rowOf(const QString &id) const;
    TransferTask *taskOf(const QString &id);
    bool isCancelled(const QString &id) const;

    /// 逐级建目录（已存在视为成功）
    void ensureDirectory(StorageAdapter *adapter, const QString &dir,
                         std::function<void(StorageError)> done);

    QList<TransferTask> m_tasks;
    QHash<QString, Runtime> m_runtime;
    /// 已在本次队列中预定但尚未落盘的远端路径（避免同批同名文件互相覆盖）
    QSet<QString> m_reservedPaths;
    QString m_runningId;
    bool m_lastBusy = false;
    bool m_pumpScheduled = false;
    quint64 m_seq = 0;
};

} // namespace myhub
