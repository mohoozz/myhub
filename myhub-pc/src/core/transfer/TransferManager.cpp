#include "TransferManager.h"

#include "core/storage/StorageAdapter.h"
#include "core/storage/StoragePath.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QStandardPaths>
#include <QTimer>
#include <QUrl>

namespace myhub {

namespace {

/// 下载分块大小：单块 1MB，进度粒度与请求次数取得平衡
constexpr qint64 kChunkBytes = 1024LL * 1024;
/// 进度节流间隔（毫秒）
constexpr int kProgressIntervalMs = 100;
/// 单次拖入的文件夹最多展开多少个文件，避免误拖整个盘符卡死
constexpr int kMaxFolderFiles = 500;

const QString kPartSuffix = QStringLiteral(".myhub-part");

/// name.ext → name (n).ext；无扩展名时 name → name (n)
QString indexedName(const QString &fileName, int attempt)
{
    if (attempt <= 0)
        return fileName;
    const int dot = fileName.lastIndexOf(QLatin1Char('.'));
    const QString suffix = QStringLiteral(" (%1)").arg(attempt);
    if (dot <= 0)
        return fileName + suffix;
    return fileName.left(dot) + suffix + fileName.mid(dot);
}

/// 文件夹递归展开（最多 kMaxFolderFiles 个文件）
void collectFiles(const QString &dir, const QString &relative, QStringList *out, int limit)
{
    const QDir d(dir);
    const QFileInfoList entries =
        d.entryInfoList(QDir::Files | QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name);
    for (const QFileInfo &fi : entries) {
        if (out->size() >= limit)
            return;
        const QString rel =
            relative.isEmpty() ? fi.fileName() : relative + QLatin1Char('/') + fi.fileName();
        if (fi.isDir())
            collectFiles(fi.absoluteFilePath(), rel, out, limit);
        else
            out->append(fi.absoluteFilePath());
    }
}

} // namespace

TransferManager &TransferManager::instance()
{
    static TransferManager manager;
    return manager;
}

TransferManager::TransferManager(QObject *parent)
    : QObject(parent)
{}

TransferManager::~TransferManager() = default;

QString TransferManager::defaultDownloadDir()
{
    const QString base = QStandardPaths::writableLocation(QStandardPaths::DownloadLocation);
    return QDir(base.isEmpty() ? QDir::homePath() : base).filePath(QStringLiteral("MyHub"));
}

QString TransferManager::appendIndex(const QString &fileName, int attempt)
{
    return indexedName(fileName, attempt);
}

int TransferManager::enqueueUploads(StorageAdapter *adapter, const QString &connectionId,
                                    const QString &connectionName, const QString &dirPath,
                                    const QStringList &localPaths)
{
    if (!adapter || localPaths.isEmpty())
        return 0;

    // 新一批任务进来时先清掉上一批的历史，横幅不会越堆越长
    clearFinished();

    const QString parentDir = StoragePath::normalize(dirPath);
    int added = 0;

    for (const QString &raw : localPaths) {
        // QML 侧可能传来 file:// URL，统一转成本地路径
        const QUrl url(raw);
        const QString localPath = url.isLocalFile() ? url.toLocalFile() : raw;
        const QFileInfo fi(localPath);
        if (!fi.exists())
            continue;

        QStringList files;
        if (fi.isDir()) {
            collectFiles(fi.absoluteFilePath(), QString(), &files, kMaxFolderFiles);
        } else {
            files.append(fi.absoluteFilePath());
        }

        for (const QString &file : files) {
            TransferTask task;
            task.id = QStringLiteral("t%1").arg(++m_seq);
            task.kind = TransferTask::Upload;
            task.connectionId = connectionId;
            task.connectionName = connectionName;
            task.localPath = file;
            task.totalBytes = QFileInfo(file).size();
            if (fi.isDir()) {
                // 保留文件夹层级：目录内的相对路径决定落点
                const QString rel = QDir(fi.absoluteFilePath()).relativeFilePath(file);
                task.displayName = rel;
                const int slash = rel.lastIndexOf(QLatin1Char('/'));
                if (slash >= 0) {
                    task.parentPath = StoragePath::join(parentDir, rel.left(slash));
                    task.displayName = rel.mid(slash + 1);
                } else {
                    task.parentPath = parentDir;
                }
            } else {
                task.parentPath = parentDir;
                task.displayName = fi.fileName();
            }
            task.remotePath.clear(); // 起跑时再探测同名顺延

            Runtime rt;
            rt.adapter = adapter;
            rt.cancelFlag = std::make_shared<std::atomic_bool>(false);
            m_runtime.insert(task.id, rt);

            m_tasks.append(task);
            emit taskAdded(m_tasks.size() - 1);
            ++added;
        }
    }

    if (added > 0) {
        notifyBusy();
        pump();
    }
    return added;
}

int TransferManager::enqueueDownloads(StorageAdapter *adapter, const QString &connectionId,
                                      const QString &connectionName, const QStringList &remotePaths,
                                      const QString &localDir)
{
    if (!adapter || remotePaths.isEmpty())
        return 0;

    clearFinished();
    int added = 0;

    for (const QString &remote : remotePaths) {
        const QString path = StoragePath::normalize(remote);
        if (StoragePath::isRoot(path))
            continue;

        TransferTask task;
        task.id = QStringLiteral("t%1").arg(++m_seq);
        task.kind = TransferTask::Download;
        task.connectionId = connectionId;
        task.connectionName = connectionName;
        task.remotePath = path;
        task.displayName = StoragePath::fileName(path);
        // 目标路径在 startDownload 里拼装；localDir 非空时作为下载根目录
        task.localPath.clear();
        if (!localDir.isEmpty())
            task.parentPath = localDir;

        Runtime rt;
        rt.adapter = adapter;
        rt.cancelFlag = std::make_shared<std::atomic_bool>(false);
        m_runtime.insert(task.id, rt);

        m_tasks.append(task);
        emit taskAdded(m_tasks.size() - 1);
        ++added;
    }

    if (added > 0) {
        notifyBusy();
        pump();
    }
    return added;
}

int TransferManager::enqueueDownloadAs(StorageAdapter *adapter, const QString &connectionId,
                                       const QString &connectionName, const QString &remotePath,
                                       const QString &targetPath)
{
    if (!adapter || remotePath.isEmpty() || targetPath.isEmpty())
        return 0;

    clearFinished();

    TransferTask task;
    task.id = QStringLiteral("t%1").arg(++m_seq);
    task.kind = TransferTask::Download;
    task.connectionId = connectionId;
    task.connectionName = connectionName;
    task.remotePath = StoragePath::normalize(remotePath);
    task.displayName = QFileInfo(targetPath).fileName();
    task.localPath = targetPath;

    Runtime rt;
    rt.adapter = adapter;
    rt.cancelFlag = std::make_shared<std::atomic_bool>(false);
    m_runtime.insert(task.id, rt);

    m_tasks.append(task);
    emit taskAdded(m_tasks.size() - 1);
    notifyBusy();
    pump();
    return 1;
}

int TransferManager::activeCount() const
{
    int count = 0;
    for (const TransferTask &t : m_tasks) {
        if (t.status == TransferTask::Pending || t.status == TransferTask::Running)
            ++count;
    }
    return count;
}

int TransferManager::rowOf(const QString &id) const
{
    for (int i = 0; i < m_tasks.size(); ++i) {
        if (m_tasks.at(i).id == id)
            return i;
    }
    return -1;
}

TransferTask *TransferManager::taskOf(const QString &id)
{
    const int row = rowOf(id);
    return row >= 0 ? &m_tasks[row] : nullptr;
}

bool TransferManager::isCancelled(const QString &id) const
{
    const auto it = m_runtime.constFind(id);
    return it != m_runtime.constEnd() && it->cancelFlag && it->cancelFlag->load();
}

void TransferManager::emitChanged(const QString &id)
{
    const int row = rowOf(id);
    if (row >= 0)
        emit taskChanged(row);
}

void TransferManager::notifyBusy()
{
    const bool now = busy();
    if (now != m_lastBusy) {
        m_lastBusy = now;
        emit busyChanged();
    }
}

void TransferManager::pump()
{
    // 异步调度：任务可能在 startTask 内同步失败并再次 pump，同步递归会越叠越深
    if (m_pumpScheduled)
        return;
    m_pumpScheduled = true;
    QTimer::singleShot(0, this, [this]() {
        m_pumpScheduled = false;
        if (!m_runningId.isEmpty())
            return;
        for (const TransferTask &t : m_tasks) {
            if (t.status != TransferTask::Pending)
                continue;
            const QString id = t.id;
            m_runningId = id;
            startTask(id);
            return;
        }
        notifyBusy();
    });
}

void TransferManager::startTask(const QString &id)
{
    TransferTask *task = taskOf(id);
    if (!task) {
        m_runningId.clear();
        pump();
        return;
    }
    task->status = TransferTask::Running;
    task->error.clear();
    emitChanged(id);
    notifyBusy();

    if (task->kind == TransferTask::Upload)
        startUpload(id);
    else
        startDownload(id);
}

// ---- 上传 ----

void TransferManager::startUpload(const QString &id)
{
    TransferTask *task = taskOf(id);
    const auto it = m_runtime.find(id);
    if (!task || it == m_runtime.end() || !it->adapter) {
        failTask(id, StorageError(StorageError::Underlying, tr("连接源不可用")));
        return;
    }
    task->transferred = 0;
    task->totalBytes = QFileInfo(task->localPath).size();
    // attempt 0 = 原名，冲突才逐次追加 (1) (2) ...
    resolveUploadTarget(id, 0);
}

void TransferManager::resolveUploadTarget(const QString &id, int attempt)
{
    TransferTask *task = taskOf(id);
    if (!task)
        return;
    if (attempt > 99) {
        failTask(id, StorageError(StorageError::Http, tr("同名文件过多，无法确定保存名")));
        return;
    }

    auto it = m_runtime.find(id);
    if (it == m_runtime.end() || !it->adapter) {
        failTask(id, StorageError(StorageError::Underlying, tr("连接源不可用")));
        return;
    }

    const QString candidate = indexedName(task->displayName, attempt);
    const QString path = StoragePath::join(task->parentPath, candidate);

    // 同批任务已经预定的名字直接跳过，避免两个任务同时写入同一路径
    if (m_reservedPaths.contains(path)) {
        resolveUploadTarget(id, attempt + 1);
        return;
    }

    StorageAdapter *adapter = it->adapter;
    adapter->stat(path, [this, id, attempt, path, candidate](StatResult result) {
        TransferTask *t = taskOf(id);
        if (!t || isCancelled(id))
            return;
        if (result.ok()) {
            resolveUploadTarget(id, attempt + 1);
            return;
        }
        if (result.error.kind() != StorageError::NotFound) {
            failTask(id, result.error);
            return;
        }
        t->remotePath = path;
        t->displayName = candidate;
        m_reservedPaths.insert(path);
        performUpload(id);
    });
}

void TransferManager::performUpload(const QString &id)
{
    TransferTask *task = taskOf(id);
    auto it = m_runtime.find(id);
    if (!task || it == m_runtime.end() || !it->adapter)
        return;

    StorageAdapter *adapter = it->adapter;
    const auto flag = it->cancelFlag;
    const QString remote = task->remotePath;
    const QString local = task->localPath;
    const QString parent = task->parentPath;
    const QString connectionId = task->connectionId;

    auto progress = [this, id](qint64 sent) {
        // 适配器可能在 worker 线程回调，统一投递到对象线程后再更新状态
        QMetaObject::invokeMethod(
            this, [this, id, sent]() { updateProgress(id, sent, -1); }, Qt::QueuedConnection);
    };
    auto cancelProbe = [flag]() {
        return flag && flag->load();
    };

    auto finish = [this, id, remote, parent, connectionId](StorageError error) {
        QMetaObject::invokeMethod(
            this,
            [this, id, remote, parent, connectionId, error]() {
                if (!taskOf(id))
                    return;
                if (error.kind() == StorageError::Cancelled || this->isCancelled(id)) {
                    dropTask(id);
                    return;
                }
                if (!error.isNull()) {
                    failTask(id, error);
                    return;
                }
                m_reservedPaths.remove(remote);
                completeTask(id);
                emit uploaded(connectionId, parent, remote);
            },
            Qt::QueuedConnection);
    };

    ensureDirectory(
        adapter, parent,
        [adapter, remote, local, progress, cancelProbe, finish](StorageError dirError) mutable {
            if (!dirError.isNull()) {
                finish(dirError);
                return;
            }
            adapter->uploadFile(remote, local, progress, cancelProbe, finish);
        });
}

// ---- 下载 ----

void TransferManager::startDownload(const QString &id)
{
    TransferTask *task = taskOf(id);
    auto it = m_runtime.find(id);
    if (!task || it == m_runtime.end() || !it->adapter) {
        failTask(id, StorageError(StorageError::Underlying, tr("连接源不可用")));
        return;
    }

    StorageAdapter *adapter = it->adapter;
    const QString remote = task->remotePath;

    adapter->stat(remote, [this, id, remote](StatResult result) {
        TransferTask *t = taskOf(id);
        if (!t)
            return;
        if (!result.ok()) {
            failTask(id, result.error);
            return;
        }
        if (result.value.isDir) {
            failTask(id, StorageError(StorageError::InvalidPath, tr("暂不支持下载文件夹")));
            return;
        }

        if (result.value.size < 0) {
            failTask(id, StorageError(StorageError::InvalidResponse, tr("无法确定文件大小")));
            return;
        }
        t->totalBytes = result.value.size;

        // 目标路径：另存为已指定；否则 <下载根目录>/<连接名>/<远端路径>
        if (t->localPath.isEmpty()) {
            const QString base = t->parentPath.isEmpty() ? defaultDownloadDir() : t->parentPath;
            const QString connDir = QStringLiteral("%1/%2").arg(base, t->connectionName);
            QString candidate = connDir + t->remotePath;
            int attempt = 0;
            // 已存在同名文件 → 顺延；只存在 .part 说明是上次未完成的下载，复用该名字续传
            while (QFile::exists(candidate) && attempt < 99)
                candidate = connDir + StoragePath::parent(t->remotePath) + QLatin1Char('/')
                    + indexedName(StoragePath::fileName(t->remotePath), ++attempt);
            t->localPath = QDir::cleanPath(candidate);
            t->displayName = QFileInfo(t->localPath).fileName();
            t->parentPath = QFileInfo(t->localPath).absolutePath();
        } else if (t->parentPath.isEmpty()) {
            t->parentPath = QFileInfo(t->localPath).absolutePath();
        }

        const QString part = t->localPath + kPartSuffix;
        QDir().mkpath(QFileInfo(t->localPath).absolutePath());

        qint64 offset = 0;
        if (QFile::exists(part)) {
            offset = QFileInfo(part).size();
            if (offset > t->totalBytes) { // 残留脏数据，重来
                QFile::remove(part);
                offset = 0;
            }
        }
        auto *file = new QFile(part);
        const bool ok = offset > 0 ? file->open(QIODevice::Append)
                                   : file->open(QIODevice::WriteOnly | QIODevice::Truncate);
        if (!ok) {
            delete file;
            failTask(id,
                     StorageError(StorageError::Underlying, tr("无法写入本地文件：%1").arg(part)));
            return;
        }

        Runtime &rt = m_runtime[id];
        rt.outFile = file;
        rt.offset = offset;
        t->transferred = offset;
        emitChanged(id);
        requestNextChunk(id);
    });
}

void TransferManager::requestNextChunk(const QString &id)
{
    TransferTask *task = taskOf(id);
    auto it = m_runtime.find(id);
    if (!task || it == m_runtime.end() || !it->adapter)
        return;

    if (isCancelled(id)) {
        dropTask(id);
        return;
    }

    if (it->offset >= task->totalBytes) {
        // completeTask 会启动下一条任务，先把信号参数拷出来再用
        const QString connectionId = task->connectionId;
        const QString remote = task->remotePath;
        const QString local = task->localPath;
        completeTask(id);
        emit downloaded(connectionId, remote, local);
        return;
    }

    StorageAdapter *adapter = it->adapter;
    const QString remote = task->remotePath;
    const qint64 start = it->offset;
    const qint64 end = qMin(start + kChunkBytes, task->totalBytes) - 1;

    adapter->readRange(remote, start, end, [this, id, start](DataResult result) {
        TransferTask *t = taskOf(id);
        auto rt = m_runtime.find(id);
        if (!t || rt == m_runtime.end())
            return;
        if (isCancelled(id)) {
            dropTask(id);
            return;
        }
        if (!result.ok()) {
            failTask(id, result.error);
            return;
        }
        if (result.value.isEmpty()) {
            failTask(id, StorageError(StorageError::Offline, tr("读取中断，可重试续传")));
            return;
        }
        if (!rt->outFile || rt->outFile->write(result.value) != result.value.size()) {
            failTask(id, StorageError(StorageError::Underlying, tr("写入本地文件失败")));
            return;
        }
        rt->offset = start + result.value.size();
        t->transferred = rt->offset;
        // 每块都发一次信号太重：交给 updateProgress 里的节流
        updateProgress(id, rt->offset, t->totalBytes);
        requestNextChunk(id);
    });
}

// ---- 状态流转 ----

void TransferManager::updateProgress(const QString &id, qint64 transferred, qint64 total)
{
    TransferTask *task = taskOf(id);
    if (!task || task->status != TransferTask::Running)
        return;
    if (total > 0)
        task->totalBytes = total;
    task->transferred =
        qBound<qint64>(0, transferred, task->totalBytes > 0 ? task->totalBytes : transferred);

    Runtime &rt = m_runtime[id];
    if (rt.lastEmit.isValid() && rt.lastEmit.elapsed() < kProgressIntervalMs)
        return;
    rt.lastEmit.restart();
    emitChanged(id);
}

void TransferManager::completeTask(const QString &id)
{
    TransferTask *task = taskOf(id);
    if (!task)
        return;

    auto rt = m_runtime.find(id);
    if (rt != m_runtime.end() && rt->outFile) {
        rt->outFile->close();
        delete rt->outFile;
        rt->outFile = nullptr;
        // 落盘：.part → 正式文件名（Windows 下 rename 不覆盖，先删占位）
        const QString part = task->localPath + kPartSuffix;
        QFile::remove(task->localPath);
        if (!QFile::rename(part, task->localPath)) {
            failTask(id,
                     StorageError(StorageError::Underlying,
                                  tr("无法写入目标文件：%1").arg(task->localPath)));
            return;
        }
    }

    task->status = TransferTask::Completed;
    task->canRetry = false;
    if (task->totalBytes > 0)
        task->transferred = task->totalBytes;
    m_runningId.clear();
    emitChanged(id);
    notifyBusy();
    pump();
}

void TransferManager::failTask(const QString &id, const StorageError &error)
{
    TransferTask *task = taskOf(id);
    if (!task)
        return;

    auto rt = m_runtime.find(id);
    if (rt != m_runtime.end() && rt->outFile) {
        rt->outFile->close();
        delete rt->outFile;
        rt->outFile = nullptr; // 保留 .part 供重试续传
    }
    m_reservedPaths.remove(task->remotePath);

    task->status = TransferTask::Failed;
    task->error = error.kind() == StorageError::UnsupportedProtocol
        ? (task->kind == TransferTask::Upload ? tr("该连接源暂不支持上传")
                                              : tr("该连接源暂不支持下载"))
        : error.userMessage();
    task->canRetry = true;
    m_runningId.clear();
    emitChanged(id);
    notifyBusy();
    pump();
}

void TransferManager::dropTask(const QString &id)
{
    const int row = rowOf(id);
    if (row < 0)
        return;

    const TransferTask task = m_tasks.at(row);
    auto rt = m_runtime.find(id);
    if (rt != m_runtime.end()) {
        if (rt->outFile) {
            rt->outFile->close();
            delete rt->outFile;
            rt->outFile = nullptr;
            QFile::remove(task.localPath + kPartSuffix); // 取消不留残片
        }
        m_runtime.erase(rt);
    }
    m_reservedPaths.remove(task.remotePath);

    if (m_runningId == id)
        m_runningId.clear();

    m_tasks.removeAt(row);
    emit taskRemoved(row);
    notifyBusy();
    pump();
}

void TransferManager::cancel(const QString &id)
{
    TransferTask *task = taskOf(id);
    if (!task)
        return;

    if (task->status == TransferTask::Pending) {
        dropTask(id);
        return;
    }
    if (task->status != TransferTask::Running)
        return;

    auto it = m_runtime.find(id);
    if (it != m_runtime.end() && it->cancelFlag)
        it->cancelFlag->store(true);
    task->status = TransferTask::Cancelled;
    emitChanged(id);
    // 适配器回调到达时发现 Cancelled → dropTask（不走失败分支）
}

void TransferManager::cancelAll()
{
    const QList<TransferTask> snapshot = m_tasks;
    for (const TransferTask &t : snapshot) {
        if (t.status == TransferTask::Pending || t.status == TransferTask::Running)
            cancel(t.id);
    }
}

void TransferManager::retry(const QString &id)
{
    TransferTask *task = taskOf(id);
    if (!task || task->status != TransferTask::Failed)
        return;

    task->status = TransferTask::Pending;
    task->error.clear();
    task->canRetry = false;
    if (task->kind == TransferTask::Upload) {
        task->remotePath.clear(); // 重新探测顺延名
        task->transferred = 0;
    }
    const auto it = m_runtime.find(id);
    if (it != m_runtime.end() && it->cancelFlag)
        it->cancelFlag->store(false);
    emitChanged(id);
    notifyBusy();
    pump();
}

void TransferManager::clearFinished()
{
    for (int i = m_tasks.size() - 1; i >= 0; --i) {
        const TransferTask::Status status = m_tasks.at(i).status;
        if (status == TransferTask::Completed || status == TransferTask::Failed
            || status == TransferTask::Cancelled) {
            const QString id = m_tasks.at(i).id;
            m_runtime.remove(id);
            m_tasks.removeAt(i);
            emit taskRemoved(i);
        }
    }
    notifyBusy();
}

// ---- 工具 ----

void TransferManager::ensureDirectory(StorageAdapter *adapter, const QString &dir,
                                      std::function<void(StorageError)> done)
{
    const QString path = StoragePath::normalize(dir);
    if (!adapter || StoragePath::isRoot(path) || path.isEmpty()) {
        done(StorageError());
        return;
    }

    adapter->stat(path, [this, adapter, path, done](StatResult result) {
        if (result.ok()) {
            if (result.value.isDir)
                done(StorageError());
            else
                done(StorageError(StorageError::InvalidPath,
                                  tr("目标位置已存在同名文件：%1").arg(path)));
            return;
        }
        if (result.error.kind() != StorageError::NotFound) {
            done(result.error);
            return;
        }
        // 父目录先就位，再建自己（WebDAV MKCOL 要求父级存在）
        ensureDirectory(adapter, StoragePath::parent(path), [adapter, path, done](StorageError e) {
            if (!e.isNull()) {
                done(e);
                return;
            }
            adapter->makeDirectory(path, [done](StorageError mk) {
                // 并发创建 / 已存在（409、405）不算失败
                if (!mk.isNull() && mk.httpStatus() != 409 && mk.httpStatus() != 405) {
                    done(mk);
                    return;
                }
                done(StorageError());
            });
        });
    });
}

} // namespace myhub
