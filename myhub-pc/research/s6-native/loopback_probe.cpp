// S6-C：回环 HTTP 服务（Range/206）可用性与被拦截风险评估
//
// 背景：方案中用 QTcpServer 在 127.0.0.1 起一个本地 HTTP 服务，把远端
// WebDAV/SMB 流以 Range 方式喂给 libmpv（§4.1）。风险是被安全软件/防火墙拦截。
//
// 本探针评估：
//   1. 能否在回环地址绑定监听端口（无需管理员、无需防火墙放行）
//   2. Range 请求能否正确返回 206 Partial Content
//   3. libmpv 能否通过该回环 URL 拉流并解码（端到端闭环）
//   4. 记录本机防火墙状态与监听可达性，作为拦截概率评估依据

#include <mpv/client.h>

#include <QCoreApplication>
#include <QEventLoop>
#include <QFile>
#include <QHostAddress>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTextStream>
#include <QTimer>

#include <cmath>

namespace {

QTextStream *g_out = nullptr;
bool g_allOk = true;

void report(const QString &line)
{
    fprintf(stdout, "%s\n", qPrintable(line));
    fflush(stdout);
    if (g_out) { *g_out << line << '\n'; g_out->flush(); }
}

void check(bool cond, const QString &label, const QString &detail)
{
    if (!cond) g_allOk = false;
    report(QStringLiteral("[%1] %2 %3")
               .arg(cond ? QStringLiteral("OK") : QStringLiteral("FAIL"),
                    label.leftJustified(24), detail));
}

// 极简 Range HTTP 服务：把本地文件按 Range 以 206 返回
class RangeServer : public QTcpServer
{
public:
    explicit RangeServer(const QString &filePath, QObject *parent = nullptr)
        : QTcpServer(parent), m_path(filePath) {}

    int requestCount() const { return m_requests; }
    int rangeRequestCount() const { return m_rangeRequests; }

protected:
    void incomingConnection(qintptr handle) override
    {
        auto *sock = new QTcpSocket(this);
        sock->setSocketDescriptor(handle);
        connect(sock, &QTcpSocket::readyRead, this, [this, sock] { serve(sock); });
        connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
    }

private:
    void serve(QTcpSocket *sock)
    {
        const QByteArray req = sock->readAll();
        if (!req.contains("\r\n\r\n"))
            return;
        ++m_requests;

        QFile f(m_path);
        if (!f.open(QIODevice::ReadOnly)) {
            sock->write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
            sock->disconnectFromHost();
            return;
        }
        const qint64 total = f.size();

        // 解析 Range: bytes=start-end
        qint64 start = 0, end = total - 1;
        bool isRange = false;
        const int rp = req.indexOf("Range: bytes=");
        if (rp >= 0) {
            isRange = true;
            ++m_rangeRequests;
            const int vs = rp + static_cast<int>(strlen("Range: bytes="));
            const int ve = req.indexOf("\r\n", vs);
            const QByteArray spec = req.mid(vs, ve - vs).trimmed();
            const int dash = spec.indexOf('-');
            if (dash > 0)
                start = spec.left(dash).toLongLong();
            else if (dash == 0)
                start = 0;
            if (dash >= 0 && dash + 1 < spec.size())
                end = spec.mid(dash + 1).toLongLong();
        }
        start = qBound<qint64>(0, start, total > 0 ? total - 1 : 0);
        end = qBound<qint64>(start, end, total - 1);
        const qint64 len = end - start + 1;

        const bool headOnly = req.startsWith("HEAD");

        QByteArray header;
        header += isRange ? "HTTP/1.1 206 Partial Content\r\n"
                          : "HTTP/1.1 200 OK\r\n";
        header += "Accept-Ranges: bytes\r\n";
        header += "Content-Type: video/x-matroska\r\n";
        header += "Content-Length: " + QByteArray::number(len) + "\r\n";
        if (isRange) {
            header += "Content-Range: bytes " + QByteArray::number(start) + "-"
                      + QByteArray::number(end) + "/" + QByteArray::number(total) + "\r\n";
        }
        header += "Connection: close\r\n\r\n";
        sock->write(header);

        if (!headOnly) {
            f.seek(start);
            qint64 remaining = len;
            while (remaining > 0 && sock->state() == QAbstractSocket::ConnectedState) {
                const QByteArray chunk = f.read(qMin<qint64>(64 * 1024, remaining));
                if (chunk.isEmpty())
                    break;
                sock->write(chunk);
                sock->waitForBytesWritten(3000);
                remaining -= chunk.size();
            }
        }
        sock->disconnectFromHost();
    }

    QString m_path;
    int m_requests = 0;
    int m_rangeRequests = 0;
};

} // namespace

int main(int argc, char *argv[])
{
    QCoreApplication app(argc, argv);

    const QString mediaFile = argc > 1 ? QString::fromLocal8Bit(argv[1])
                                       : QStringLiteral("hevc_1080p.mkv");

    QFile outFile(QStringLiteral("s6-loopback-report.txt"));
    outFile.open(QIODevice::WriteOnly | QIODevice::Text);
    QTextStream ts(&outFile);
    g_out = &ts;

    report(QStringLiteral("=== S6-C: loopback HTTP (Range/206) feasibility ==="));
    report(QStringLiteral("serving : %1").arg(mediaFile));

    if (!QFile::exists(mediaFile)) {
        check(false, QStringLiteral("media file"), QStringLiteral("not found"));
        return 2;
    }

    // ---- 1) 绑定回环端口 ----
    RangeServer server(mediaFile);
    const bool listening = server.listen(QHostAddress::LocalHost, 0);
    check(listening,
          QStringLiteral("bind 127.0.0.1"),
          listening ? QStringLiteral("port=%1 (ephemeral, no admin rights needed)")
                          .arg(server.serverPort())
                    : server.errorString());
    if (!listening)
        return 1;

    const quint16 port = server.serverPort();
    const QString url = QStringLiteral("http://127.0.0.1:%1/stream.mkv").arg(port);

    // ---- 2) 自测 Range 请求 ----
    //
    // 关键：**不能用 waitForReadyRead()**。该调用只泵送自身 socket 的事件，
    // 服务端的 accept/readyRead 得不到处理，会死等到超时。
    // 必须用 QEventLoop 让服务端与客户端在同一事件循环中共同推进。
    {
        QTcpSocket probe;
        QByteArray resp;
        QEventLoop loop;

        QObject::connect(&probe, &QTcpSocket::readyRead, &loop,
                         [&] { resp += probe.readAll(); });
        QObject::connect(&probe, &QTcpSocket::disconnected, &loop, &QEventLoop::quit);
        QObject::connect(&probe, &QTcpSocket::connected, &probe, [&] {
            probe.write("GET /stream.mkv HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                        "Range: bytes=100-199\r\nConnection: close\r\n\r\n");
        });

        QTimer::singleShot(8000, &loop, &QEventLoop::quit);   // 兜底
        probe.connectToHost(QHostAddress::LocalHost, port);
        loop.exec();

        const bool is206 = resp.startsWith("HTTP/1.1 206");
        const bool hasRange = resp.contains("Content-Range: bytes 100-199/");
        const int bodyPos = resp.indexOf("\r\n\r\n");
        const int bodyLen = bodyPos >= 0 ? resp.size() - bodyPos - 4 : -1;

        check(is206 && hasRange && bodyLen == 100,
              QStringLiteral("Range -> 206"),
              QStringLiteral("status206=%1 contentRange=%2 bodyLen=%3")
                  .arg(is206).arg(hasRange).arg(bodyLen));
    }

    // ---- 3) libmpv 经回环 URL 拉流解码（端到端闭环）----
    //
    // libmpv 在自己的线程发 HTTP 请求，服务端在主线程，
    // 故**必须保持主线程事件循环运行**：用 QTimer 非阻塞轮询 mpv 事件，
    // 而不是 mpv_wait_event 阻塞主线程（那样服务端永远 accept 不到连接）。
    {
        mpv_handle *mpv = mpv_create();
        bool inited = false;

        if (mpv) {
            mpv_set_option_string(mpv, "vo", "null");
            mpv_set_option_string(mpv, "ao", "null");
            mpv_set_option_string(mpv, "config", "no");
            mpv_set_option_string(mpv, "msg-level", "all=no");
            inited = mpv_initialize(mpv) >= 0;
        }

        if (!inited) {
            check(false, QStringLiteral("libmpv over loopback"),
                  QStringLiteral("mpv init failed"));
            if (mpv) mpv_terminate_destroy(mpv);
        } else {
            const QByteArray u = url.toUtf8();
            const char *cmd[] = {"loadfile", u.constData(), nullptr};
            mpv_command(mpv, cmd);

            QEventLoop loop;
            bool loaded = false, failed = false;
            double pos = 0;
            QString endErr;

            QTimer poll;
            poll.setInterval(50);
            QObject::connect(&poll, &QTimer::timeout, &loop, [&] {
                // 非阻塞取事件（timeout=0），把时间让回事件循环
                for (;;) {
                    mpv_event *ev = mpv_wait_event(mpv, 0);
                    if (!ev || ev->event_id == MPV_EVENT_NONE)
                        break;
                    if (ev->event_id == MPV_EVENT_FILE_LOADED)
                        loaded = true;
                    if (ev->event_id == MPV_EVENT_END_FILE) {
                        auto *ef = static_cast<mpv_event_end_file *>(ev->data);
                        if (ef && ef->reason == MPV_END_FILE_REASON_ERROR) {
                            failed = true;
                            endErr = QString::fromUtf8(mpv_error_string(ef->error));
                            loop.quit();
                            return;
                        }
                    }
                }
                if (loaded) {
                    double p = 0;
                    if (mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &p) >= 0
                        && p > 0.5) {
                        pos = p;
                        loop.quit();
                    }
                }
            });
            poll.start();
            QTimer::singleShot(25000, &loop, &QEventLoop::quit);
            loop.exec();
            poll.stop();

            char *codec = nullptr;
            mpv_get_property(mpv, "video-codec", MPV_FORMAT_STRING, &codec);

            const QString detail = failed
                ? QStringLiteral("end-file error: %1").arg(endErr)
                : QStringLiteral("loaded=%1 time-pos=%2s codec=%3 httpReqs=%4 rangeReqs=%5")
                      .arg(loaded).arg(pos, 0, 'f', 2)
                      .arg(codec ? QString::fromUtf8(codec) : QStringLiteral("?"))
                      .arg(server.requestCount()).arg(server.rangeRequestCount());
            if (codec) mpv_free(codec);

            check(loaded && pos > 0.5,
                  QStringLiteral("libmpv over loopback"), detail);
            mpv_terminate_destroy(mpv);
        }
    }

    // ---- 4) mpv 是否真的发出了 Range 请求（决定 seek 能否按需取片段）----
    check(server.rangeRequestCount() > 0,
          QStringLiteral("mpv issues Range"),
          QStringLiteral("%1 of %2 requests carried Range header")
              .arg(server.rangeRequestCount()).arg(server.requestCount()));

    report(QStringLiteral("\n%1")
               .arg(g_allOk ? QStringLiteral("RESULT: S6-C PASSED")
                            : QStringLiteral("RESULT: S6-C HAS FAILURES")));
    outFile.close();
    return g_allOk ? 0 : 1;
}
