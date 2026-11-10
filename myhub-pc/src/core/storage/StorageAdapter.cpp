#include "StorageAdapter.h"

namespace myhub {

StorageAdapter::StorageAdapter(QObject *parent)
    : QObject(parent)
{}

StorageAdapter::~StorageAdapter() = default;

// 默认实现：未覆写者一律返回「暂不支持」，避免静默成功造成数据误判
static StorageError unsupported(const QString &op)
{
    return StorageError(StorageError::UnsupportedProtocol,
                        QStringLiteral("%1 not supported by this adapter").arg(op));
}

void StorageAdapter::writeFile(const QString &, const QByteArray &, ErrorCallback cb)
{
    if (cb)
        cb(unsupported(QStringLiteral("writeFile")));
}

void StorageAdapter::uploadFile(const QString &, const QString &, UploadProgress, CancelProbe,
                                ErrorCallback cb)
{
    if (cb)
        cb(unsupported(QStringLiteral("uploadFile")));
}

void StorageAdapter::writeFrom(const QString &, QIODevice *, qint64, UploadProgress, CancelProbe,
                               ErrorCallback cb)
{
    if (cb)
        cb(unsupported(QStringLiteral("writeFrom")));
}

void StorageAdapter::makeDirectory(const QString &, ErrorCallback cb)
{
    if (cb)
        cb(unsupported(QStringLiteral("makeDirectory")));
}

void StorageAdapter::remove(const QString &, ErrorCallback cb)
{
    if (cb)
        cb(unsupported(QStringLiteral("remove")));
}

void StorageAdapter::move(const QString &, const QString &, ErrorCallback cb)
{
    if (cb)
        cb(unsupported(QStringLiteral("move")));
}

void StorageAdapter::copy(const QString &, const QString &, ErrorCallback cb)
{
    if (cb)
        cb(unsupported(QStringLiteral("copy")));
}

} // namespace myhub
