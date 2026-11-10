#include "LocalAdapter.h"
#include "StoragePath.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QPointer>
#include <QThreadPool>
#include <QtConcurrent/QtConcurrentRun>

namespace myhub {

LocalAdapter::LocalAdapter(QString rootPath, QObject *parent)
    : StorageAdapter(parent)
    , m_rootPath(std::move(rootPath))
{
    // 去掉尾部分隔符，便于拼接
    while (m_rootPath.size() > 1
           && (m_rootPath.endsWith(QLatin1Char('/')) || m_rootPath.endsWith(QLatin1Char('\\')))) {
        m_rootPath.chop(1);
    }
}

QString LocalAdapter::realPath(const QString &virtualPath) const
{
    const QString norm = StoragePath::normalize(virtualPath);
    if (StoragePath::isRoot(norm))
        return m_rootPath;
    return m_rootPath + norm; // norm 以 '/' 开头
}

// 在线程池执行阻塞 IO，完成后把结果投递回调用线程
template <typename R, typename Work, typename Cb>
static void runAsync(QObject *ctx, Work work, Cb cb)
{
    QPointer<QObject> guard(ctx);
    (void)QtConcurrent::run([work = std::move(work), cb = std::move(cb), guard]() mutable {
        R result = work();
        if (!guard)
            return; // 适配器已销毁（如连接源被删除），丢弃回调
        QMetaObject::invokeMethod(
            guard, [cb = std::move(cb), result = std::move(result)]() mutable { cb(result); },
            Qt::QueuedConnection);
    });
}

void LocalAdapter::list(const QString &dir, ListCallback cb)
{
    if (!cb)
        return;
    const QString root = m_rootPath;
    const QString vdir = StoragePath::normalize(dir);
    const QString real = realPath(vdir);

    runAsync<ListResult>(
        this,
        [real, vdir]() -> ListResult {
            QDir d(real);
            if (!d.exists()) {
                return ListResult::failure(StorageError(
                    StorageError::NotFound, QStringLiteral("directory not found: %1").arg(real)));
            }

            FileEntryList entries;
            const QFileInfoList infos = d.entryInfoList(
                QDir::Files | QDir::Dirs | QDir::NoDotAndDotDot | QDir::Hidden, QDir::NoSort);
            entries.reserve(infos.size());

            for (const QFileInfo &fi : infos) {
                // .trash 为回收站实现细节，不呈现给用户
                if (fi.fileName() == QLatin1String(".trash"))
                    continue;
                FileEntry e;
                e.name = fi.fileName();
                e.path = StoragePath::join(vdir, fi.fileName());
                e.isDir = fi.isDir();
                e.size = fi.isDir() ? 0 : fi.size();
                e.modTime = fi.lastModified();
                e.ext = fi.isDir() ? QString() : fi.suffix().toLower();
                entries.append(e);
            }
            return ListResult::success(entries);
        },
        std::move(cb));
}

void LocalAdapter::stat(const QString &path, StatCallback cb)
{
    if (!cb)
        return;
    const QString vpath = StoragePath::normalize(path);
    const QString real = realPath(vpath);

    runAsync<StatResult>(
        this,
        [real, vpath]() -> StatResult {
            QFileInfo fi(real);
            if (!fi.exists()) {
                return StatResult::failure(StorageError(StorageError::NotFound,
                                                        QStringLiteral("not found: %1").arg(real)));
            }
            FileEntry e;
            e.name = fi.fileName();
            e.path = vpath;
            e.isDir = fi.isDir();
            e.size = fi.isDir() ? 0 : fi.size();
            e.modTime = fi.lastModified();
            e.ext = fi.isDir() ? QString() : fi.suffix().toLower();
            return StatResult::success(e);
        },
        std::move(cb));
}

void LocalAdapter::readRange(const QString &path, std::optional<qint64> start,
                             std::optional<qint64> end, DataCallback cb)
{
    if (!cb)
        return;
    const QString real = realPath(path);

    runAsync<DataResult>(
        this,
        [real, start, end]() -> DataResult {
            QFile f(real);
            if (!f.open(QIODevice::ReadOnly)) {
                return DataResult::failure(StorageError(
                    StorageError::NotFound, QStringLiteral("cannot open: %1").arg(real)));
            }
            if (start.has_value() && !f.seek(*start)) {
                return DataResult::failure(
                    StorageError(StorageError::Underlying, QStringLiteral("seek failed")));
            }
            qint64 length = -1;
            if (end.has_value())
                length = *end - start.value_or(0) + 1;

            const QByteArray data = (length > 0) ? f.read(length) : f.readAll();
            return DataResult::success(data);
        },
        std::move(cb));
}

void LocalAdapter::testConnection(ErrorCallback cb)
{
    if (!cb)
        return;
    const QString root = m_rootPath;

    runAsync<StorageError>(
        this,
        [root]() -> StorageError {
            QFileInfo fi(root);
            if (root.isEmpty())
                return StorageError(StorageError::InvalidConfig, QStringLiteral("empty root path"));
            if (!fi.exists())
                return StorageError(StorageError::NotFound,
                                    QStringLiteral("路径不存在：%1").arg(root));
            if (!fi.isDir())
                return StorageError(StorageError::InvalidConfig,
                                    QStringLiteral("不是目录：%1").arg(root));
            if (!fi.isReadable())
                return StorageError(StorageError::AuthenticationFailed,
                                    QStringLiteral("无读取权限：%1").arg(root));
            return StorageError();
        },
        std::move(cb));
}

void LocalAdapter::writeFile(const QString &path, const QByteArray &data, ErrorCallback cb)
{
    if (!cb)
        return;
    const QString real = realPath(path);

    runAsync<StorageError>(
        this,
        [real, data]() -> StorageError {
            QDir().mkpath(QFileInfo(real).absolutePath());
            QFile f(real);
            if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
                return StorageError(StorageError::Underlying,
                                    QStringLiteral("cannot write: %1").arg(real));
            }
            if (f.write(data) != data.size())
                return StorageError(StorageError::Underlying, QStringLiteral("short write"));
            return StorageError();
        },
        std::move(cb));
}

void LocalAdapter::uploadFile(const QString &path, const QString &localPath,
                              UploadProgress progress, CancelProbe isCancelled, ErrorCallback cb)
{
    if (!cb)
        return;
    const QString real = realPath(path);

    runAsync<StorageError>(
        this,
        [real, localPath, progress, isCancelled]() -> StorageError {
            QFile in(localPath);
            if (!in.open(QIODevice::ReadOnly)) {
                return StorageError(StorageError::Underlying,
                                    QStringLiteral("cannot read local file: %1").arg(localPath));
            }
            QDir().mkpath(QFileInfo(real).absolutePath());
            QFile out(real);
            if (!out.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
                return StorageError(StorageError::Underlying,
                                    QStringLiteral("cannot write: %1").arg(real));
            }
            // 1 MB 一块：进度粒度足够细，同时避免大文件整块读入内存
            constexpr qint64 kChunk = 1LL * 1024 * 1024;
            qint64 sent = 0;
            while (!in.atEnd()) {
                if (isCancelled && isCancelled())
                    return StorageError(StorageError::Cancelled, QStringLiteral("已取消"));
                const QByteArray chunk = in.read(kChunk);
                if (chunk.isEmpty()) {
                    if (in.error() != QFileDevice::NoError)
                        return StorageError(StorageError::Underlying,
                                            QStringLiteral("read failed: %1").arg(localPath));
                    break;
                }
                if (out.write(chunk) != chunk.size())
                    return StorageError(StorageError::Underlying, QStringLiteral("short write"));
                sent += chunk.size();
                if (progress)
                    progress(sent);
            }
            if (!out.flush())
                return StorageError(StorageError::Underlying, QStringLiteral("flush failed"));
            return StorageError();
        },
        std::move(cb));
}

void LocalAdapter::writeFrom(const QString &path, QIODevice *source, qint64 totalBytes,
                             UploadProgress progress, CancelProbe isCancelled, ErrorCallback cb)
{
    if (!cb)
        return;
    if (!source || totalBytes < 0) {
        cb(StorageError(StorageError::InvalidPath, QStringLiteral("中转数据源不可用")));
        return;
    }
    const QString real = realPath(path);

    runAsync<StorageError>(
        this,
        [real, source, totalBytes, progress, isCancelled]() -> StorageError {
            QDir().mkpath(QFileInfo(real).absolutePath());
            QFile out(real);
            if (!out.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
                return StorageError(StorageError::Underlying,
                                    QStringLiteral("cannot write: %1").arg(real));
            }
            QByteArray buf(qsizetype(256) * 1024, Qt::Uninitialized);
            qint64 written = 0;
            while (written < totalBytes) {
                if (isCancelled && isCancelled()) {
                    return StorageError(StorageError::Cancelled, QStringLiteral("已取消"));
                }
                const qint64 want = qMin<qint64>(buf.size(), totalBytes - written);
                const qint64 got = source->read(buf.data(), want);
                if (got < 0) {
                    return StorageError(StorageError::Underlying,
                                        QStringLiteral("中转中断：%1").arg(real));
                }
                if (got == 0) {
                    break; // 源提前结束：下面按「长度不符」报错，不静默成功
                }
                if (out.write(buf.constData(), got) != got) {
                    return StorageError(StorageError::Underlying,
                                        QStringLiteral("写入失败：%1").arg(real));
                }
                written += got;
                if (progress) {
                    progress(written);
                }
            }
            if (!out.flush()) {
                return StorageError(StorageError::Underlying,
                                    QStringLiteral("写入未落盘：%1").arg(real));
            }
            if (written != totalBytes) {
                return StorageError(
                    StorageError::Underlying,
                    QStringLiteral("中转未完成：已写入 %1 / %2 字节").arg(written).arg(totalBytes));
            }
            return StorageError();
        },
        std::move(cb));
}

void LocalAdapter::makeDirectory(const QString &path, ErrorCallback cb)
{
    if (!cb)
        return;
    const QString real = realPath(path);

    runAsync<StorageError>(
        this,
        [real]() -> StorageError {
            if (QDir().mkpath(real))
                return StorageError();
            return StorageError(StorageError::Underlying,
                                QStringLiteral("mkdir failed: %1").arg(real));
        },
        std::move(cb));
}

void LocalAdapter::remove(const QString &path, ErrorCallback cb)
{
    if (!cb)
        return;
    const QString real = realPath(path);

    runAsync<StorageError>(
        this,
        [real]() -> StorageError {
            QFileInfo fi(real);
            if (!fi.exists())
                return StorageError(StorageError::NotFound, QStringLiteral("not found"));
            const bool ok = fi.isDir() ? QDir(real).removeRecursively() : QFile::remove(real);
            if (!ok)
                return StorageError(
                    StorageError::Underlying,
                    QStringLiteral("删除失败，文件可能被占用：%1").arg(fi.fileName()));
            return StorageError();
        },
        std::move(cb));
}

void LocalAdapter::move(const QString &src, const QString &dst, ErrorCallback cb)
{
    if (!cb)
        return;
    const QString rs = realPath(src);
    const QString rd = realPath(dst);

    runAsync<StorageError>(
        this,
        [rs, rd]() -> StorageError {
            QDir().mkpath(QFileInfo(rd).absolutePath());
            if (QFile::rename(rs, rd))
                return StorageError();
            return StorageError(StorageError::Underlying,
                                QStringLiteral("移动失败：%1").arg(QFileInfo(rs).fileName()));
        },
        std::move(cb));
}

void LocalAdapter::copy(const QString &src, const QString &dst, ErrorCallback cb)
{
    if (!cb)
        return;
    const QString rs = realPath(src);
    const QString rd = realPath(dst);

    runAsync<StorageError>(
        this,
        [rs, rd]() -> StorageError {
            QDir().mkpath(QFileInfo(rd).absolutePath());
            if (QFile::copy(rs, rd))
                return StorageError();
            return StorageError(StorageError::Underlying,
                                QStringLiteral("复制失败：%1").arg(QFileInfo(rs).fileName()));
        },
        std::move(cb));
}

} // namespace myhub
