#include "ArchiveFetcher.h"

#include "core/storage/StorageAdapter.h"

#include <QFile>

#include <memory>

namespace myhub {

void ArchiveFetcher::fetch(StorageAdapter *adapter, const QString &remotePath, qint64 size,
                           const QString &targetPath, ProgressCallback onProgress,
                           DoneCallback onDone)
{
    if (adapter == nullptr) {
        onDone(QString(), StorageError(StorageError::InvalidPath, QStringLiteral("连接源不可用")));
        return;
    }
    if (size <= 0) {
        onDone(
            QString(),
            StorageError(StorageError::InvalidPath, QStringLiteral("文件大小未知，无法落地整包")));
        return;
    }

    const QString tempPath = targetPath + QStringLiteral(".part");
    QFile::remove(tempPath);

    auto written = std::make_shared<qint64>(0);
    auto step = std::make_shared<std::function<void()>>();

    auto finish = [tempPath, targetPath, onDone](const StorageError &error) {
        if (!error.isNull()) {
            QFile::remove(tempPath);
            onDone(QString(), error);
            return;
        }
        if (!QFile::rename(tempPath, targetPath)) {
            // Windows 上目标已存在时 rename 会失败：先删再试一次
            QFile::remove(targetPath);
            if (!QFile::rename(tempPath, targetPath)) {
                QFile::remove(tempPath);
                onDone(QString(),
                       StorageError(StorageError::Underlying,
                                    QStringLiteral("整包落地失败：写不进缓存目录")));
                return;
            }
        }
        onDone(targetPath, StorageError());
    };

    *step = [adapter, remotePath, size, tempPath, onProgress, finish, written, step]() {
        const qint64 offset = *written;
        if (offset >= size) {
            finish(StorageError());
            return;
        }
        const qint64 end = qMin(offset + kChunkBytes, size) - 1;

        // 顺序分块：rar 的解压本身就要从头读，边下边解没有意义，先把进度做实
        adapter->readRange(remotePath, offset, end, [=](DataResult result) {
            if (!result.ok()) {
                finish(result.error);
                return;
            }

            QFile pack(tempPath);
            if (!pack.open(QIODevice::WriteOnly | QIODevice::Append)) {
                finish(StorageError(StorageError::Underlying,
                                    QStringLiteral("缓存目录不可写，无法落地整包")));
                return;
            }
            pack.write(result.value);
            pack.close();

            *written = qMin(end + 1, size);
            if (onProgress) {
                onProgress(*written, size);
            }
            (*step)();
        });
    };

    (*step)();
}

} // namespace myhub
