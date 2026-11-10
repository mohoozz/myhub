#include "core/stream/LocalStreamProxy.h"

#include <QEventLoop>
#include <QHostAddress>
#include <QSignalSpy>
#include <QTcpSocket>
#include <QTest>
#include <QTimer>

using namespace myhub;

namespace {

struct HttpResponse
{
    int status = 0;
    QList<QPair<QByteArray, QByteArray>> headers;
    QByteArray body;

    QByteArray header(const QByteArray &name) const
    {
        for (const auto &pair : headers) {
            if (pair.first.toLower() == name.toLower())
                return pair.second;
        }
        return {};
    }
};

HttpResponse request(quint16 port, const QByteArray &method, const QByteArray &path,
                     const QByteArray &range = QByteArray())
{
    QByteArray raw;
    {
        QTcpSocket socket;
        QEventLoop loop;
        QObject::connect(
            &socket, &QTcpSocket::connected, &socket, [&socket, method, path, range]() {
                QByteArray req = method + ' ' + path + " HTTP/1.1\r\nHost: 127.0.0.1\r\n";
                if (!range.isEmpty())
                    req += "Range: " + range + "\r\n";
                req += "Connection: close\r\n\r\n";
                socket.write(req);
            });
        QObject::connect(&socket, &QTcpSocket::readyRead, &socket,
                         [&socket, &raw]() { raw += socket.readAll(); });
        QObject::connect(&socket, &QTcpSocket::disconnected, &loop, &QEventLoop::quit);
        QObject::connect(&socket, &QTcpSocket::errorOccurred, &loop, [&loop]() { loop.quit(); });
        QTimer::singleShot(5000, &loop, &QEventLoop::quit);
        socket.connectToHost(QHostAddress::LocalHost, port);
        loop.exec();
    }

    HttpResponse response;
    const int split = raw.indexOf("\r\n\r\n");
    if (split < 0) {
        response.body = raw;
        return response;
    }
    const QByteArray head = raw.left(split);
    response.body = raw.mid(split + 4);

    const QList<QByteArray> lines = head.split('\n');
    const QList<QByteArray> statusLine = lines.value(0).trimmed().split(' ');
    if (statusLine.size() >= 2)
        response.status = statusLine.at(1).toInt();

    for (int i = 1; i < lines.size(); ++i) {
        const QByteArray line = lines.at(i).trimmed();
        const int colon = line.indexOf(':');
        if (colon > 0)
            response.headers.append({line.left(colon), line.mid(colon + 1).trimmed()});
    }
    return response;
}

QByteArray makePayload(int size)
{
    QByteArray data(size, Qt::Uninitialized);
    for (int i = 0; i < size; ++i)
        data[i] = static_cast<char>((i * 17 + 3) % 251);
    return data;
}

} // namespace

class TestStreamProxy : public QObject
{
    Q_OBJECT

private slots:
    void fullGetReturnsWholeFile();
    void rangeGetReturns206();
    void suffixRangeReturnsTail();
    void unsatisfiableRangeReturns416();
    void headHasNoBody();
    void unknownStreamReturns404();
    void healthProbeSucceeds();
    void verifyHealthRebuildsAfterListenerStop();

private:
    LocalStreamProxy m_proxy;
    QByteArray m_payload = makePayload(700 * 1024);
    QString m_url;
};

void TestStreamProxy::fullGetReturnsWholeFile()
{
    QVERIFY(m_proxy.start(0));
    m_url = m_proxy.registerStream(
        QStringLiteral("s1"),
        LocalStreamProxy::Stream{
            m_payload.size(),
            QStringLiteral("movie.mkv"),
            [this](qint64 start, qint64 length, LocalStreamProxy::ReadCallback cb) {
                const qint64 available = qMin(length, qint64(m_payload.size()) - start);
                if (available <= 0) {
                    cb({}, StorageError());
                    return;
                }
                cb(m_payload.mid(static_cast<int>(start), static_cast<int>(available)),
                   StorageError());
            },
        });
    QVERIFY(m_url.startsWith(m_proxy.baseUrl()));

    const HttpResponse response = request(m_proxy.port(), "GET", "/stream/s1/movie.mkv");
    QCOMPARE(response.status, 200);
    QCOMPARE(response.header("Content-Length").toLongLong(), qint64(m_payload.size()));
    QCOMPARE(response.header("Accept-Ranges"), QByteArrayLiteral("bytes"));
    QCOMPARE(response.header("Content-Type"), QByteArrayLiteral("video/x-matroska"));
    QCOMPARE(response.body, m_payload);
}

void TestStreamProxy::rangeGetReturns206()
{
    const HttpResponse response =
        request(m_proxy.port(), "GET", "/stream/s1/movie.mkv", "bytes=1000-1999");
    QCOMPARE(response.status, 206);
    QCOMPARE(response.body, m_payload.mid(1000, 1000));
    QCOMPARE(response.header("Content-Range"),
             QStringLiteral("bytes 1000-1999/%1").arg(m_payload.size()).toLatin1());
    QCOMPARE(response.header("Content-Length").toLongLong(), qint64(1000));
}

void TestStreamProxy::suffixRangeReturnsTail()
{
    const HttpResponse response =
        request(m_proxy.port(), "GET", "/stream/s1/movie.mkv", "bytes=-4096");
    QCOMPARE(response.status, 206);
    QCOMPARE(response.body, m_payload.right(4096));
}

void TestStreamProxy::unsatisfiableRangeReturns416()
{
    const HttpResponse response = request(m_proxy.port(), "GET", "/stream/s1/movie.mkv",
                                          "bytes=" + QByteArray::number(m_payload.size()) + "-");
    QCOMPARE(response.status, 416);
    QCOMPARE(response.header("Content-Range"), "bytes */" + QByteArray::number(m_payload.size()));
    QVERIFY(response.body.isEmpty());
}

void TestStreamProxy::headHasNoBody()
{
    const HttpResponse response = request(m_proxy.port(), "HEAD", "/stream/s1/movie.mkv");
    QCOMPARE(response.status, 200);
    QCOMPARE(response.header("Content-Length").toLongLong(), qint64(m_payload.size()));
    QVERIFY(response.body.isEmpty());
}

void TestStreamProxy::unknownStreamReturns404()
{
    const HttpResponse response = request(m_proxy.port(), "GET", "/stream/nope/x.mkv");
    QCOMPARE(response.status, 404);
}

void TestStreamProxy::healthProbeSucceeds()
{
    QSignalSpy spy(&m_proxy, &LocalStreamProxy::healthChecked);
    const quint16 port = m_proxy.port();

    m_proxy.verifyHealth();
    QTRY_VERIFY_WITH_TIMEOUT(!spy.isEmpty(), 3000);
    QCOMPARE(spy.first().at(0).toBool(), true);
    QCOMPARE(m_proxy.port(), port);

    const QVariantMap snapshot = m_proxy.healthSnapshot();
    QCOMPARE(snapshot.value(QStringLiteral("lastHealthOk")).toBool(), true);
    QCOMPARE(snapshot.value(QStringLiteral("rebuilds")).toInt(), 0);

    const HttpResponse health = request(m_proxy.port(), "GET", "/health");
    QCOMPARE(health.status, 200);
    QCOMPARE(health.body, QByteArrayLiteral("ok"));
}

void TestStreamProxy::verifyHealthRebuildsAfterListenerStop()
{
    QCOMPARE(m_proxy.streamCount(), 1);

    QSignalSpy spy(&m_proxy, &LocalStreamProxy::listenerRebuilt);
    m_proxy.stop();
    QVERIFY(!m_proxy.isRunning());

    m_proxy.verifyHealth();
    QTRY_VERIFY_WITH_TIMEOUT(spy.count() == 1, 3000);
    QVERIFY(m_proxy.isRunning());
    QCOMPARE(m_proxy.streamCount(), 1); // 流注册信息在换端口后仍保留

    const HttpResponse response =
        request(m_proxy.port(), "GET", "/stream/s1/movie.mkv", "bytes=0-9");
    QCOMPARE(response.status, 206);
    QCOMPARE(response.body, m_payload.left(10));
}

QTEST_GUILESS_MAIN(TestStreamProxy)
#include "tst_streamproxy.moc"
