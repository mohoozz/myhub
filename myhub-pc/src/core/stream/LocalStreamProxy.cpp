#include "LocalStreamProxy.h"

#include "core/utils/AppLogger.h"

#include <QElapsedTimer>
#include <QFileInfo>
#include <QHostAddress>
#include <QPointer>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTimer>
#include <QUrl>

#include <memory>

namespace myhub {

namespace {

constexpr int kMaxRequestBytes = 16 * 1024;      ///< 请求头上限，超了直接 400
constexpr qint64 kReadChunkBytes = 256LL * 1024; ///< 单次向数据源要的字节数
constexpr qint64 kMaxSocketBuffer = 4LL * 1024 * 1024;

QByteArray contentTypeFor(const QString &fileName)
{
    static const QHash<QString, QByteArray> types = {
        {QStringLiteral("mp4"), QByteArrayLiteral("video/mp4")},
        {QStringLiteral("m4v"), QByteArrayLiteral("video/mp4")},
        {QStringLiteral("mov"), QByteArrayLiteral("video/quicktime")},
        {QStringLiteral("mkv"), QByteArrayLiteral("video/x-matroska")},
        {QStringLiteral("webm"), QByteArrayLiteral("video/webm")},
        {QStringLiteral("avi"), QByteArrayLiteral("video/x-msvideo")},
        {QStringLiteral("ts"), QByteArrayLiteral("video/mp2t")},
        {QStringLiteral("flv"), QByteArrayLiteral("video/x-flv")},
        {QStringLiteral("wmv"), QByteArrayLiteral("video/x-ms-wmv")},
        {QStringLiteral("rmvb"), QByteArrayLiteral("application/vnd.rn-realmedia-vbr")},
        {QStringLiteral("mp3"), QByteArrayLiteral("audio/mpeg")},
        {QStringLiteral("m4a"), QByteArrayLiteral("audio/mp4")},
        {QStringLiteral("aac"), QByteArrayLiteral("audio/aac")},
        {QStringLiteral("flac"), QByteArrayLiteral("audio/flac")},
        {QStringLiteral("wav"), QByteArrayLiteral("audio/wav")},
        {QStringLiteral("ogg"), QByteArrayLiteral("audio/ogg")},
        {QStringLiteral("opus"), QByteArrayLiteral("audio/ogg")},
    };
    const QString ext = QFileInfo(fileName).suffix().toLower();
    return types.value(ext, QByteArrayLiteral("application/octet-stream"));
}

enum class RangeResult
{
    None, ///< 没有 Range 头 / 不认识的写法 → 整文件
    Valid,
    Unsatisfiable,
};

RangeResult parseRange(const QByteArray &value, qint64 size, qint64 *start, qint64 *end)
{
    if (!value.startsWith("bytes=") || value.contains(','))
        return RangeResult::None; // 多区间不支持，按整文件返回（RFC 允许）

    const QByteArray spec = value.mid(6).trimmed();
    const int dash = spec.indexOf('-');
    if (dash < 0)
        return RangeResult::None;

    const QByteArray from = spec.left(dash);
    const QByteArray to = spec.mid(dash + 1);

    if (from.isEmpty()) {
        if (to.isEmpty() || size <= 0)
            return RangeResult::None;
        const qint64 suffix = to.toLongLong();
        if (suffix <= 0)
            return RangeResult::Unsatisfiable;
        *start = qMax<qint64>(0, size - suffix);
        *end = size - 1;
        return RangeResult::Valid;
    }

    bool ok = false;
    const qint64 begin = from.toLongLong(&ok);
    if (!ok || begin < 0)
        return RangeResult::None;

    if (size >= 0 && begin >= size)
        return RangeResult::Unsatisfiable;

    qint64 finish = -1;
    if (!to.isEmpty()) {
        finish = to.toLongLong(&ok);
        if (!ok || finish < begin)
            return RangeResult::Unsatisfiable;
    }

    *start = begin;
    if (size >= 0)
        *end = finish < 0 ? size - 1 : qMin(finish, size - 1);
    else
        *end = finish;
    return RangeResult::Valid;
}

void writeHead(QTcpSocket *socket, int status, const QByteArray &reason,
               const QList<QPair<QByteArray, QByteArray>> &headers)
{
    QByteArray head;
    head += "HTTP/1.1 " + QByteArray::number(status) + ' ' + reason + "\r\n";
    for (const auto &header : headers)
        head += header.first + ": " + header.second + "\r\n";
    head += "Connection: close\r\n\r\n";
    socket->write(head);
}

void replyText(QTcpSocket *socket, int status, const QByteArray &reason, const QByteArray &body)
{
    writeHead(socket, status, reason,
              {{QByteArrayLiteral("Content-Type"), QByteArrayLiteral("text/plain; charset=utf-8")},
               {QByteArrayLiteral("Content-Length"), QByteArray::number(body.size())}});
    socket->write(body);
    socket->disconnectFromHost();
}

} // namespace

/**
 * 单条 HTTP 连接：解析请求头 → 定响应头 → 边读边写响应体。
 *
 * 响应体不整体缓冲：`read` 拿一块写一块，socket 缓冲超过 4MB 就靠
 * bytesWritten 回压，避免「8GB 的 4K 原盘把内存吃满」。
 */
class StreamHttpConnection : public QObject
{
public:
    StreamHttpConnection(LocalStreamProxy *proxy, QTcpSocket *socket);
    ~StreamHttpConnection() override;

private:
    void onReadyRead();
    void dispatch(const QByteArray &method, const QByteArray &path, const QByteArray &rangeHeader);
    void serve(LocalStreamProxy::Stream stream, qint64 start, qint64 length);
    void pump();
    void pumpLater();

    LocalStreamProxy *m_proxy = nullptr;
    QTcpSocket *m_socket = nullptr;
    QByteArray m_buffer;

    LocalStreamProxy::Stream m_stream;
    qint64 m_offset = 0;
    qint64 m_remaining = 0;
    bool m_busy = false;
    bool m_done = false;
};

StreamHttpConnection::StreamHttpConnection(LocalStreamProxy *proxy, QTcpSocket *socket)
    : QObject(proxy)
    , m_proxy(proxy)
    , m_socket(socket)
{
    m_socket->setParent(this);
    connect(m_socket, &QTcpSocket::readyRead, this, &StreamHttpConnection::onReadyRead);
    connect(m_socket, &QTcpSocket::bytesWritten, this, [this]() {
        if (!m_done && !m_busy)
            pump();
    });
    connect(m_socket, &QTcpSocket::disconnected, this, &QObject::deleteLater);
}

StreamHttpConnection::~StreamHttpConnection() = default;

void StreamHttpConnection::onReadyRead()
{
    if (m_done)
        return;

    m_buffer += m_socket->readAll();
    if (m_buffer.size() > kMaxRequestBytes) {
        m_done = true;
        replyText(m_socket, 400, "Bad Request", "request header too large");
        return;
    }

    const int headerEnd = m_buffer.indexOf("\r\n\r\n");
    if (headerEnd < 0)
        return;

    const QByteArray head = m_buffer.left(headerEnd);
    m_buffer.clear();

    const QList<QByteArray> lines = head.split('\n');
    if (lines.isEmpty()) {
        m_done = true;
        replyText(m_socket, 400, "Bad Request", "malformed request");
        return;
    }

    const QList<QByteArray> requestLine = lines.first().trimmed().split(' ');
    if (requestLine.size() < 2) {
        m_done = true;
        replyText(m_socket, 400, "Bad Request", "malformed request line");
        return;
    }

    QByteArray rangeHeader;
    for (int i = 1; i < lines.size(); ++i) {
        const QByteArray line = lines.at(i).trimmed();
        const int colon = line.indexOf(':');
        if (colon <= 0)
            continue;
        if (line.left(colon).toLower() == "range")
            rangeHeader = line.mid(colon + 1).trimmed();
    }

    dispatch(requestLine.at(0), requestLine.at(1), rangeHeader);
}

void StreamHttpConnection::dispatch(const QByteArray &method, const QByteArray &rawPath,
                                    const QByteArray &rangeHeader)
{
    if (method != "GET" && method != "HEAD") {
        m_done = true;
        replyText(m_socket, 405, "Method Not Allowed", "only GET/HEAD");
        return;
    }

    QByteArray path = rawPath;
    const int query = path.indexOf('?');
    if (query >= 0)
        path.truncate(query);
    path = QUrl::fromPercentEncoding(path).toUtf8();

    if (path == "/health") {
        m_done = true;
        replyText(m_socket, 200, "OK", "ok");
        return;
    }

    if (!path.startsWith("/stream/")) {
        m_done = true;
        replyText(m_socket, 404, "Not Found", "unknown route");
        return;
    }

    const QString rest = QString::fromUtf8(path.mid(8));
    const int slash = rest.indexOf(QLatin1Char('/'));
    const QString id = slash < 0 ? rest : rest.left(slash);

    const auto it = m_proxy->m_streams.constFind(id);
    if (it == m_proxy->m_streams.constEnd() || !it->read) {
        m_done = true;
        replyText(m_socket, 404, "Not Found", "stream not found");
        return;
    }

    LocalStreamProxy::Stream stream = it.value();
    if (stream.fileName.isEmpty())
        stream.fileName = slash < 0 ? id : rest.mid(slash + 1);

    const qint64 size = stream.size;
    qint64 start = 0;
    qint64 end = size >= 0 ? size - 1 : -1;
    const RangeResult result = parseRange(rangeHeader, size, &start, &end);

    if (result == RangeResult::Unsatisfiable) {
        m_done = true;
        writeHead(m_socket, 416, "Range Not Satisfiable",
                  {{QByteArrayLiteral("Content-Range"),
                    QByteArrayLiteral("bytes */") + QByteArray::number(qMax<qint64>(0, size))},
                   {QByteArrayLiteral("Content-Length"), QByteArrayLiteral("0")}});
        m_socket->disconnectFromHost();
        return;
    }

    const QByteArray type = contentTypeFor(stream.fileName);

    if (result == RangeResult::Valid) {
        // 长度未知且是开放区间（bytes=100-）时，length = -1 表示「一直读到 EOF」
        const qint64 length = end >= start ? end - start + 1 : (size >= 0 ? 0 : -1);
        QList<QPair<QByteArray, QByteArray>> headers = {
            {QByteArrayLiteral("Content-Type"), type},
            {QByteArrayLiteral("Accept-Ranges"), QByteArrayLiteral("bytes")},
            {QByteArrayLiteral("Content-Length"), QByteArray::number(length)},
        };
        if (size >= 0) {
            headers.append({QByteArrayLiteral("Content-Range"),
                            QByteArrayLiteral("bytes ") + QByteArray::number(start) + '-'
                                + QByteArray::number(end) + '/' + QByteArray::number(size)});
        }
        writeHead(m_socket, 206, "Partial Content", headers);
        if (method == "HEAD") {
            m_done = true;
            m_socket->disconnectFromHost();
            return;
        }
        serve(std::move(stream), start, length);
        return;
    }

    QList<QPair<QByteArray, QByteArray>> headers = {
        {QByteArrayLiteral("Content-Type"), type},
        {QByteArrayLiteral("Accept-Ranges"), QByteArrayLiteral("bytes")},
    };
    if (size >= 0)
        headers.append({QByteArrayLiteral("Content-Length"), QByteArray::number(size)});
    writeHead(m_socket, 200, "OK", headers);
    if (method == "HEAD") {
        m_done = true;
        m_socket->disconnectFromHost();
        return;
    }
    serve(std::move(stream), 0, size >= 0 ? size : -1);
}

void StreamHttpConnection::serve(LocalStreamProxy::Stream stream, qint64 start, qint64 length)
{
    m_stream = std::move(stream);
    m_offset = start;
    m_remaining = length;
    if (m_remaining == 0) {
        m_done = true;
        m_socket->disconnectFromHost();
        return;
    }
    pump();
}

void StreamHttpConnection::pump()
{
    if (m_done || m_busy)
        return;
    if (m_socket->state() != QAbstractSocket::ConnectedState) {
        m_done = true;
        return;
    }
    if (m_socket->bytesToWrite() > kMaxSocketBuffer)
        return; // 等 bytesWritten 回压

    const qint64 want = m_remaining > 0 ? qMin(kReadChunkBytes, m_remaining) : kReadChunkBytes;
    m_busy = true;

    QPointer<StreamHttpConnection> self(this);
    m_stream.read(m_offset, want, [self](QByteArray data, StorageError error) {
        if (!self)
            return;
        self->m_busy = false;
        if (self->m_done)
            return;
        if (!error.isNull()) {
            MH_WARN(Stream, QStringLiteral("回环代流读取失败：%1").arg(error.message()));
            self->m_done = true;
            self->m_socket->abort();
            return;
        }
        if (data.isEmpty()) {
            self->m_done = true;
            self->m_socket->disconnectFromHost();
            return;
        }
        self->m_socket->write(data);
        self->m_offset += data.size();
        if (self->m_remaining > 0)
            self->m_remaining -= data.size();
        if (self->m_remaining == 0) {
            self->m_done = true;
            self->m_socket->disconnectFromHost();
            return;
        }
        self->pumpLater();
    });
}

void StreamHttpConnection::pumpLater()
{
    QTimer::singleShot(0, this, [this]() { pump(); });
}

// ---------------------------------------------------------------- 代理本体

LocalStreamProxy::LocalStreamProxy(QObject *parent)
    : QObject(parent)
{
    m_server = new QTcpServer(this);
    connect(m_server, &QTcpServer::newConnection, this, &LocalStreamProxy::onNewConnection);
}

LocalStreamProxy::~LocalStreamProxy()
{
    m_streams.clear();
}

void LocalStreamProxy::onNewConnection()
{
    while (QTcpSocket *socket = m_server->nextPendingConnection())
        new StreamHttpConnection(this, socket);
}

bool LocalStreamProxy::start(quint16 port)
{
    if (m_server->isListening())
        return true;

    for (int attempt = 0; attempt < 5; ++attempt) {
        const quint16 want = port == 0 ? 0 : static_cast<quint16>(port + attempt);
        if (m_server->listen(QHostAddress::LocalHost, want)) {
            m_port = m_server->serverPort();
            MH_INFO(Stream, QStringLiteral("回环代流服务已启动：%1").arg(baseUrl()));
            return true;
        }
        MH_WARN(Stream,
                QStringLiteral("监听端口 %1 失败：%2").arg(want).arg(m_server->errorString()));
    }
    m_port = 0;
    return false;
}

void LocalStreamProxy::stop()
{
    if (!m_server->isListening())
        return;
    m_server->close();
    m_port = 0;
}

bool LocalStreamProxy::isRunning() const
{
    return m_server && m_server->isListening();
}

QString LocalStreamProxy::baseUrl() const
{
    return QStringLiteral("http://127.0.0.1:%1").arg(m_port);
}

QString LocalStreamProxy::urlFor(const QString &id, const QString &fileName) const
{
    QString name = fileName.isEmpty() ? QStringLiteral("stream") : fileName;
    return QStringLiteral("%1/stream/%2/%3")
        .arg(baseUrl(), QString::fromLatin1(QUrl::toPercentEncoding(id)),
             QString::fromLatin1(QUrl::toPercentEncoding(name)));
}

QString LocalStreamProxy::registerStream(const QString &id, Stream stream)
{
    if (id.isEmpty() || !stream.read)
        return {};
    if (!isRunning())
        start(0);

    m_streams.insert(id, stream);
    return urlFor(id, m_streams.value(id).fileName);
}

void LocalStreamProxy::unregisterStream(const QString &id)
{
    m_streams.remove(id);
}

void LocalStreamProxy::clearStreams()
{
    m_streams.clear();
}

void LocalStreamProxy::verifyHealth()
{
    if (m_healthInFlight)
        return;

    if (!isRunning()) {
        // 未监听（如监听已僵死被 stop）：按换端口重建处理，并广播给上层重开播放
        rebuildListener();
        return;
    }

    m_healthInFlight = true;
    QElapsedTimer timer;
    timer.start();

    auto *socket = new QTcpSocket(this);
    auto *timeout = new QTimer(this);
    timeout->setSingleShot(true);
    auto finished = std::make_shared<bool>(false);

    auto finishProbe = [this, socket, timeout, timer, finished](bool ok, const QString &error) {
        if (*finished)
            return;
        *finished = true;
        m_healthInFlight = false;
        m_lastHealthOk = ok;
        m_lastHealthMs = static_cast<int>(timer.elapsed());
        m_lastHealthError = error;
        socket->deleteLater();
        timeout->deleteLater();
        emit healthChecked(ok);
        if (!ok) {
            MH_WARN(Stream,
                    QStringLiteral("回环代流健康探活失败（%1），换端口重建监听").arg(error));
            rebuildListener();
        }
    };

    connect(timeout, &QTimer::timeout, this,
            [finishProbe]() { finishProbe(false, QStringLiteral("探活超时")); });
    connect(socket, &QTcpSocket::connected, this, [socket]() {
        socket->write("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    });
    connect(socket, &QTcpSocket::readyRead, this, [socket, finishProbe]() {
        const QByteArray reply = socket->readAll();
        finishProbe(reply.contains(" 200 "),
                    reply.isEmpty() ? QStringLiteral("空响应") : QString());
    });
    connect(socket, &QTcpSocket::errorOccurred, this,
            [finishProbe, socket]() { finishProbe(false, socket->errorString()); });

    timeout->start(m_healthTimeoutMs);
    socket->connectToHost(QHostAddress::LocalHost, m_port);
}

void LocalStreamProxy::rebuildListener()
{
    const quint16 oldPort = m_port;
    stop();
    if (!start(0)) {
        m_lastHealthError = QStringLiteral("重建监听失败");
        emit healthChecked(false);
        return;
    }

    ++m_rebuildCount;
    m_lastHealthOk = true;
    m_lastHealthMs = 0;
    m_lastHealthError.clear();
    MH_INFO(Stream,
            QStringLiteral("回环代流换端口重建：%1 → %2（%3 条流）")
                .arg(oldPort)
                .arg(m_port)
                .arg(m_streams.size()));
    emit listenerRebuilt(oldPort, m_port);
}

QVariantMap LocalStreamProxy::healthSnapshot() const
{
    return QVariantMap{
        {QStringLiteral("running"), isRunning()},
        {QStringLiteral("port"), m_port},
        {QStringLiteral("baseUrl"), baseUrl()},
        {QStringLiteral("streams"), m_streams.size()},
        {QStringLiteral("lastHealthOk"), m_lastHealthOk},
        {QStringLiteral("lastHealthMs"), m_lastHealthMs},
        {QStringLiteral("lastError"), m_lastHealthError},
        {QStringLiteral("rebuilds"), m_rebuildCount},
    };
}

} // namespace myhub
