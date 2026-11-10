#include "StorageAdapterFactory.h"
#include "LocalAdapter.h"
#include "RoutedWebDAVAdapter.h"
#include "SMBAdapter.h"
#include "WebDAVAdapter.h"
#include "../credentials/CredentialStore.h"
#include "../utils/AppLogger.h"

#include <QObject>

namespace myhub {

ConnectionType StorageAdapterFactory::typeFromString(const QString &s)
{
    const QString t = s.toLower();
    if (t == QLatin1String("local"))
        return ConnectionType::Local;
    if (t == QLatin1String("webdav"))
        return ConnectionType::WebDAV;
    if (t == QLatin1String("smb"))
        return ConnectionType::SMB;
    if (t == QLatin1String("ftp"))
        return ConnectionType::FTP;
    if (t == QLatin1String("sftp"))
        return ConnectionType::SFTP;
    if (t == QLatin1String("nfs"))
        return ConnectionType::NFS;
    return ConnectionType::Unknown;
}

QString StorageAdapterFactory::typeToString(ConnectionType t)
{
    switch (t) {
    case ConnectionType::Local:
        return QStringLiteral("local");
    case ConnectionType::WebDAV:
        return QStringLiteral("webdav");
    case ConnectionType::SMB:
        return QStringLiteral("smb");
    case ConnectionType::FTP:
        return QStringLiteral("ftp");
    case ConnectionType::SFTP:
        return QStringLiteral("sftp");
    case ConnectionType::NFS:
        return QStringLiteral("nfs");
    case ConnectionType::Unknown:
        break;
    }
    return QStringLiteral("unknown");
}

bool StorageAdapterFactory::isSupported(ConnectionType t)
{
    switch (t) {
    case ConnectionType::Local:
    case ConnectionType::WebDAV:
    case ConnectionType::SMB:
        return true;
    default:
        return false;
    }
}

QString StorageAdapterFactory::typeDisplayName(ConnectionType t)
{
    switch (t) {
    case ConnectionType::Local:
        return QObject::tr("本地路径");
    case ConnectionType::WebDAV:
        return QStringLiteral("WebDAV");
    case ConnectionType::SMB:
        return QStringLiteral("SMB");
    case ConnectionType::FTP:
        return QStringLiteral("FTP");
    case ConnectionType::SFTP:
        return QStringLiteral("SFTP");
    case ConnectionType::NFS:
        return QStringLiteral("NFS");
    case ConnectionType::Unknown:
        break;
    }
    return QObject::tr("未知");
}

StorageAdapter *StorageAdapterFactory::create(const ConnectionRecord &record,
                                              const QString &passwordOverride, StorageError *error,
                                              QObject *parent)
{
    auto fail = [error](StorageError::Kind kind, const QString &msg) -> StorageAdapter * {
        if (error)
            *error = StorageError(kind, msg);
        return nullptr;
    };

    if (!isSupported(record.type)) {
        return fail(StorageError::UnsupportedProtocol,
                    QObject::tr("暂不支持 %1 协议").arg(typeDisplayName(record.type)));
    }

    // 凭据：优先用显式覆盖（未保存的表单），否则从系统凭据库读取
    const QString password = passwordOverride.isEmpty()
        ? CredentialStore::load(CredentialStore::connectionKey(record.id))
        : passwordOverride;

    switch (record.type) {
    case ConnectionType::Local: {
        const QString path = record.config.value(QStringLiteral("path")).toString();
        if (path.isEmpty())
            return fail(StorageError::InvalidConfig, QObject::tr("本地路径未配置"));
        return new LocalAdapter(path, parent);
    }

    case ConnectionType::WebDAV: {
        WebDAVConfig cfg;
        cfg.baseURL = record.config.value(QStringLiteral("baseURL")).toString();
        cfg.internalBaseURL = record.config.value(QStringLiteral("internalBaseURL")).toString();
        cfg.username = record.config.value(QStringLiteral("username")).toString();
        cfg.rootPath = record.config.value(QStringLiteral("rootPath")).toString();
        cfg.allowInsecureTLS = record.config.value(QStringLiteral("allowInsecureTLS")).toBool();
        cfg.password = password;

        if (cfg.baseURL.isEmpty() && cfg.internalBaseURL.isEmpty())
            return fail(StorageError::InvalidConfig, QObject::tr("WebDAV 地址未配置"));

        // 配置了内网地址 → 启用竞速路由装饰器（PC-708）
        if (!cfg.internalBaseURL.isEmpty())
            return new RoutedWebDAVAdapter(cfg, parent);
        return new WebDAVAdapter(cfg, parent);
    }

    case ConnectionType::SMB: {
        SMBConfig cfg;
        cfg.host = record.config.value(QStringLiteral("host")).toString();
        cfg.share = record.config.value(QStringLiteral("share")).toString();
        cfg.username = record.config.value(QStringLiteral("username")).toString();
        cfg.domain = record.config.value(QStringLiteral("domain")).toString();
        cfg.guest = record.config.value(QStringLiteral("guest")).toBool();
        cfg.password = password;

        if (cfg.host.isEmpty() || cfg.share.isEmpty())
            return fail(StorageError::InvalidConfig, QObject::tr("SMB 服务器或共享名未配置"));
        return new SMBAdapter(cfg, parent);
    }

    default:
        break;
    }

    return fail(StorageError::UnsupportedProtocol, QObject::tr("未知的连接类型"));
}

} // namespace myhub
