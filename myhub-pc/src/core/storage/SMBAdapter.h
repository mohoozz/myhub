#pragma once

#include "StorageAdapter.h"

namespace myhub {

/// SMB 连接配置（§5.3 SMBConfig）
struct SMBConfig
{
    QString host;
    QString share;
    QString username;
    QString password; ///< 运行期注入，不入库
    QString domain;
    bool guest = false;
};

/**
 * SMB2/3 适配器（PC-101），基于 libsmb2。
 *
 * libsmb2 为同步阻塞 API，因此所有操作放到线程池执行，
 * 回调投递回调用线程，保证 GUI 线程零阻塞。
 *
 * 注意（Windows 集成）：libsmb2.h 依赖 ws2tcpip.h，必须先引入 winsock2.h；
 * 且 smb2.h 须先于 libsmb2.h。顺序已在 .cpp 中处理。
 */
class SMBAdapter : public StorageAdapter
{
    Q_OBJECT
public:
    explicit SMBAdapter(SMBConfig config, QObject *parent = nullptr);
    ~SMBAdapter() override;

    QString typeName() const override { return QStringLiteral("smb"); }

    void list(const QString &dir, ListCallback cb) override;
    void stat(const QString &path, StatCallback cb) override;
    void readRange(const QString &path, std::optional<qint64> start, std::optional<qint64> end,
                   DataCallback cb) override;
    void testConnection(ErrorCallback cb) override;

    void makeDirectory(const QString &path, ErrorCallback cb) override;
    void remove(const QString &path, ErrorCallback cb) override;

    void setPasswordOverride(const QString &password) { m_config.password = password; }

private:
    SMBConfig m_config;
};

} // namespace myhub
