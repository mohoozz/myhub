#pragma once

#include "StorageAdapter.h"

#include <QJsonObject>
#include <QString>

namespace myhub {

/// 连接源类型（§5.3 connection.type）
enum class ConnectionType
{
    Local,
    WebDAV,
    SMB,
    // 预留：枚举保留，工厂抛「暂不支持」（§2.4 PC-101）
    FTP,
    SFTP,
    NFS,
    Unknown,
};

/// 连接源记录
struct ConnectionRecord
{
    QString id;
    QString name;
    ConnectionType type = ConnectionType::Unknown;
    QJsonObject config; ///< configJSON，密码不入库
    QString mountPoint;
    bool enabled = true;
    QDateTime createdAt;

    bool isValid() const { return !id.isEmpty() && type != ConnectionType::Unknown; }
};

/**
 * 适配器工厂（§2.4 PC-101）。
 *
 * 按 Connection.type 实例化并自动从系统凭据库取凭据；
 * 表单未保存时支持 passwordOverride 以便「测试连接」。
 */
class StorageAdapterFactory
{
public:
    /**
     * 创建适配器。
     * @param passwordOverride 非空时覆盖凭据库中的密码（用于未保存表单的连接测试）
     * @param error 创建失败原因
     * @return 调用方负责销毁；失败返回 nullptr
     */
    static StorageAdapter *create(const ConnectionRecord &record,
                                  const QString &passwordOverride = QString(),
                                  StorageError *error = nullptr, QObject *parent = nullptr);

    static ConnectionType typeFromString(const QString &s);
    static QString typeToString(ConnectionType t);

    /// 类型是否已实现（FTP/SFTP/NFS 为预留）
    static bool isSupported(ConnectionType t);

    /// 类型的中文显示名
    static QString typeDisplayName(ConnectionType t);
};

} // namespace myhub
