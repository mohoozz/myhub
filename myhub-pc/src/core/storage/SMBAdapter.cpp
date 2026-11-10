// Windows 头文件顺序纪律（见 third_party/README.md §4.1）：
// libsmb2.h 会 include <ws2tcpip.h>，必须先引入 winsock2.h，
// 否则 windows.h 带入旧版 winsock.h，导致 getsockopt 重载冲突与 IPPROTO_IPV6 未定义。
#ifdef Q_OS_WIN
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#endif

// O_RDONLY / SEEK_SET：libsmb2 的 open/lseek 沿用 POSIX 常量
#include <fcntl.h>
#include <cstdio>

#include "SMBAdapter.h"
#include "StoragePath.h"
#include "../utils/AppLogger.h"

// smb2.h 必须先于 libsmb2.h：前者定义 SMB2_GUID_SIZE 等协议常量
#include <smb2/smb2.h>
#include <smb2/libsmb2.h>

#include <QDateTime>
#include <QPointer>
#include <QtConcurrent/QtConcurrentRun>

namespace myhub {

namespace {

/// RAII 包装 smb2_context，保证异常/提前返回时也能释放
class SmbSession
{
public:
    explicit SmbSession(const SMBConfig &cfg)
    {
        m_ctx = smb2_init_context();
        if (!m_ctx) {
            m_error =
                StorageError(StorageError::Underlying, QStringLiteral("无法初始化 SMB 上下文"));
            return;
        }

        smb2_set_security_mode(m_ctx, SMB2_NEGOTIATE_SIGNING_ENABLED);

        if (cfg.guest) {
            smb2_set_user(m_ctx, "guest");
            smb2_set_password(m_ctx, "");
        } else {
            if (!cfg.username.isEmpty())
                smb2_set_user(m_ctx, cfg.username.toUtf8().constData());
            if (!cfg.password.isEmpty())
                smb2_set_password(m_ctx, cfg.password.toUtf8().constData());
        }
        if (!cfg.domain.isEmpty())
            smb2_set_domain(m_ctx, cfg.domain.toUtf8().constData());

        const QByteArray host = cfg.host.toUtf8();
        const QByteArray share = cfg.share.toUtf8();
        const QByteArray user = cfg.guest ? QByteArrayLiteral("guest") : cfg.username.toUtf8();

        if (smb2_connect_share(m_ctx, host.constData(), share.constData(),
                               user.isEmpty() ? nullptr : user.constData())
            != 0) {
            m_error = StorageError(
                StorageError::Offline,
                QStringLiteral("连接共享失败：%1").arg(QString::fromUtf8(smb2_get_error(m_ctx))));
            smb2_destroy_context(m_ctx);
            m_ctx = nullptr;
        }
    }

    ~SmbSession()
    {
        if (m_ctx) {
            smb2_disconnect_share(m_ctx);
            smb2_destroy_context(m_ctx);
        }
    }

    Q_DISABLE_COPY_MOVE(SmbSession)

    bool isValid() const { return m_ctx != nullptr; }
    smb2_context *ctx() const { return m_ctx; }
    StorageError error() const { return m_error; }

private:
    smb2_context *m_ctx = nullptr;
    StorageError m_error;
};

/// 虚拟路径 → SMB 相对路径（去掉前导 '/'，libsmb2 要求相对共享根）
QByteArray smbPath(const QString &virtualPath)
{
    QString p = StoragePath::normalize(virtualPath);
    if (p.startsWith(QLatin1Char('/')))
        p.remove(0, 1);
    return p.toUtf8();
}

template <typename R, typename Work, typename Cb>
void runAsync(QObject *ctx, Work work, Cb cb)
{
    QPointer<QObject> guard(ctx);
    (void)QtConcurrent::run([work = std::move(work), cb = std::move(cb), guard]() mutable {
        R result = work();
        if (!guard)
            return;
        QMetaObject::invokeMethod(
            guard, [cb = std::move(cb), result = std::move(result)]() mutable { cb(result); },
            Qt::QueuedConnection);
    });
}

} // namespace

SMBAdapter::SMBAdapter(SMBConfig config, QObject *parent)
    : StorageAdapter(parent)
    , m_config(std::move(config))
{}

SMBAdapter::~SMBAdapter() = default;

void SMBAdapter::list(const QString &dir, ListCallback cb)
{
    if (!cb)
        return;
    const SMBConfig cfg = m_config;
    const QString vdir = StoragePath::normalize(dir);

    runAsync<ListResult>(
        this,
        [cfg, vdir]() -> ListResult {
            SmbSession session(cfg);
            if (!session.isValid())
                return ListResult::failure(session.error());

            smb2dir *handle = smb2_opendir(session.ctx(), smbPath(vdir).constData());
            if (!handle) {
                return ListResult::failure(
                    StorageError(StorageError::NotFound,
                                 QStringLiteral("无法打开目录：%1")
                                     .arg(QString::fromUtf8(smb2_get_error(session.ctx())))));
            }

            FileEntryList entries;
            while (smb2dirent *ent = smb2_readdir(session.ctx(), handle)) {
                const QString name = QString::fromUtf8(ent->name);
                if (name == QLatin1String(".") || name == QLatin1String("..")
                    || name == QLatin1String(".trash")) {
                    continue;
                }

                FileEntry e;
                e.name = name;
                e.path = StoragePath::join(vdir, name);
                e.isDir = (ent->st.smb2_type == SMB2_TYPE_DIRECTORY);
                e.size = e.isDir ? 0 : static_cast<qint64>(ent->st.smb2_size);
                if (ent->st.smb2_mtime > 0)
                    e.modTime =
                        QDateTime::fromSecsSinceEpoch(static_cast<qint64>(ent->st.smb2_mtime));
                e.ext = e.isDir ? QString() : StoragePath::extension(name);
                entries.append(e);
            }
            smb2_closedir(session.ctx(), handle);
            return ListResult::success(entries);
        },
        std::move(cb));
}

void SMBAdapter::stat(const QString &path, StatCallback cb)
{
    if (!cb)
        return;
    const SMBConfig cfg = m_config;
    const QString vpath = StoragePath::normalize(path);

    runAsync<StatResult>(
        this,
        [cfg, vpath]() -> StatResult {
            SmbSession session(cfg);
            if (!session.isValid())
                return StatResult::failure(session.error());

            struct smb2_stat_64 st = {};
            if (smb2_stat(session.ctx(), smbPath(vpath).constData(), &st) != 0) {
                return StatResult::failure(
                    StorageError(StorageError::NotFound,
                                 QStringLiteral("stat 失败：%1")
                                     .arg(QString::fromUtf8(smb2_get_error(session.ctx())))));
            }

            FileEntry e;
            e.name = StoragePath::fileName(vpath);
            e.path = vpath;
            e.isDir = (st.smb2_type == SMB2_TYPE_DIRECTORY);
            e.size = e.isDir ? 0 : static_cast<qint64>(st.smb2_size);
            if (st.smb2_mtime > 0)
                e.modTime = QDateTime::fromSecsSinceEpoch(static_cast<qint64>(st.smb2_mtime));
            e.ext = e.isDir ? QString() : StoragePath::extension(vpath);
            return StatResult::success(e);
        },
        std::move(cb));
}

void SMBAdapter::readRange(const QString &path, std::optional<qint64> start,
                           std::optional<qint64> end, DataCallback cb)
{
    if (!cb)
        return;
    const SMBConfig cfg = m_config;
    const QString vpath = StoragePath::normalize(path);

    runAsync<DataResult>(
        this,
        [cfg, vpath, start, end]() -> DataResult {
            SmbSession session(cfg);
            if (!session.isValid())
                return DataResult::failure(session.error());

            smb2fh *fh = smb2_open(session.ctx(), smbPath(vpath).constData(), O_RDONLY);
            if (!fh) {
                return DataResult::failure(
                    StorageError(StorageError::NotFound,
                                 QStringLiteral("无法打开文件：%1")
                                     .arg(QString::fromUtf8(smb2_get_error(session.ctx())))));
            }

            if (start.has_value()) {
                if (smb2_lseek(session.ctx(), fh, static_cast<int64_t>(*start), SEEK_SET, nullptr)
                    < 0) {
                    smb2_close(session.ctx(), fh);
                    return DataResult::failure(
                        StorageError(StorageError::Underlying, QStringLiteral("seek 失败")));
                }
            }

            qint64 remaining = -1;
            if (end.has_value())
                remaining = *end - start.value_or(0) + 1;

            // 原生分块读取：按 libsmb2 协商的最大读长度循环
            QByteArray out;
            const int chunkSize = 1 << 16; // 64KB
            QByteArray buf(chunkSize, Qt::Uninitialized);

            while (remaining != 0) {
                const int want = (remaining < 0)
                    ? chunkSize
                    : static_cast<int>(qMin<qint64>(remaining, chunkSize));
                const int got =
                    smb2_read(session.ctx(), fh, reinterpret_cast<uint8_t *>(buf.data()),
                              static_cast<uint32_t>(want));
                if (got < 0) {
                    smb2_close(session.ctx(), fh);
                    return DataResult::failure(
                        StorageError(StorageError::Underlying,
                                     QStringLiteral("读取失败：%1")
                                         .arg(QString::fromUtf8(smb2_get_error(session.ctx())))));
                }
                if (got == 0)
                    break; // EOF
                out.append(buf.constData(), got);
                if (remaining > 0)
                    remaining -= got;
            }

            smb2_close(session.ctx(), fh);
            return DataResult::success(out);
        },
        std::move(cb));
}

void SMBAdapter::testConnection(ErrorCallback cb)
{
    if (!cb)
        return;
    const SMBConfig cfg = m_config;

    runAsync<StorageError>(
        this,
        [cfg]() -> StorageError {
            if (cfg.host.isEmpty())
                return StorageError(StorageError::InvalidConfig, QStringLiteral("服务器地址为空"));
            if (cfg.share.isEmpty())
                return StorageError(StorageError::InvalidConfig, QStringLiteral("共享名为空"));

            SmbSession session(cfg);
            if (!session.isValid())
                return session.error();

            // 能连上还要能列根目录才算真正可用
            smb2dir *handle = smb2_opendir(session.ctx(), "");
            if (!handle) {
                return StorageError(StorageError::AuthenticationFailed,
                                    QStringLiteral("无法访问共享根目录：%1")
                                        .arg(QString::fromUtf8(smb2_get_error(session.ctx()))));
            }
            smb2_closedir(session.ctx(), handle);
            return StorageError();
        },
        std::move(cb));
}

void SMBAdapter::makeDirectory(const QString &path, ErrorCallback cb)
{
    if (!cb)
        return;
    const SMBConfig cfg = m_config;
    const QString vpath = StoragePath::normalize(path);

    runAsync<StorageError>(
        this,
        [cfg, vpath]() -> StorageError {
            SmbSession session(cfg);
            if (!session.isValid())
                return session.error();
            if (smb2_mkdir(session.ctx(), smbPath(vpath).constData()) != 0) {
                return StorageError(StorageError::Underlying,
                                    QStringLiteral("新建文件夹失败：%1")
                                        .arg(QString::fromUtf8(smb2_get_error(session.ctx()))));
            }
            return StorageError();
        },
        std::move(cb));
}

void SMBAdapter::remove(const QString &path, ErrorCallback cb)
{
    if (!cb)
        return;
    const SMBConfig cfg = m_config;
    const QString vpath = StoragePath::normalize(path);

    runAsync<StorageError>(
        this,
        [cfg, vpath]() -> StorageError {
            SmbSession session(cfg);
            if (!session.isValid())
                return session.error();

            struct smb2_stat_64 st = {};
            if (smb2_stat(session.ctx(), smbPath(vpath).constData(), &st) != 0)
                return StorageError(StorageError::NotFound, QStringLiteral("文件不存在"));

            const int rc = (st.smb2_type == SMB2_TYPE_DIRECTORY)
                ? smb2_rmdir(session.ctx(), smbPath(vpath).constData())
                : smb2_unlink(session.ctx(), smbPath(vpath).constData());
            if (rc != 0) {
                return StorageError(StorageError::Underlying,
                                    QStringLiteral("删除失败：%1")
                                        .arg(QString::fromUtf8(smb2_get_error(session.ctx()))));
            }
            return StorageError();
        },
        std::move(cb));
}

} // namespace myhub
