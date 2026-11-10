#pragma once

#include "StorageAdapter.h"

namespace myhub {

/**
 * 本地磁盘适配器（PC-101）。
 *
 * 虚拟路径 → 真实路径：rootPath + 虚拟路径。
 * 目录列举等阻塞 IO 放到线程池，回调投递回调用线程（GUI 线程零阻塞）。
 */
class LocalAdapter : public StorageAdapter
{
    Q_OBJECT
public:
    explicit LocalAdapter(QString rootPath, QObject *parent = nullptr);

    QString typeName() const override { return QStringLiteral("local"); }

    void list(const QString &dir, ListCallback cb) override;
    void stat(const QString &path, StatCallback cb) override;
    void readRange(const QString &path, std::optional<qint64> start, std::optional<qint64> end,
                   DataCallback cb) override;
    void testConnection(ErrorCallback cb) override;

    void writeFile(const QString &path, const QByteArray &data, ErrorCallback cb) override;
    void uploadFile(const QString &path, const QString &localPath, UploadProgress progress,
                    CancelProbe isCancelled, ErrorCallback cb) override;
    void writeFrom(const QString &path, QIODevice *source, qint64 totalBytes,
                   UploadProgress progress, CancelProbe isCancelled, ErrorCallback cb) override;
    void makeDirectory(const QString &path, ErrorCallback cb) override;
    void remove(const QString &path, ErrorCallback cb) override;
    void move(const QString &src, const QString &dst, ErrorCallback cb) override;
    void copy(const QString &src, const QString &dst, ErrorCallback cb) override;

    /// 虚拟路径 → 真实本地路径
    QString realPath(const QString &virtualPath) const;

private:
    QString m_rootPath;
};

} // namespace myhub
