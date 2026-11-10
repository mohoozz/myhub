#include "TestServer.h"

#include <QBuffer>
#include <QList>

namespace {

QByteArray htmlPage(const QString &title, const QString &bgColor, const QString &label)
{
    // 关键点：window.__ticks 由 100ms 定时器自增。
    // 若标签被冻结（Chromium 会把不可见页冻结），该计数器会停止增长——
    // 这正是「标签保活」要判定的东西，故计数器必须由页面自己驱动，
    // 不能由外部 runJavaScript 触发（那会让页面被动唤醒，测不出冻结）。
    return QStringLiteral(
               "<!doctype html><html><head><meta charset=\"utf-8\">"
               "<link rel=\"icon\" type=\"image/png\" href=\"/fav.png\">"
               "<title>%1</title>"
               "<style>html,body{margin:0;height:100%%;overflow:hidden}"
               "body{background:%2}"
               "#badge{position:absolute;top:60px;left:60px;color:#fff;"
               "font:bold 72px sans-serif;font-family:Consolas,monospace}"
               "#ticks{position:absolute;bottom:60px;left:60px;color:#fff;"
               "font:bold 48px monospace}</style></head><body>"
               "<div id=\"badge\">%1</div><div id=\"ticks\">0</div>"
               "<script>window.__ticks=0;"
               "setInterval(function(){window.__ticks++;"
               "document.getElementById('ticks').textContent=window.__ticks;},100);"
               "</script></body></html>")
        .arg(title, bgColor, label)
        .toUtf8();
}

QByteArray uaPage()
{
    // 把 navigator.userAgent 同时写进 title 与正文：
    // title 可从 QML 的 title 属性直接读，无需注入 JS。
    return QStringLiteral(
               "<!doctype html><html><head><meta charset=\"utf-8\">"
               "<title>UA_PENDING</title>"
               "<style>html,body{margin:0;height:100%;background:#111}"
               "div{color:#0f0;font:16px monospace;padding:20px;word-break:break-all}"
               "</style></head><body><div id=\"ua\"></div>"
               "<script>var u=navigator.userAgent;"
               "document.title='UA:'+u;"
               "document.getElementById('ua').textContent=u;</script>"
               "</body></html>")
        .toUtf8();
}

} // namespace

TestServer::TestServer(QObject *parent)
    : QTcpServer(parent)
{
    // 16x16 纯色 + 中心方块，保证不是全透明（否则 icon 可能被视为无效）
    QImage img(16, 16, QImage::Format_ARGB32);
    img.fill(QColor(0x1E, 0x3A, 0x8A));
    for (int y = 5; y < 11; ++y)
        for (int x = 5; x < 11; ++x)
            img.setPixelColor(x, y, QColor(0xF5, 0x9E, 0x0B));

    QBuffer buf(&m_favicon);
    buf.open(QIODevice::WriteOnly);
    img.save(&buf, "PNG");

    connect(this, &QTcpServer::newConnection, this, &TestServer::onNewConnection);
}

QByteArray TestServer::makeDownloadBody()
{
    const int n = 128 * 1024;
    QByteArray body(n, Qt::Uninitialized);
    for (int i = 0; i < n; ++i)
        body[i] = static_cast<char>((i * 31 + 7) & 0xFF);
    return body;
}

void TestServer::onNewConnection()
{
    while (hasPendingConnections()) {
        QTcpSocket *sock = nextPendingConnection();
        auto *buf = new QByteArray();

        connect(sock, &QTcpSocket::readyRead, this, [this, sock, buf] {
            buf->append(sock->readAll());
            // 请求头收全才响应；本地探针无 body，故见到空行即完整
            if (buf->indexOf("\r\n\r\n") < 0)
                return;
            respond(sock, *buf);
            buf->clear();
            sock->disconnectFromHost();
        });
        connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
        connect(sock, &QTcpSocket::disconnected, this, [buf] { delete buf; });
    }
}

void TestServer::respond(QTcpSocket *sock, const QByteArray &request)
{
    const QList<QByteArray> lines = request.split('\n');
    if (lines.isEmpty())
        return;

    const QList<QByteArray> start = lines.first().trimmed().split(' ');
    const QByteArray method = start.value(0);
    QByteArray path = start.value(1);
    const int query = path.indexOf('?');
    if (query >= 0)
        path = path.left(query);

    // 记录实际收到的 User-Agent —— UA 覆盖要能从**服务端**这一侧被证实，
    // 只看 navigator.userAgent 无法排除「页面自己编的」。
    for (const QByteArray &line : lines) {
        const QByteArray lower = line.toLower();
        if (lower.startsWith("user-agent:")) {
            const QString p = QString::fromUtf8(path);
            m_ua.insert(p, QString::fromUtf8(line.mid(11)).trimmed());
            break;
        }
    }
    const QString key = QString::fromUtf8(path);
    m_reqs.insert(key, m_reqs.value(key) + 1);

    QByteArray status = "HTTP/1.1 200 OK\r\n";
    QByteArray contentType = "text/html; charset=utf-8";
    QByteArray extra;
    QByteArray body;

    if (path == QLatin1String("/tab1")) {
        body = htmlPage(QStringLiteral("TAB1"), QStringLiteral("#1E3A8A"),
                        QStringLiteral("tab-1"));
    } else if (path == QLatin1String("/tab2")) {
        body = htmlPage(QStringLiteral("TAB2"), QStringLiteral("#166534"),
                        QStringLiteral("tab-2"));
    } else if (path == QLatin1String("/tab3")) {
        body = htmlPage(QStringLiteral("TAB3"), QStringLiteral("#7C2D12"),
                        QStringLiteral("tab-3"));
    } else if (path == QLatin1String("/ua")) {
        body = uaPage();
    } else if (path == QLatin1String("/fav.png")) {
        contentType = "image/png";
        body = m_favicon;
    } else if (path == QLatin1String("/download")) {
        contentType = "application/octet-stream";
        body = makeDownloadBody();
        // 触发下载而非内联渲染
        extra += "Content-Disposition: attachment; filename=\"s4-download.bin\"\r\n";
    } else {
        status = "HTTP/1.1 404 Not Found\r\n";
        body = "not found";
    }

    QByteArray resp = status;
    resp += "Content-Type: " + contentType + "\r\n";
    resp += "Content-Length: " + QByteArray::number(body.size()) + "\r\n";
    // 禁止缓存：否则重载可能命中缓存，UA 变更「看起来没生效」
    resp += "Cache-Control: no-store\r\n";
    resp += extra;
    resp += "Connection: close\r\n\r\n";
    if (method != QLatin1String("HEAD"))
        resp += body;

    sock->write(resp);
    sock->flush();
}
