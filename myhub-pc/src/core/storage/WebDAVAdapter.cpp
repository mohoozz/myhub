#include "WebDAVAdapter.h"
#include "StoragePath.h"
#include "../utils/AppLogger.h"

#include <QBuffer>
#include <QDateTime>
#include <QFile>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QPointer>
#include <QSslConfiguration>
#include <QTimer>
#include <QXmlStreamReader>

namespace myhub {

namespace {

constexpr int kRequestTimeoutMs = 30000;

/// PROPFIND 请求体：只取需要的属性，减少响应体积
const QByteArray kPropfindBody = QByteArrayLiteral("<?xml version=\"1.0\" encoding=\"utf-8\"?>"
                                                   "<D:propfind xmlns:D=\"DAV:\">"
                                                   "<D:prop>"
                                                   "<D:resourcetype/>"
                                                   "<D:getcontentlength/>"
                                                   "<D:getlastmodified/>"
                                                   "<D:displayname/>"
                                                   "</D:prop>"
                                                   "</D:propfind>");

/// 从 href 中提取相对于 rootPrefix 的虚拟路径
QString virtualPathFromHref(const QString &href, const QString &rootPrefix)
{
    QString p = QUrl::fromPercentEncoding(href.toUtf8());

    // href 可能是绝对 URL，也可能是绝对路径
    if (p.startsWith(QLatin1String("http://")) || p.startsWith(QLatin1String("https://"))) {
        const QUrl u(p);
        p = u.path();
    }

    if (!rootPrefix.isEmpty() && rootPrefix != QLatin1String("/")) {
        if (p.startsWith(rootPrefix))
            p = p.mid(rootPrefix.size());
    }
    return StoragePath::normalize(p);
}

} // namespace

WebDAVAdapter::WebDAVAdapter(WebDAVConfig config, QObject *parent)
    : StorageAdapter(parent)
    , m_config(std::move(config))
{
    m_activeBaseURL = m_config.baseURL;

    // 独立 Session：提高每主机连接数上限、禁用 HTTP 缓存（串流与列举互不干扰）
    m_nam = new QNetworkAccessManager(this);
    m_nam->setAutoDeleteReplies(false);
    m_nam->setTransferTimeout(kRequestTimeoutMs);
}

WebDAVAdapter::~WebDAVAdapter() = default;

void WebDAVAdapter::setActiveBaseURL(const QString &url)
{
    if (!url.isEmpty())
        m_activeBaseURL = url;
}

QUrl WebDAVAdapter::urlFor(const QString &virtualPath) const
{
    QString base = m_activeBaseURL;
    while (base.endsWith(QLatin1Char('/')))
        base.chop(1);

    QString root = StoragePath::normalize(m_config.rootPath);
    if (StoragePath::isRoot(root))
        root.clear();

    const QString full = root + StoragePath::percentEncoded(virtualPath);
    QUrl url(base + full);
    return url;
}

QNetworkReply *WebDAVAdapter::sendRequest(const QByteArray &verb, const QString &virtualPath,
                                          const QByteArray &body,
                                          const QList<QPair<QByteArray, QByteArray>> &headers)
{
    QNetworkRequest req(urlFor(virtualPath));
    req.setAttribute(QNetworkRequest::CacheLoadControlAttribute, QNetworkRequest::AlwaysNetwork);
    req.setAttribute(QNetworkRequest::CacheSaveControlAttribute, false);
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                     QNetworkRequest::NoLessSafeRedirectPolicy);
    req.setRawHeader(QByteArrayLiteral("User-Agent"), QByteArrayLiteral("MyHub/1.0"));

    // Basic 认证：预置 Authorization 头，避免多一轮 401 往返
    if (!m_config.username.isEmpty()) {
        const QByteArray token =
            (m_config.username + QLatin1Char(':') + m_config.password).toUtf8().toBase64();
        req.setRawHeader(QByteArrayLiteral("Authorization"), QByteArrayLiteral("Basic ") + token);
    }

    if (m_config.allowInsecureTLS) {
        QSslConfiguration ssl = req.sslConfiguration();
        ssl.setPeerVerifyMode(QSslSocket::VerifyNone);
        req.setSslConfiguration(ssl);
    }

    for (const auto &h : headers)
        req.setRawHeader(h.first, h.second);

    QBuffer *buffer = nullptr;
    if (!body.isEmpty()) {
        req.setHeader(QNetworkRequest::ContentTypeHeader,
                      QStringLiteral("application/xml; charset=utf-8"));
        buffer = new QBuffer;
        buffer->setData(body);
        buffer->open(QIODevice::ReadOnly);
    }

    QNetworkReply *reply = m_nam->sendCustomRequest(req, verb, buffer);
    if (buffer)
        buffer->setParent(reply); // 随 reply 释放
    return reply;
}

StorageError WebDAVAdapter::errorFromReply(QNetworkReply *reply) const
{
    if (!reply)
        return StorageError(StorageError::Underlying, QStringLiteral("null reply"));

    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    const QNetworkReply::NetworkError err = reply->error();

    if (err == QNetworkReply::NoError)
        return StorageError();

    // 连接类错误 → Offline（允许触发路由自愈）
    switch (err) {
    case QNetworkReply::ConnectionRefusedError:
    case QNetworkReply::RemoteHostClosedError:
    case QNetworkReply::HostNotFoundError:
    case QNetworkReply::TimeoutError:
    case QNetworkReply::NetworkSessionFailedError:
    case QNetworkReply::TemporaryNetworkFailureError:
    case QNetworkReply::UnknownNetworkError:
    case QNetworkReply::ProxyConnectionRefusedError:
    case QNetworkReply::ProxyTimeoutError:
        return StorageError(StorageError::Offline, reply->errorString());
    case QNetworkReply::OperationCanceledError:
        return StorageError(StorageError::Cancelled, reply->errorString());
    case QNetworkReply::AuthenticationRequiredError:
        return StorageError(StorageError::AuthenticationFailed, reply->errorString(), status);
    case QNetworkReply::SslHandshakeFailedError:
        return StorageError(StorageError::Offline,
                            QStringLiteral("TLS 握手失败：%1").arg(reply->errorString()));
    default:
        break;
    }

    if (status > 0)
        return StorageError::fromHttpStatus(status, reply->errorString());
    return StorageError(StorageError::Underlying, reply->errorString());
}

ListResult WebDAVAdapter::parsePropfind(const QByteArray &xml, const QString &requestDir,
                                        const QString &rootPrefix)
{
    // 严格校验：必须能解析出 DAV: multistatus 根元素
    QXmlStreamReader reader(xml);
    bool sawMultistatus = false;
    FileEntryList entries;

    const QString normRequestDir = StoragePath::normalize(requestDir);

    while (!reader.atEnd()) {
        reader.readNext();
        if (!reader.isStartElement())
            continue;

        const QStringView name = reader.name();

        if (name == QLatin1String("multistatus")) {
            sawMultistatus = true;
            continue;
        }

        if (name != QLatin1String("response"))
            continue;

        // 解析单个 response
        QString href;
        bool isDir = false;
        qint64 size = 0;
        QDateTime modTime;
        QString displayName;

        int depth = 1;
        while (!reader.atEnd() && depth > 0) {
            reader.readNext();
            if (reader.isEndElement()) {
                if (reader.name() == QLatin1String("response"))
                    --depth;
                continue;
            }
            if (!reader.isStartElement())
                continue;

            const QStringView n = reader.name();
            if (n == QLatin1String("href")) {
                href = reader.readElementText();
            } else if (n == QLatin1String("collection")) {
                isDir = true;
            } else if (n == QLatin1String("getcontentlength")) {
                size = reader.readElementText().toLongLong();
            } else if (n == QLatin1String("getlastmodified")) {
                const QString s = reader.readElementText();
                modTime = QDateTime::fromString(s, Qt::RFC2822Date);
                if (!modTime.isValid())
                    modTime = QDateTime::fromString(s, Qt::ISODate);
            } else if (n == QLatin1String("displayname")) {
                displayName = reader.readElementText();
            }
        }

        if (href.isEmpty())
            continue;

        const QString vpath = virtualPathFromHref(href, rootPrefix);

        // 跳过目录自身条目
        if (vpath == normRequestDir)
            continue;

        FileEntry e;
        e.name = displayName.isEmpty() ? StoragePath::fileName(vpath) : displayName;
        e.path = vpath;
        e.isDir = isDir;
        e.size = isDir ? 0 : size;
        e.modTime = modTime;
        e.ext = isDir ? QString() : StoragePath::extension(vpath);

        if (e.name == QLatin1String(".trash"))
            continue;

        entries.append(e);
    }

    if (reader.hasError() || !sawMultistatus) {
        // 异常响应必须报错，严禁当作空目录（PC-708）
        return ListResult::failure(
            StorageError(StorageError::InvalidResponse,
                         QStringLiteral("PROPFIND 响应无法解析（%1）")
                             .arg(reader.hasError() ? reader.errorString()
                                                    : QStringLiteral("缺少 multistatus 根元素"))));
    }

    return ListResult::success(entries);
}

void WebDAVAdapter::list(const QString &dir, ListCallback cb)
{
    if (!cb)
        return;

    QNetworkReply *reply = sendRequest(QByteArrayLiteral("PROPFIND"), dir, kPropfindBody,
                                       {{QByteArrayLiteral("Depth"), QByteArrayLiteral("1")}});

    const QString rootPrefix = StoragePath::isRoot(StoragePath::normalize(m_config.rootPath))
        ? QString()
        : StoragePath::normalize(m_config.rootPath);
    const QString vdir = StoragePath::normalize(dir);

    QPointer<WebDAVAdapter> self(this);
    connect(reply, &QNetworkReply::finished, this,
            [reply, cb = std::move(cb), rootPrefix, vdir, self]() mutable {
                reply->deleteLater();
                if (!self)
                    return;

                const int status =
                    reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
                const QByteArray body = reply->readAll();
                const StorageError netErr = self->errorFromReply(reply);

                if (!netErr.isNull()) {
                    MH_WARN(Storage,
                            QStringLiteral("PROPFIND %1 failed: status=%2 err=%3")
                                .arg(vdir)
                                .arg(status)
                                .arg(netErr.message()));
                    cb(ListResult::failure(netErr));
                    return;
                }

                // WebDAV 成功应为 207 Multi-Status
                if (status != 207 && status != 200) {
                    const QString ct = reply->header(QNetworkRequest::ContentTypeHeader).toString();
                    MH_WARN(Storage,
                            QStringLiteral("PROPFIND %1 unexpected status=%2 "
                                           "content-type=%3 body-prefix=%4")
                                .arg(vdir)
                                .arg(status)
                                .arg(ct, QString::fromUtf8(body.left(120))));
                    cb(ListResult::failure(StorageError::fromHttpStatus(
                        status, QStringLiteral("PROPFIND 返回异常状态"))));
                    return;
                }

                ListResult result = parsePropfind(body, vdir, rootPrefix);
                if (!result.ok()) {
                    // 记录诊断信息：状态码 / Content-Type / 响应体前缀
                    const QString ct = reply->header(QNetworkRequest::ContentTypeHeader).toString();
                    MH_ERROR(Storage,
                             QStringLiteral("PROPFIND %1 invalid response: status=%2 "
                                            "content-type=%3 body-prefix=%4")
                                 .arg(vdir)
                                 .arg(status)
                                 .arg(ct, QString::fromUtf8(body.left(200))));
                }
                cb(std::move(result));
            });
}

void WebDAVAdapter::stat(const QString &path, StatCallback cb)
{
    if (!cb)
        return;

    QNetworkReply *reply = sendRequest(QByteArrayLiteral("PROPFIND"), path, kPropfindBody,
                                       {{QByteArrayLiteral("Depth"), QByteArrayLiteral("0")}});

    const QString rootPrefix = StoragePath::isRoot(StoragePath::normalize(m_config.rootPath))
        ? QString()
        : StoragePath::normalize(m_config.rootPath);
    const QString vpath = StoragePath::normalize(path);

    QPointer<WebDAVAdapter> self(this);
    connect(reply, &QNetworkReply::finished, this,
            [reply, cb = std::move(cb), rootPrefix, vpath, self]() mutable {
                reply->deleteLater();
                if (!self)
                    return;

                const StorageError netErr = self->errorFromReply(reply);
                if (!netErr.isNull()) {
                    cb(StatResult::failure(netErr));
                    return;
                }

                const QByteArray body = reply->readAll();
                // Depth:0 时目标自身即为唯一 response，故传空 requestDir 以免被过滤
                ListResult listed = parsePropfind(body, QStringLiteral("\x01"), rootPrefix);
                if (!listed.ok()) {
                    cb(StatResult::failure(listed.error));
                    return;
                }
                if (listed.value.isEmpty()) {
                    cb(StatResult::failure(
                        StorageError(StorageError::NotFound, QStringLiteral("stat 未返回条目"))));
                    return;
                }

                FileEntry e = listed.value.first();
                e.path = vpath;
                if (e.name.isEmpty())
                    e.name = StoragePath::fileName(vpath);
                cb(StatResult::success(e));
            });
}

void WebDAVAdapter::readRange(const QString &path, std::optional<qint64> start,
                              std::optional<qint64> end, DataCallback cb)
{
    if (!cb)
        return;

    QList<QPair<QByteArray, QByteArray>> headers;
    if (start.has_value() || end.has_value()) {
        const QString range = QStringLiteral("bytes=%1-%2")
                                  .arg(start.has_value() ? QString::number(*start) : QString())
                                  .arg(end.has_value() ? QString::number(*end) : QString());
        headers.append({QByteArrayLiteral("Range"), range.toUtf8()});
    }

    QNetworkReply *reply = sendRequest(QByteArrayLiteral("GET"), path, {}, headers);

    QPointer<WebDAVAdapter> self(this);
    connect(reply, &QNetworkReply::finished, this, [reply, cb = std::move(cb), self]() mutable {
        reply->deleteLater();
        if (!self)
            return;
        const StorageError err = self->errorFromReply(reply);
        if (!err.isNull()) {
            cb(DataResult::failure(err));
            return;
        }
        cb(DataResult::success(reply->readAll()));
    });
}

void WebDAVAdapter::testConnection(ErrorCallback cb)
{
    if (!cb)
        return;

    if (m_activeBaseURL.isEmpty()) {
        cb(StorageError(StorageError::InvalidConfig, QStringLiteral("服务器地址为空")));
        return;
    }

    // 以根目录 PROPFIND Depth:0 作为探测，比 OPTIONS 更能反映真实可用性
    QNetworkReply *reply =
        sendRequest(QByteArrayLiteral("PROPFIND"), QStringLiteral("/"), kPropfindBody,
                    {{QByteArrayLiteral("Depth"), QByteArrayLiteral("0")}});

    QPointer<WebDAVAdapter> self(this);
    connect(reply, &QNetworkReply::finished, this, [reply, cb = std::move(cb), self]() mutable {
        reply->deleteLater();
        if (!self)
            return;

        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const StorageError err = self->errorFromReply(reply);
        if (!err.isNull()) {
            cb(err);
            return;
        }
        if (status != 207 && status != 200) {
            cb(StorageError::fromHttpStatus(status, QStringLiteral("服务器未返回 WebDAV 响应")));
            return;
        }
        cb(StorageError());
    });
}

// ---- 写操作 ----

void WebDAVAdapter::writeFile(const QString &path, const QByteArray &data, ErrorCallback cb)
{
    if (!cb)
        return;
    QNetworkRequest req(urlFor(path));
    if (!m_config.username.isEmpty()) {
        const QByteArray token =
            (m_config.username + QLatin1Char(':') + m_config.password).toUtf8().toBase64();
        req.setRawHeader(QByteArrayLiteral("Authorization"), QByteArrayLiteral("Basic ") + token);
    }
    if (m_config.allowInsecureTLS) {
        QSslConfiguration ssl = req.sslConfiguration();
        ssl.setPeerVerifyMode(QSslSocket::VerifyNone);
        req.setSslConfiguration(ssl);
    }
    req.setHeader(QNetworkRequest::ContentLengthHeader, data.size());

    QNetworkReply *reply = m_nam->put(req, data);
    QPointer<WebDAVAdapter> self(this);
    connect(reply, &QNetworkReply::finished, this, [reply, cb = std::move(cb), self]() mutable {
        reply->deleteLater();
        if (self)
            cb(self->errorFromReply(reply));
    });
}

void WebDAVAdapter::uploadFile(const QString &path, const QString &localPath,
                               UploadProgress progress, CancelProbe isCancelled, ErrorCallback cb)
{
    if (!cb)
        return;

    auto *file = new QFile(localPath);
    if (!file->open(QIODevice::ReadOnly)) {
        delete file;
        cb(StorageError(StorageError::Underlying,
                        QStringLiteral("无法读取本地文件：%1").arg(localPath)));
        return;
    }

    QNetworkRequest req(urlFor(path));
    if (!m_config.username.isEmpty()) {
        const QByteArray token =
            (m_config.username + QLatin1Char(':') + m_config.password).toUtf8().toBase64();
        req.setRawHeader(QByteArrayLiteral("Authorization"), QByteArrayLiteral("Basic ") + token);
    }
    if (m_config.allowInsecureTLS) {
        QSslConfiguration ssl = req.sslConfiguration();
        ssl.setPeerVerifyMode(QSslSocket::VerifyNone);
        req.setSslConfiguration(ssl);
    }
    req.setHeader(QNetworkRequest::ContentLengthHeader, file->size());

    // QNAM 从 QFile 流式读取请求体，不会把整个文件载入内存
    QNetworkReply *reply = m_nam->put(req, file);
    file->setParent(reply);

    if (progress) {
        connect(reply, &QNetworkReply::uploadProgress, this, [progress](qint64 sent, qint64 total) {
            Q_UNUSED(total);
            progress(sent);
        });
    }
    if (isCancelled) {
        // 取消探针轮询：PUT 没有逐块回调，只能定时检查后 abort
        auto *timer = new QTimer(reply);
        timer->setInterval(200);
        connect(timer, &QTimer::timeout, reply, [reply, isCancelled]() {
            if (isCancelled && isCancelled())
                reply->abort();
        });
        timer->start();
    }

    QPointer<WebDAVAdapter> self(this);
    connect(reply, &QNetworkReply::finished, this, [reply, cb = std::move(cb), self]() mutable {
        reply->deleteLater();
        if (self)
            cb(self->errorFromReply(reply));
    });
}

void WebDAVAdapter::writeFrom(const QString &path, QIODevice *source, qint64 totalBytes,
                              UploadProgress progress, CancelProbe isCancelled, ErrorCallback cb)
{
    if (!cb)
        return;
    if (!source || totalBytes < 0) {
        cb(StorageError(StorageError::InvalidPath, QStringLiteral("中转数据源不可用")));
        return;
    }
    if (!source->isOpen() && !source->open(QIODevice::ReadOnly)) {
        cb(StorageError(StorageError::Underlying, QStringLiteral("中转数据源不可读")));
        return;
    }

    QNetworkRequest req(urlFor(path));
    if (!m_config.username.isEmpty()) {
        const QByteArray token =
            (m_config.username + QLatin1Char(':') + m_config.password).toUtf8().toBase64();
        req.setRawHeader(QByteArrayLiteral("Authorization"), QByteArrayLiteral("Basic ") + token);
    }
    if (m_config.allowInsecureTLS) {
        QSslConfiguration ssl = req.sslConfiguration();
        ssl.setPeerVerifyMode(QSslSocket::VerifyNone);
        req.setSslConfiguration(ssl);
    }
    // 长度必须显式给出：顺序设备无法自动推断，缺了会退化成 chunked
    req.setHeader(QNetworkRequest::ContentLengthHeader, totalBytes);

    // 源设备由调用方持有（跨源中转的 RelayStream），此处只借用
    QNetworkReply *reply = m_nam->put(req, source);

    if (progress) {
        connect(reply, &QNetworkReply::uploadProgress, this, [progress](qint64 sent, qint64 total) {
            Q_UNUSED(total);
            progress(sent);
        });
    }
    if (isCancelled) {
        auto *timer = new QTimer(reply);
        timer->setInterval(200);
        connect(timer, &QTimer::timeout, reply, [reply, isCancelled]() {
            if (isCancelled && isCancelled())
                reply->abort();
        });
        timer->start();
    }

    QPointer<WebDAVAdapter> self(this);
    connect(reply, &QNetworkReply::finished, this, [reply, cb = std::move(cb), self]() mutable {
        const StorageError error = self ? self->errorFromReply(reply) : StorageError();
        reply->deleteLater();
        cb(error);
    });
}

void WebDAVAdapter::makeDirectory(const QString &path, ErrorCallback cb)
{
    if (!cb)
        return;
    QNetworkReply *reply = sendRequest(QByteArrayLiteral("MKCOL"), path);
    QPointer<WebDAVAdapter> self(this);
    connect(reply, &QNetworkReply::finished, this, [reply, cb = std::move(cb), self]() mutable {
        reply->deleteLater();
        if (self)
            cb(self->errorFromReply(reply));
    });
}

void WebDAVAdapter::remove(const QString &path, ErrorCallback cb)
{
    if (!cb)
        return;
    QNetworkReply *reply = sendRequest(QByteArrayLiteral("DELETE"), path);
    QPointer<WebDAVAdapter> self(this);
    connect(reply, &QNetworkReply::finished, this, [reply, cb = std::move(cb), self]() mutable {
        reply->deleteLater();
        if (self)
            cb(self->errorFromReply(reply));
    });
}

void WebDAVAdapter::move(const QString &src, const QString &dst, ErrorCallback cb)
{
    if (!cb)
        return;
    QNetworkReply *reply = sendRequest(QByteArrayLiteral("MOVE"), src, {},
                                       {{QByteArrayLiteral("Destination"), urlFor(dst).toEncoded()},
                                        {QByteArrayLiteral("Overwrite"), QByteArrayLiteral("F")}});
    QPointer<WebDAVAdapter> self(this);
    connect(reply, &QNetworkReply::finished, this, [reply, cb = std::move(cb), self]() mutable {
        reply->deleteLater();
        if (self)
            cb(self->errorFromReply(reply));
    });
}

void WebDAVAdapter::copy(const QString &src, const QString &dst, ErrorCallback cb)
{
    if (!cb)
        return;
    QNetworkReply *reply = sendRequest(QByteArrayLiteral("COPY"), src, {},
                                       {{QByteArrayLiteral("Destination"), urlFor(dst).toEncoded()},
                                        {QByteArrayLiteral("Overwrite"), QByteArrayLiteral("F")}});
    QPointer<WebDAVAdapter> self(this);
    connect(reply, &QNetworkReply::finished, this, [reply, cb = std::move(cb), self]() mutable {
        reply->deleteLater();
        if (self)
            cb(self->errorFromReply(reply));
    });
}

} // namespace myhub
