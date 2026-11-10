#pragma once

#include "StorageAdapter.h"

#include <QUrl>

class QNetworkAccessManager;
class QNetworkReply;

namespace myhub {

/// WebDAV 连接配置（§5.3 WebDAVConfig）
struct WebDAVConfig
{
    QString baseURL;
    QString internalBaseURL; ///< 可选内网地址，用于内外网竞速（PC-708）
    QString username;
    QString password; ///< 运行期由 CredentialStore 注入，不入库
    QString rootPath;
    bool allowInsecureTLS = false;
};

/**
 * WebDAV 适配器（PC-101）。
 *
 * 实现 PROPFIND / GET(Range) / PUT / MOVE / COPY / DELETE / MKCOL。
 *
 * 关键纪律（iOS 实战经验）：
 *   - **PROPFIND 严格校验**：解析不到合法 multistatus 即抛 InvalidResponse，
 *     并记录状态码 / Content-Type / 响应体前缀；**严禁把异常响应当空目录**
 *   - 使用独立 Session 提高每主机连接数上限、禁用 HTTP 缓存
 */
class WebDAVAdapter : public StorageAdapter
{
    Q_OBJECT
public:
    explicit WebDAVAdapter(WebDAVConfig config, QObject *parent = nullptr);
    ~WebDAVAdapter() override;

    QString typeName() const override { return QStringLiteral("webdav"); }

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

    const WebDAVConfig &config() const { return m_config; }

    /// 覆盖使用的基地址（供 RoutedWebDAVAdapter 在竞速后锁定地址）
    void setActiveBaseURL(const QString &url);
    QString activeBaseURL() const { return m_activeBaseURL; }

    /// 表单未保存时用于测试的密码覆盖
    void setPasswordOverride(const QString &password) { m_config.password = password; }

    /**
     * 解析 PROPFIND 响应。
     * 公开为静态方法以便单测覆盖（§13 QTest 覆盖纯逻辑层）。
     * @return 解析失败时 ok=false，error 为 InvalidResponse
     */
    static ListResult parsePropfind(const QByteArray &xml, const QString &requestDir,
                                    const QString &rootPrefix);

private:
    QUrl urlFor(const QString &virtualPath) const;
    QNetworkReply *sendRequest(const QByteArray &verb, const QString &virtualPath,
                               const QByteArray &body = {},
                               const QList<QPair<QByteArray, QByteArray>> &headers = {});
    StorageError errorFromReply(QNetworkReply *reply) const;

    WebDAVConfig m_config;
    QString m_activeBaseURL;
    QNetworkAccessManager *m_nam = nullptr;
};

} // namespace myhub
