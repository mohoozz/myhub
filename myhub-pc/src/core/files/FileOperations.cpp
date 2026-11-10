#include "FileOperations.h"

#include "TrashStore.h"
#include "core/cache/DirectoryCache.h"
#include "core/favorites/FavoriteRepository.h"
#include "core/history/ProgressRepository.h"
#include "core/storage/StorageAdapter.h"
#include "core/storage/StoragePath.h"
#include "core/text/TextCodec.h"
#include "core/transfer/RelayStream.h"
#include "core/utils/AppLogger.h"
#include "core/utils/Formatters.h"
#include "core/utils/MediaType.h"

#include <QDateTime>
#include <QElapsedTimer>
#include <QPair>
#include <QPointer>
#include <QSet>
#include <QTimer>
#include <QVector>

#include <atomic>

namespace myhub {

namespace {

constexpr int kMaxRetries = 2;
constexpr int kRetryDelaysMs[kMaxRetries] = {600, 1200};
constexpr int kMaxNameLength = 120;

/// 与各平台文件系统取交集后仍安全的非法字符（宁严不松，避免「本地能建、SMB 建不了」）
const QString &illegalChars()
{
    static const QString chars = QStringLiteral("/\\:*?\"<>|");
    return chars;
}

/// Windows 设备保留名：即使目标不是本地盘也一并拒绝，跨端体验一致
const QSet<QString> &reservedNames()
{
    static const QSet<QString> names = {
        QStringLiteral("CON"),  QStringLiteral("PRN"),  QStringLiteral("AUX"),
        QStringLiteral("NUL"),  QStringLiteral("COM1"), QStringLiteral("COM2"),
        QStringLiteral("COM3"), QStringLiteral("COM4"), QStringLiteral("COM5"),
        QStringLiteral("COM6"), QStringLiteral("COM7"), QStringLiteral("COM8"),
        QStringLiteral("COM9"), QStringLiteral("LPT1"), QStringLiteral("LPT2"),
        QStringLiteral("LPT3"), QStringLiteral("LPT4"), QStringLiteral("LPT5"),
        QStringLiteral("LPT6"), QStringLiteral("LPT7"), QStringLiteral("LPT8"),
        QStringLiteral("LPT9"),
    };
    return names;
}

StorageError cancelledError()
{
    return StorageError(StorageError::Cancelled, QStringLiteral("连接源已断开"));
}

/// 清理条目对应的 `.meta.json`。
///
/// 元数据缺失不算失败：无 meta 的条目（删除记录已丢失）同样允许彻底删除，
/// 此时 remove 必然返回 NotFound，若照常告警会误导用户以为删除没做干净。
void removeMetaQuietly(StorageAdapter *adapter, const QString &trashName)
{
    if (!adapter)
        return;
    adapter->remove(TrashStore::metaPath(trashName), [](StorageError error) {
        if (error.isNull() || error.kind() == StorageError::NotFound)
            return;
        MH_WARN(Storage, QStringLiteral("回收站元数据清理失败：%1").arg(error.userMessage()));
    });
}

} // namespace

/**
 * 批量删除的共享状态。
 *
 * 跨多轮事件循环，必须堆上并用 shared_ptr 传递；
 * `done` / `failedNames` 分开记录，天然满足「只对未成功的剩余项报失败」。
 */
struct FileOperations::Batch
{
    QPointer<StorageAdapter> adapter;
    QString connectionId;
    QStringList sources;
    QStringList done;
    QStringList failedNames;
    StorageError firstError;
    bool toTrash = true;
    int index = 0;
};

/**
 * 还原的共享状态。
 *
 * 步骤：stat 原父目录 →（缺失则重建）→ 逐个候选名探测冲突 → move 出回收站 → 删 meta。
 * `originalName`/`parentPath` 由 meta 记录的原路径拆出，与删除侧共用同一套命名规则。
 */
struct FileOperations::RestoreOp
{
    QPointer<StorageAdapter> adapter;
    QString connectionId;
    QString trashName;
    QString originalName;
    QString parentPath;
};

/// 彻底删除（回收站清理）的共享状态：逐条删除条目与元数据
struct FileOperations::PurgeOp
{
    QPointer<StorageAdapter> adapter;
    QString connectionId;
    QStringList trashNames;
    QStringList doneNames;
    QStringList failedNames;
    StorageError firstError;
    int index = 0;
};

FileOperations &FileOperations::instance()
{
    static FileOperations service;
    return service;
}

FileOperations::FileOperations(QObject *parent)
    : QObject(parent)
{}

FileOperations::~FileOperations() = default;

QString FileOperations::validateName(const QString &name)
{
    if (name.isEmpty()) {
        return QStringLiteral("名称不能为空");
    }
    if (name == QLatin1String(".") || name == QLatin1String("..")) {
        return QStringLiteral("名称不能是 . 或 ..");
    }
    if (name != name.trimmed()) {
        return QStringLiteral("名称首尾不能有空格");
    }
    if (name.endsWith(QLatin1Char('.'))) {
        return QStringLiteral("名称不能以 . 结尾");
    }

    const QString &bad = illegalChars();
    for (const QChar ch : std::as_const(name)) {
        if (ch.unicode() < 0x20) {
            return QStringLiteral("名称包含不可见的控制字符");
        }
        if (bad.contains(ch)) {
            return QStringLiteral("名称不能包含 / \\ : * ? \" < > |");
        }
    }

    if (name.size() > kMaxNameLength) {
        return QStringLiteral("名称过长（最多 %1 个字符）").arg(kMaxNameLength);
    }

    const QString stem = name.section(QLatin1Char('.'), 0, 0).trimmed().toUpper();
    if (reservedNames().contains(stem)) {
        return QStringLiteral("%1 是系统保留名称").arg(stem);
    }
    return {};
}

QString FileOperations::uniqueName(const QString &name, int attempt)
{
    return TrashStore::candidateName(name, attempt);
}

void FileOperations::createFolder(StorageAdapter *adapter, const QString &connectionId,
                                  const QString &parentPath, const QString &name)
{
    const QString title = QStringLiteral("新建文件夹失败");
    const QString reason = validateName(name);
    if (!reason.isEmpty()) {
        emit failed(title, reason);
        return;
    }
    if (!adapter) {
        emit failed(title, QStringLiteral("连接源不可用，请检查连接状态"));
        return;
    }

    const QString parent = StoragePath::normalize(parentPath);
    const QString target = StoragePath::join(parent, name);
    begin();

    QPointer<StorageAdapter> guard(adapter);
    guard->stat(target,
                [this, guard, connectionId, parent, target, name, title](StatResult result) {
                    if (!guard) {
                        end();
                        return;
                    }
                    // 已存在时 mkpath 会静默成功，用户会以为按钮失灵 —— 必须当面拒绝
                    if (result.ok()) {
                        end();
                        emit failed(title, QStringLiteral("同名条目已存在：%1").arg(name));
                        return;
                    }
                    runWithRetry(
                        [guard, target](std::function<void(StorageError)> done) {
                            if (guard) {
                                guard->makeDirectory(target, std::move(done));
                            } else {
                                done(cancelledError());
                            }
                        },
                        [this, connectionId, parent, target, title](StorageError error) {
                            end();
                            if (!error.isNull()) {
                                emit failed(title, error.userMessage());
                                return;
                            }
                            DirectoryCache::instance().invalidate(connectionId, parent);
                            emit created(parent, target, true);
                        });
                });
}

void FileOperations::rename(StorageAdapter *adapter, const QString &connectionId,
                            const QString &path, const QString &newName)
{
    const QString title = QStringLiteral("重命名失败");
    const QString reason = validateName(newName);
    if (!reason.isEmpty()) {
        emit failed(title, reason);
        return;
    }
    if (!adapter) {
        emit failed(title, QStringLiteral("连接源不可用，请检查连接状态"));
        return;
    }

    const QString source = StoragePath::normalize(path);
    if (StoragePath::isRoot(source)) {
        emit failed(title, QStringLiteral("根目录不可重命名"));
        return;
    }

    const QString parent = StoragePath::parent(source);
    const QString target = StoragePath::join(parent, newName);
    if (StoragePath::normalize(target) == source) {
        return; // 名字没变：不是错误，也不必惊动网络
    }

    begin();
    QPointer<StorageAdapter> guard(adapter);
    guard->stat(
        target,
        [this, guard, connectionId, source, target, parent, newName, title](StatResult result) {
            if (!guard) {
                end();
                return;
            }
            if (result.ok()) {
                end();
                emit failed(title, QStringLiteral("同名条目已存在：%1").arg(newName));
                return;
            }
            runWithRetry(
                [guard, source, target](std::function<void(StorageError)> done) {
                    if (guard) {
                        guard->move(source, target, std::move(done));
                    } else {
                        done(cancelledError());
                    }
                },
                [this, connectionId, source, target, parent, title](StorageError error) {
                    end();
                    if (!error.isNull()) {
                        emit failed(title, error.userMessage());
                        return;
                    }
                    ProgressRepository::instance().renamePath(connectionId, source, target);
                    FavoriteRepository::instance().renamePath(connectionId, source, target);
                    DirectoryCache::instance().invalidate(connectionId, parent);
                    DirectoryCache::instance().invalidate(connectionId,
                                                          StoragePath::parent(target));
                    emit renamed(source, target);
                });
        });
}

void FileOperations::removeToTrash(StorageAdapter *adapter, const QString &connectionId,
                                   const QStringList &paths)
{
    const QString title = QStringLiteral("删除失败");
    QStringList targets;
    for (const QString &path : paths) {
        const QString normalized = StoragePath::normalize(path);
        // 根目录、回收站自身及其内部条目一律不参与删除
        if (normalized.isEmpty() || StoragePath::isRoot(normalized)
            || StoragePath::isDescendantOf(normalized, TrashStore::trashDir())) {
            continue;
        }
        targets.append(normalized);
    }
    if (targets.isEmpty()) {
        return;
    }
    if (!adapter) {
        emit failed(title, QStringLiteral("连接源不可用，请检查连接状态"));
        return;
    }
    if (!adapter->supportsTrash()) {
        emit failed(title, QStringLiteral("该连接源不支持回收站，可改用「永久删除」"));
        return;
    }

    auto batch = std::make_shared<Batch>();
    batch->adapter = adapter;
    batch->connectionId = connectionId;
    batch->sources = targets;
    batch->toTrash = true;
    begin();

    // 回收站目录按需创建（幂等）。失败不在此处拦：真正的移动会给出具体原因
    QPointer<StorageAdapter> guard(adapter);
    guard->makeDirectory(TrashStore::trashDir(), [this, batch, guard](StorageError error) {
        if (!guard) {
            end();
            return;
        }
        if (!error.isNull()) {
            MH_WARN(Storage, QStringLiteral("回收站目录创建失败：%1").arg(error.userMessage()));
        }
        startRemove(batch);
    });
}

void FileOperations::removePermanently(StorageAdapter *adapter, const QString &connectionId,
                                       const QStringList &paths)
{
    const QString title = QStringLiteral("永久删除失败");
    QStringList targets;
    for (const QString &path : paths) {
        const QString normalized = StoragePath::normalize(path);
        if (normalized.isEmpty() || StoragePath::isRoot(normalized)) {
            continue;
        }
        targets.append(normalized);
    }
    if (targets.isEmpty()) {
        return;
    }
    if (!adapter) {
        emit failed(title, QStringLiteral("连接源不可用，请检查连接状态"));
        return;
    }

    auto batch = std::make_shared<Batch>();
    batch->adapter = adapter;
    batch->connectionId = connectionId;
    batch->sources = targets;
    batch->toTrash = false;
    begin();
    startRemove(batch);
}

void FileOperations::startRemove(const BatchPtr &batch)
{
    if (batch->index >= batch->sources.size()) {
        finishRemove(batch);
        return;
    }
    const QString source = batch->sources.at(batch->index);
    if (batch->toTrash) {
        probeTrashName(batch, source, StoragePath::fileName(source), 0);
    } else {
        removePermanentItem(batch, source);
    }
}

void FileOperations::probeTrashName(const BatchPtr &batch, const QString &src,
                                    const QString &originalName, int attempt)
{
    QPointer<StorageAdapter> guard = batch->adapter;
    if (!guard) {
        advanceRemove(batch, src, cancelledError());
        return;
    }
    if (attempt > TrashStore::kMaxNameAttempts) {
        advanceRemove(batch, src,
                      StorageError(StorageError::Underlying,
                                   QStringLiteral("回收站内同名条目过多，无法归档")));
        return;
    }

    const QString candidate = TrashStore::candidateName(originalName, attempt);
    guard->stat(TrashStore::entryPath(candidate),
                [this, batch, src, originalName, candidate, attempt](StatResult result) {
                    // 同名已存在：顺延序号，绝不覆盖别人删进来的文件
                    if (result.ok()) {
                        probeTrashName(batch, src, originalName, attempt + 1);
                        return;
                    }
                    moveIntoTrash(batch, src, candidate);
                });
}

void FileOperations::moveIntoTrash(const BatchPtr &batch, const QString &src,
                                   const QString &trashName)
{
    QPointer<StorageAdapter> guard = batch->adapter;
    if (!guard) {
        advanceRemove(batch, src, cancelledError());
        return;
    }
    const QString destination = TrashStore::entryPath(trashName);
    runWithRetry(
        [guard, src, destination](std::function<void(StorageError)> done) {
            if (guard) {
                guard->move(src, destination, std::move(done));
            } else {
                done(cancelledError());
            }
        },
        [this, batch, src, trashName](StorageError error) {
            if (!error.isNull()) {
                advanceRemove(batch, src, error);
                return;
            }
            writeTrashMeta(batch, src, trashName);
            advanceRemove(batch, src, StorageError());
        });
}

void FileOperations::writeTrashMeta(const BatchPtr &batch, const QString &src,
                                    const QString &trashName)
{
    if (!batch->adapter) {
        return;
    }
    TrashStore::Meta meta;
    meta.connectionId = batch->connectionId;
    meta.originalPath = src;
    meta.deletedAtMs = QDateTime::currentMSecsSinceEpoch();

    // 元数据失败**不回滚**已完成的移动：宁可留一个无主条目，也不能把用户文件弄丢
    batch->adapter->writeFile(
        TrashStore::metaPath(trashName), TrashStore::encodeMeta(meta), [src](StorageError error) {
            if (!error.isNull()) {
                MH_WARN(
                    Storage,
                    QStringLiteral("回收站元数据写入失败（%1）：%2").arg(src, error.userMessage()));
            }
        });
}

void FileOperations::removePermanentItem(const BatchPtr &batch, const QString &src)
{
    QPointer<StorageAdapter> guard = batch->adapter;
    if (!guard) {
        advanceRemove(batch, src, cancelledError());
        return;
    }
    runWithRetry(
        [guard, src](std::function<void(StorageError)> done) {
            if (guard) {
                guard->remove(src, std::move(done));
            } else {
                done(cancelledError());
            }
        },
        [this, batch, src](StorageError error) { advanceRemove(batch, src, error); });
}

void FileOperations::advanceRemove(const BatchPtr &batch, const QString &src,
                                   const StorageError &error)
{
    if (error.isNull()) {
        batch->done.append(src);
    } else {
        batch->failedNames.append(StoragePath::fileName(src));
        if (batch->firstError.isNull()) {
            batch->firstError = error;
        }
    }
    ++batch->index;
    startRemove(batch);
}

void FileOperations::finishRemove(const BatchPtr &batch)
{
    for (const QString &path : batch->done) {
        ProgressRepository::instance().removeSubtree(batch->connectionId, path);
        FavoriteRepository::instance().removeSubtree(batch->connectionId, path);
        DirectoryCache::instance().invalidate(batch->connectionId, StoragePath::parent(path));
    }
    end();

    if (!batch->done.isEmpty()) {
        emit removed(batch->done, batch->toTrash);
    }
    if (!batch->failedNames.isEmpty()) {
        QString reason = batch->firstError.isNull() ? QStringLiteral("未知原因")
                                                    : batch->firstError.userMessage();
        // 部分成功时必须点名剩下的，否则用户会重复删除已移走的项
        if (!batch->done.isEmpty() || batch->failedNames.size() > 1) {
            reason +=
                QStringLiteral("\n未完成：%1").arg(batch->failedNames.join(QStringLiteral("、")));
        }
        emit failed(batch->toTrash ? QStringLiteral("删除失败") : QStringLiteral("永久删除失败"),
                    reason);
    }
}

void FileOperations::restoreFromTrash(StorageAdapter *adapter, const QString &connectionId,
                                      const QString &trashName, const QString &originalPath)
{
    const QString title = QStringLiteral("还原失败");
    if (!adapter) {
        emit failed(title, QStringLiteral("连接源不可用，请检查连接状态"));
        return;
    }
    if (trashName.isEmpty() || originalPath.isEmpty()) {
        emit failed(title, QStringLiteral("该条目缺少删除记录（元数据丢失），无法还原"));
        return;
    }

    auto op = std::make_shared<RestoreOp>();
    op->adapter = adapter;
    op->connectionId = connectionId;
    op->trashName = trashName;
    op->originalName = StoragePath::fileName(originalPath);
    op->parentPath = StoragePath::parent(originalPath);
    begin();
    startRestore(op);
}

void FileOperations::startRestore(const RestoreOpPtr &op)
{
    QPointer<StorageAdapter> guard = op->adapter;
    if (!guard) {
        failRestore(op, cancelledError());
        return;
    }

    // 原父目录可能已被整体删除：先探测，缺失则重建（还原单个文件不要求手工建目录）
    guard->stat(op->parentPath, [this, op](StatResult result) {
        QPointer<StorageAdapter> guard = op->adapter;
        if (!guard) {
            failRestore(op, cancelledError());
            return;
        }
        if (result.ok()) {
            if (!result.value.isDir) {
                failRestore(
                    op,
                    StorageError(StorageError::InvalidPath,
                                 QStringLiteral("原路径的父级已不是目录：%1").arg(op->parentPath)));
                return;
            }
            probeRestoreTarget(op, 0);
            return;
        }
        if (result.error.kind() != StorageError::NotFound) {
            failRestore(op, result.error);
            return;
        }
        guard->makeDirectory(op->parentPath, [this, op](StorageError error) {
            if (!error.isNull()) {
                failRestore(
                    op,
                    StorageError(error.kind(),
                                 QStringLiteral("原目录已不存在且无法重建：%1").arg(op->parentPath),
                                 error.httpStatus()));
                return;
            }
            probeRestoreTarget(op, 0);
        });
    });
}

void FileOperations::probeRestoreTarget(const RestoreOpPtr &op, int attempt)
{
    QPointer<StorageAdapter> guard = op->adapter;
    if (!guard) {
        failRestore(op, cancelledError());
        return;
    }
    if (attempt > TrashStore::kMaxNameAttempts) {
        failRestore(op,
                    StorageError(StorageError::Underlying,
                                 QStringLiteral("原目录内同名条目过多，无法还原")));
        return;
    }

    const QString candidate = TrashStore::candidateName(op->originalName, attempt);
    const QString target = StoragePath::join(op->parentPath, candidate);
    guard->stat(target, [this, op, target, attempt](StatResult result) {
        if (result.ok()) {
            // 目标处已有同名条目：顺延序号，绝不覆盖（与删除侧规则一致）
            probeRestoreTarget(op, attempt + 1);
            return;
        }
        if (result.error.kind() != StorageError::NotFound) {
            failRestore(op, result.error);
            return;
        }
        moveOutOfTrash(op, target);
    });
}

void FileOperations::moveOutOfTrash(const RestoreOpPtr &op, const QString &targetPath)
{
    QPointer<StorageAdapter> guard = op->adapter;
    if (!guard) {
        failRestore(op, cancelledError());
        return;
    }
    const QString source = TrashStore::entryPath(op->trashName);
    runWithRetry(
        [guard, source, targetPath](std::function<void(StorageError)> done) {
            if (guard) {
                guard->move(source, targetPath, std::move(done));
            } else {
                done(cancelledError());
            }
        },
        [this, op, targetPath](StorageError error) {
            if (!error.isNull()) {
                failRestore(op, error);
                return;
            }
            // 元数据清理失败不影响还原结果：残留 meta 只会让条目变成「无主」，不会丢文件
            removeMetaQuietly(op->adapter, op->trashName);
            DirectoryCache::instance().invalidate(op->connectionId, op->parentPath);
            DirectoryCache::instance().invalidate(op->connectionId, TrashStore::trashDir());
            end();
            emit restored(op->connectionId, op->trashName, targetPath);
        });
}

void FileOperations::failRestore(const RestoreOpPtr &op, const StorageError &error)
{
    end();
    const QString name = op->originalName.isEmpty() ? op->trashName : op->originalName;
    emit failed(QStringLiteral("还原失败"),
                QStringLiteral("%1：%2").arg(name, error.userMessage()));
}

void FileOperations::purgeTrash(StorageAdapter *adapter, const QString &connectionId,
                                const QStringList &trashNames)
{
    const QString title = QStringLiteral("彻底删除失败");
    if (!adapter) {
        emit failed(title, QStringLiteral("连接源不可用，请检查连接状态"));
        return;
    }
    if (trashNames.isEmpty()) {
        return;
    }

    auto op = std::make_shared<PurgeOp>();
    op->adapter = adapter;
    op->connectionId = connectionId;
    op->trashNames = trashNames;
    begin();
    startPurge(op);
}

void FileOperations::startPurge(const PurgeOpPtr &op)
{
    if (op->index >= op->trashNames.size()) {
        finishPurge(op);
        return;
    }
    purgeItem(op);
}

void FileOperations::purgeItem(const PurgeOpPtr &op)
{
    QPointer<StorageAdapter> guard = op->adapter;
    if (!guard) {
        advancePurge(op, cancelledError());
        return;
    }
    const QString trashName = op->trashNames.at(op->index);
    runWithRetry(
        [guard, trashName](std::function<void(StorageError)> done) {
            if (guard) {
                guard->remove(TrashStore::entryPath(trashName), std::move(done));
            } else {
                done(cancelledError());
            }
        },
        [this, op](StorageError error) { advancePurge(op, error); });
}

void FileOperations::advancePurge(const PurgeOpPtr &op, const StorageError &error)
{
    const QString trashName = op->trashNames.at(op->index);
    if (error.isNull()) {
        op->doneNames.append(trashName);
        removeMetaQuietly(op->adapter, trashName);
    } else {
        op->failedNames.append(trashName);
        if (op->firstError.isNull()) {
            op->firstError = error;
        }
    }
    ++op->index;
    startPurge(op);
}

void FileOperations::finishPurge(const PurgeOpPtr &op)
{
    if (!op->doneNames.isEmpty()) {
        DirectoryCache::instance().invalidate(op->connectionId, TrashStore::trashDir());
    }
    end();

    if (!op->doneNames.isEmpty()) {
        emit purged(op->connectionId, op->doneNames);
    }
    if (!op->failedNames.isEmpty()) {
        QString reason =
            op->firstError.isNull() ? QStringLiteral("未知原因") : op->firstError.userMessage();
        reason += QStringLiteral("\n未完成：%1").arg(op->failedNames.join(QStringLiteral("、")));
        emit failed(QStringLiteral("彻底删除失败"), reason);
    }
}

// ==================== 文本在线读写（PC-103）====================

namespace {

/// 在线编辑的体积上限：超过即拒绝（不做静默截断，截断等于丢用户内容）
constexpr qint64 kMaxEditableTextBytes = qint64(8) * 1024 * 1024;

} // namespace

void FileOperations::loadText(StorageAdapter *adapter, const QString &connectionId,
                              const QString &path)
{
    const QString title = QStringLiteral("打开文本失败");
    if (!adapter) {
        emit failed(title, QStringLiteral("连接源不可用，请检查连接状态"));
        return;
    }
    const QString source = StoragePath::normalize(path);
    if (source.isEmpty() || StoragePath::isRoot(source)) {
        emit failed(title, QStringLiteral("无法打开该路径"));
        return;
    }

    begin();
    QPointer<StorageAdapter> guard(adapter);
    guard->stat(source, [this, guard, connectionId, source, title](StatResult result) {
        if (!guard) {
            end();
            return;
        }
        if (!result.ok()) {
            end();
            emit failed(title, result.error.userMessage());
            return;
        }
        const FileEntry entry = result.value;
        if (entry.isDir) {
            end();
            emit failed(title, QStringLiteral("该条目是文件夹，不能按文本打开"));
            return;
        }
        if (entry.size > kMaxEditableTextBytes) {
            end();
            emit failed(title,
                        QStringLiteral("文件过大（%1 MB），暂不支持在线编辑（上限 %2 MB）")
                            .arg(QString::number(double(entry.size) / (1024.0 * 1024.0), 'f', 1),
                                 QString::number(kMaxEditableTextBytes / (qint64(1024) * 1024))));
            return;
        }

        guard->readRange(
            source, std::nullopt, std::nullopt,
            [this, guard, connectionId, source, title](DataResult data) {
                end();
                if (!data.ok()) {
                    if (guard) {
                        emit failed(title, data.error.userMessage());
                    }
                    return;
                }
                const TextCodec::Decoded decoded = TextCodec::decode(data.value);
                if (decoded.hadErrors) {
                    MH_WARN(Storage,
                            QStringLiteral("文本含无法解码的字节，已用替换符兜底：%1").arg(source));
                }
                emit textLoaded(connectionId, source, decoded.text,
                                TextCodec::name(decoded.encoding), decoded.hadBom);
            });
    });
}

void FileOperations::saveText(StorageAdapter *adapter, const QString &connectionId,
                              const QString &path, const QString &text, const QString &encodingName,
                              bool withBom)
{
    const QString title = QStringLiteral("保存失败");
    if (!adapter) {
        emit failed(title, QStringLiteral("连接源不可用，请检查连接状态"));
        return;
    }
    const QString target = StoragePath::normalize(path);
    if (target.isEmpty() || StoragePath::isRoot(target)) {
        emit failed(title, QStringLiteral("无法保存到该路径"));
        return;
    }
    const qint64 bytes = qint64(text.size()) * 4;
    if (bytes > kMaxEditableTextBytes) {
        emit failed(title, QStringLiteral("内容过大，暂不支持在线保存"));
        return;
    }

    // 纪律：沿用原编码；原编码表示不了新字符时回退 UTF-8（不写问号、不静默丢字）
    const TextCodec::Encoding encoding = TextCodec::fromName(encodingName);
    const TextCodec::Encoded encoded = TextCodec::encode(
        text, encoding == TextCodec::Unknown ? TextCodec::Utf8 : encoding, withBom);

    begin();
    QPointer<StorageAdapter> guard(adapter);
    runWithRetry(
        [guard, target, encoded](std::function<void(StorageError)> done) {
            if (guard) {
                guard->writeFile(target, encoded.data, std::move(done));
            } else {
                done(cancelledError());
            }
        },
        [this, connectionId, target, encoded](StorageError error) {
            end();
            if (!error.isNull()) {
                emit failed(QStringLiteral("保存失败"), error.userMessage());
                return;
            }
            DirectoryCache::instance().invalidate(connectionId, StoragePath::parent(target));
            emit textSaved(connectionId, target, encoded.fellBackToUtf8,
                           TextCodec::name(encoded.encoding));
        });
}

// ==================== 属性面板（PC-110）====================

void FileOperations::inspect(StorageAdapter *adapter, const QString &connectionId,
                             const QString &path)
{
    const QString target = StoragePath::normalize(path);
    if (!adapter) {
        emit inspectFailed(connectionId, target, QStringLiteral("连接源不可用，请检查连接状态"));
        return;
    }
    if (target.isEmpty() || StoragePath::isRoot(target)) {
        emit inspectFailed(connectionId, target, QStringLiteral("根目录没有可展示的属性"));
        return;
    }

    const QString fallbackName = StoragePath::baseName(target);
    QPointer<StorageAdapter> guard(adapter);
    // 现场 stat：目录行可能来自缓存，大小/修改时间必须以此刻为准（PC-110）
    guard->stat(target, [this, guard, connectionId, target, fallbackName](StatResult result) {
        if (!guard) {
            return;
        }
        if (!result.ok()) {
            emit inspectFailed(connectionId, target, result.error.userMessage());
            return;
        }

        const FileEntry &entry = result.value;
        const QString entryPath = entry.path.isEmpty() ? target : entry.path;
        const MediaType::Kind kind = MediaType::fromPath(entryPath, entry.isDir);

        QVariantMap info;
        info.insert(QStringLiteral("name"), entry.name.isEmpty() ? fallbackName : entry.name);
        info.insert(QStringLiteral("filePath"), target);
        info.insert(QStringLiteral("parentPath"), StoragePath::parent(target));
        info.insert(QStringLiteral("connectionId"), connectionId);
        info.insert(QStringLiteral("isDir"), entry.isDir);
        info.insert(QStringLiteral("ext"), entry.ext);
        info.insert(QStringLiteral("size"), entry.size);
        info.insert(QStringLiteral("sizeText"),
                    entry.isDir ? QString() : Formatters::fileSize(entry.size));
        info.insert(QStringLiteral("modTime"), entry.modTime);
        info.insert(QStringLiteral("modTimeText"), Formatters::absoluteTime(entry.modTime));
        info.insert(QStringLiteral("mediaKind"), MediaType::badgeId(kind));
        info.insert(QStringLiteral("mediaKindText"), MediaType::displayName(kind));
        info.insert(QStringLiteral("textEditable"),
                    MediaType::isEditableText(entryPath, entry.isDir));

        // 阅读进度：查不到就是没读过（不显示 0% 的假进度）
        ProgressRecord record;
        const bool hasProgress = ProgressRepository::instance().find(connectionId, target, &record);
        info.insert(QStringLiteral("hasProgress"), hasProgress);
        if (hasProgress) {
            info.insert(QStringLiteral("progressPercent"), record.percent);
            info.insert(QStringLiteral("progressText"), Formatters::percent(record.percent));
            info.insert(QStringLiteral("finished"), record.finished);
            info.insert(QStringLiteral("resumeMs"), record.positionMs());
            info.insert(QStringLiteral("durationMs"), record.durationMs());
            info.insert(QStringLiteral("lastReadText"),
                        Formatters::relativeTime(QDateTime::fromMSecsSinceEpoch(record.updatedAt)));
        }

        emit inspected(connectionId, target, info);
    });
}

// ==================== 移动 / 复制（PC-104）====================

namespace {

/// 同名顺延的最大尝试次数（50 个候选足够，超出说明目标目录已严重冲突）
constexpr int kMaxNameAttempts = 50;
constexpr qint64 kRelayChunkBytes = qint64(1024) * 1024;
/// 中转缓冲上限：超过就等消费侧吃掉一些再拉，避免把整个大文件读进内存
constexpr qint64 kRelayHighWaterBytes = qint64(4) * 1024 * 1024;
/// 进度上报节流：中转进度来自后台线程，过密既浪费信号也拖慢 UI
constexpr qint64 kProgressIntervalMs = 100;

StorageError itemCancelledError()
{
    return StorageError(StorageError::Cancelled, QStringLiteral("操作已取消"));
}

} // namespace

/**
 * 移动/复制的共享状态。
 *
 * 跨多轮事件循环（stat → 冲突探测 → 逐项中转），必须堆上并用 shared_ptr 传递。
 * `cancel` 用原子标志：取消可能来自 UI 线程，而探针在中转的阻塞读侧被轮询。
 */
struct FileOperations::TransferOp
{
    QPointer<StorageAdapter> source;
    QPointer<StorageAdapter> destination;
    QString sourceConnectionId;
    QString targetConnectionId;
    QString targetDir;
    QStringList pending;                    ///< 还没开始的顶层源路径
    QStringList createdPaths;               ///< 目标处实际落点
    QVector<QPair<QString, QString>> moves; ///< 移动成功的一对（源 → 目标），供改写阅读记录
    QStringList failures;                   ///< 「名称：原因」
    QString currentName;
    qint64 currentTotal = 0;
    QElapsedTimer lastEmit; ///< 进度节流（只有一个中转在跑，无需加锁）
    int done = 0;
    int total = 0;
    bool copy = false;
    bool finished = false;
    std::shared_ptr<std::atomic_bool> cancel = std::make_shared<std::atomic_bool>(false);
};

bool FileOperations::moveOrCopy(const TransferRequest &request)
{
    const QString title = request.copy ? QStringLiteral("复制失败") : QStringLiteral("移动失败");
    if (m_transferring) {
        emit failed(title, QStringLiteral("已有移动/复制任务在进行中，请稍候"));
        return false;
    }
    if (!request.source || !request.target.adapter) {
        emit failed(title, QStringLiteral("连接源不可用，请检查连接状态"));
        return false;
    }

    QStringList paths;
    for (const QString &path : request.paths) {
        const QString normalized = StoragePath::normalize(path);
        // 根与回收站不参与移动/复制
        if (normalized.isEmpty() || StoragePath::isRoot(normalized)
            || StoragePath::isDescendantOf(normalized, TrashStore::trashDir())) {
            continue;
        }
        paths.append(normalized);
    }
    if (paths.isEmpty()) {
        emit failed(title, QStringLiteral("没有可操作的文件"));
        return false;
    }

    auto op = std::make_shared<TransferOp>();
    op->source = request.source;
    op->destination = request.target.adapter;
    op->sourceConnectionId = request.sourceConnectionId;
    op->targetConnectionId = request.target.connectionId;
    op->targetDir = StoragePath::normalize(request.target.directory);
    if (op->targetDir.isEmpty()) {
        op->targetDir = QStringLiteral("/");
    }
    op->pending = paths;
    op->total = int(paths.size());
    op->copy = request.copy;
    op->currentName = StoragePath::fileName(paths.first());

    m_transferring = true;
    m_transferOp = op;
    begin();
    startTransferItem(op);
    return true;
}

void FileOperations::cancelTransfer()
{
    if (m_transferOp) {
        m_transferOp->cancel->store(true);
    }
}

void FileOperations::startTransferItem(const TransferOpPtr &op)
{
    if (op->finished) {
        return;
    }
    if (op->cancel->load() || !op->source || !op->destination) {
        finishTransfer(op);
        return;
    }
    if (op->pending.isEmpty()) {
        finishTransfer(op);
        return;
    }

    const QString src = op->pending.takeFirst();
    op->source->stat(src, [this, op, src](StatResult result) {
        if (op->finished) {
            return;
        }
        if (!result.ok()) {
            failTransferItem(op, src, result.error);
            startTransferItem(op);
            return;
        }
        FileEntry entry = result.value;
        entry.path = src;
        if (entry.name.isEmpty()) {
            entry.name = StoragePath::fileName(src);
        }
        planTransferItem(op, src, entry, 0);
    });
}

void FileOperations::planTransferItem(const TransferOpPtr &op, const QString &src,
                                      const FileEntry &entry, int attempt)
{
    if (op->finished) {
        return;
    }
    if (op->cancel->load()) {
        startTransferItem(op);
        return;
    }

    // 放进自己内部会无限递归（或直接失败），提前给出可读原因
    if (StoragePath::isDescendantOf(op->targetDir, src)) {
        failTransferItem(op, src,
                         StorageError(StorageError::InvalidPath,
                                      QStringLiteral("不能把条目移动/复制到它自己内部")));
        startTransferItem(op);
        return;
    }

    // 同目录移动 = 无操作（不是错误，也不必惊动网络）
    if (!op->copy && StoragePath::normalize(StoragePath::parent(src)) == op->targetDir) {
        ++op->done;
        emit transferProgress(op->done, op->total, entry.name, entry.size, entry.size);
        startTransferItem(op);
        return;
    }

    if (attempt >= kMaxNameAttempts) {
        failTransferItem(op, src,
                         StorageError(StorageError::Underlying,
                                      QStringLiteral("目标目录同名条目过多，无法确定可用名称")));
        startTransferItem(op);
        return;
    }

    const QString candidate = StoragePath::join(op->targetDir, uniqueName(entry.name, attempt));
    op->destination->stat(candidate, [this, op, src, entry, candidate, attempt](StatResult probed) {
        if (op->finished) {
            return;
        }
        if (probed.ok()) {
            planTransferItem(op, src, entry, attempt + 1); // 同名：顺延
            return;
        }
        if (probed.error.kind() != StorageError::NotFound) {
            failTransferItem(op, src, probed.error);
            startTransferItem(op);
            return;
        }
        runTransferItem(op, src, candidate, entry);
    });
}

void FileOperations::runTransferItem(const TransferOpPtr &op, const QString &src,
                                     const QString &dst, const FileEntry &entry)
{
    op->currentName = entry.name;
    op->currentTotal = entry.size;
    emit transferProgress(op->done, op->total, entry.name, 0, entry.size);

    transferTree(op, src, dst, entry, [this, op, src, dst, entry](StorageError error) {
        if (op->finished) {
            return;
        }
        if (!error.isNull()) {
            failTransferItem(op, src, error);
            startTransferItem(op);
            return;
        }

        // 移动：跨源还要把源条目删掉（同源 move 已由适配器完成搬移）
        const bool needRemoveSource = !op->copy && (op->source != op->destination);
        auto complete = [this, op, src, dst, entry](StorageError removeError) {
            if (op->finished) {
                return;
            }
            if (!removeError.isNull()) {
                failTransferItem(op, src, removeError);
                startTransferItem(op);
                return;
            }
            op->createdPaths.append(dst);
            if (!op->copy) {
                op->moves.append(qMakePair(src, dst));
            }
            ++op->done;
            emit transferProgress(op->done, op->total, entry.name, entry.size, entry.size);
            startTransferItem(op);
        };

        if (needRemoveSource && op->source) {
            op->source->remove(
                src, [complete](StorageError removeError) mutable { complete(removeError); });
            return;
        }
        complete(StorageError());
    });
}

void FileOperations::transferTree(const TransferOpPtr &op, const QString &src, const QString &dst,
                                  const FileEntry &entry, std::function<void(StorageError)> done)
{
    if (!op->source || !op->destination) {
        done(itemCancelledError());
        return;
    }
    if (op->cancel->load()) {
        done(itemCancelledError());
        return;
    }

    const bool sameAdapter = (op->source == op->destination);

    if (!entry.isDir) {
        if (sameAdapter) {
            runWithRetry(
                [op, src, dst](std::function<void(StorageError)> cb) {
                    if (!op->destination) {
                        cb(itemCancelledError());
                        return;
                    }
                    if (op->copy) {
                        op->destination->copy(src, dst, std::move(cb));
                    } else {
                        op->destination->move(src, dst, std::move(cb));
                    }
                },
                std::move(done));
            return;
        }
        relayFile(op, src, dst, entry.size, std::move(done));
        return;
    }

    // 同源移动整目录：适配器一条指令即可（本地 rename / WebDAV MOVE）
    if (sameAdapter && !op->copy) {
        runWithRetry(
            [op, src, dst](std::function<void(StorageError)> cb) {
                if (op->destination) {
                    op->destination->move(src, dst, std::move(cb));
                } else {
                    cb(itemCancelledError());
                }
            },
            std::move(done));
        return;
    }

    // 其余（同源复制目录 / 跨源任意目录）统一递归：才有统一进度与同名顺延
    runWithRetry(
        [op, dst](std::function<void(StorageError)> cb) {
            if (op->destination) {
                op->destination->makeDirectory(dst, std::move(cb));
            } else {
                cb(itemCancelledError());
            }
        },
        [this, op, src, dst, done = std::move(done)](StorageError mkError) mutable {
            if (op->finished) {
                return;
            }
            if (!mkError.isNull()) {
                done(mkError);
                return;
            }
            if (!op->source) {
                done(itemCancelledError());
                return;
            }
            op->source->list(
                src, [this, op, src, dst, done = std::move(done)](ListResult listed) mutable {
                    if (op->finished) {
                        return;
                    }
                    if (!listed.ok()) {
                        done(listed.error);
                        return;
                    }
                    transferChildren(op, src, dst, listed.value, 0, std::move(done));
                });
        });
}

void FileOperations::transferChildren(const TransferOpPtr &op, const QString &srcDir,
                                      const QString &dstDir, const FileEntryList &children,
                                      int index, std::function<void(StorageError)> done)
{
    if (op->finished) {
        return;
    }
    if (op->cancel->load()) {
        done(itemCancelledError());
        return;
    }
    if (index >= int(children.size())) {
        done(StorageError());
        return;
    }

    // 只在本函数内同步使用 `child`（transferTree 不保留 entry 引用），故取引用避免拷贝
    const FileEntry &child = children.at(index);
    transferTree(op, StoragePath::join(srcDir, child.name), StoragePath::join(dstDir, child.name),
                 child, [this, op, srcDir, dstDir, children, index, done](StorageError error) {
                     if (!error.isNull()) {
                         done(error);
                         return;
                     }
                     transferChildren(op, srcDir, dstDir, children, index + 1, done);
                 });
}

void FileOperations::relayFile(const TransferOpPtr &op, const QString &src, const QString &dst,
                               qint64 size, std::function<void(StorageError)> done)
{
    if (!op->source || !op->destination) {
        done(itemCancelledError());
        return;
    }

    auto *stream = new RelayStream(size, this);
    QPointer<RelayStream> guard(stream);
    // 先写 `.myhub-part` 再改名：取消/失败不会在目标处留下半个文件（与下载共用后缀）
    const QString partPath = dst + QStringLiteral(".myhub-part");

    op->destination->writeFrom(
        partPath, stream, size,
        [this, op](qint64 sent) {
            // 进度回调可能在后台线程（本地适配器线程池），节流后投递回 GUI 线程
            if (op->lastEmit.isValid() && op->lastEmit.elapsed() < kProgressIntervalMs) {
                return;
            }
            op->lastEmit.start();
            const QString name = op->currentName;
            QMetaObject::invokeMethod(
                this,
                [this, op, sent, name]() {
                    if (op->finished) {
                        return;
                    }
                    emit transferProgress(op->done, op->total, name, sent, op->currentTotal);
                },
                Qt::QueuedConnection);
        },
        [op]() { return op->cancel->load(); },
        [this, op, stream, partPath, dst, done = std::move(done)](StorageError error) mutable {
            // 下游结束：让上游的追加立刻停手，避免管道一直等
            if (error.isNull()) {
                stream->finish();
            } else {
                stream->abort(error);
            }
            stream->deleteLater();

            if (!error.isNull()) {
                // 半成品清理（失败/取消都不该留下 .myhub-part）
                if (op->destination) {
                    op->destination->remove(partPath, [](StorageError) {});
                }
                done(error);
                return;
            }
            if (!op->destination) {
                done(itemCancelledError());
                return;
            }
            op->destination->move(partPath, dst,
                                  [done](StorageError moveError) mutable { done(moveError); });
        });

    if (guard && !op->cancel->load()) {
        pullRelayChunk(op, src, guard, 0, size);
    }
}

void FileOperations::pullRelayChunk(const TransferOpPtr &op, const QString &src,
                                    RelayStream *stream, qint64 offset, qint64 total)
{
    if (!stream) {
        return;
    }
    if (op->cancel->load()) {
        stream->abort(itemCancelledError());
        return;
    }
    if (offset >= total) {
        stream->finish();
        return;
    }
    // 背压：先让消费侧吃掉一些再继续拉
    if (stream->bufferedBytes() >= kRelayHighWaterBytes) {
        QPointer<RelayStream> guard(stream);
        QTimer::singleShot(20, this, [this, op, src, guard, offset, total]() {
            if (guard)
                pullRelayChunk(op, src, guard, offset, total);
        });
        return;
    }
    if (!op->source) {
        stream->abort(itemCancelledError());
        return;
    }

    const qint64 end = qMin(total, offset + kRelayChunkBytes) - 1;
    QPointer<RelayStream> guard(stream);
    op->source->readRange(
        src, offset, end, [this, op, src, guard, offset, total](DataResult result) mutable {
            if (!guard) {
                return;
            }
            if (!result.ok()) {
                guard->abort(result.error);
                return;
            }
            const qint64 got = result.value.size();
            if (got <= 0) {
                guard->abort(StorageError(StorageError::Underlying,
                                          QStringLiteral("源文件读取中断，中转未完成")));
                return;
            }
            if (!guard->append(result.value)) {
                return; // 下游已中止（取消 / 目标侧失败）
            }
            pullRelayChunk(op, src, guard, offset + got, total);
        });
}

void FileOperations::failTransferItem(const TransferOpPtr &op, const QString &src,
                                      const StorageError &error)
{
    if (op->finished) {
        return;
    }
    // 用户取消不算失败项
    if (op->cancel->load()) {
        return;
    }
    ++op->done;
    op->failures.append(
        QStringLiteral("%1：%2").arg(StoragePath::fileName(src), error.userMessage()));
    MH_WARN(Storage,
            QStringLiteral("移动/复制失败：%1 → %2，原因：%3")
                .arg(src, op->targetDir, error.message()));
}

void FileOperations::finishTransfer(const TransferOpPtr &op)
{
    if (op->finished) {
        return;
    }
    op->finished = true;
    m_transferring = false;
    m_transferOp.reset();

    for (const auto &move : op->moves) {
        // 同源移动：记录跟着走；跨源暂不改写（目标连接源不同，需迁移记录，见 TODO §3.2）
        if (op->sourceConnectionId == op->targetConnectionId) {
            ProgressRepository::instance().renamePath(op->sourceConnectionId, move.first,
                                                      move.second);
            FavoriteRepository::instance().renamePath(op->sourceConnectionId, move.first,
                                                      move.second);
        }
        DirectoryCache::instance().invalidate(op->sourceConnectionId,
                                              StoragePath::parent(move.first));
    }
    if (!op->createdPaths.isEmpty()) {
        DirectoryCache::instance().invalidate(op->targetConnectionId, op->targetDir);
    }

    end();

    if (!op->createdPaths.isEmpty()) {
        QStringList movedSources;
        movedSources.reserve(op->moves.size());
        for (const auto &move : op->moves) {
            movedSources.append(move.first);
        }
        emit transferred(op->sourceConnectionId, movedSources, op->targetConnectionId,
                         op->targetDir, op->createdPaths, op->copy);
    }
    if (!op->failures.isEmpty()) {
        emit failed(op->copy ? QStringLiteral("复制失败") : QStringLiteral("移动失败"),
                    op->failures.join(QLatin1Char('\n')));
    }
    emit transferFinished();
}

void FileOperations::begin()
{
    const bool wasIdle = (m_active == 0);
    ++m_active;
    if (wasIdle) {
        emit busyChanged();
    }
}

void FileOperations::end()
{
    if (m_active > 0) {
        --m_active;
    }
    if (m_active == 0) {
        emit busyChanged();
    }
}

void FileOperations::runWithRetry(std::function<void(std::function<void(StorageError)>)> op,
                                  std::function<void(StorageError)> done, int attempt)
{
    op([this, op, done, attempt](StorageError error) {
        if (error.isNull()) {
            done(error);
            return;
        }
        if (error.isTransient() && attempt < kMaxRetries) {
            const int delay = kRetryDelaysMs[attempt];
            MH_WARN(
                Storage,
                QStringLiteral("文件操作瞬时失败，%1ms 后重试（第 %2 次）：%3")
                    .arg(QString::number(delay), QString::number(attempt + 1), error.message()));
            QTimer::singleShot(
                delay, this, [this, op, done, attempt]() { runWithRetry(op, done, attempt + 1); });
            return;
        }
        done(error);
    });
}

} // namespace myhub
