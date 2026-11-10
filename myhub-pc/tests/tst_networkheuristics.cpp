#include <QtTest>

#include "core/network/NetworkHeuristics.h"

using namespace myhub;

/**
 * 内外网判定（PC-101）：
 * 「测试成功提示区分内网可达 / 外网可达」依赖本判定。
 */
class TestNetworkHeuristics : public QObject
{
    Q_OBJECT
private slots:
    void privateHosts_data();
    void privateHosts();
    void hostExtraction_data();
    void hostExtraction();
    void scopeMapping();
};

void TestNetworkHeuristics::privateHosts_data()
{
    QTest::addColumn<QString>("url");
    QTest::addColumn<bool>("isPrivate");

    // 私有段
    QTest::newRow("10.x") << "http://10.0.0.5:5005" << true;
    QTest::newRow("172.16") << "http://172.16.3.9/dav" << true;
    QTest::newRow("172.31") << "http://172.31.0.1" << true;
    QTest::newRow("192.168") << "https://192.168.1.100:8443" << true;
    QTest::newRow("127.0.0.1") << "http://127.0.0.1:8080" << true;
    QTest::newRow("169.254") << "http://169.254.1.1" << true;
    QTest::newRow("localhost") << "http://localhost:5005" << true;
    QTest::newRow(".local") << "http://nas.local/dav" << true;
    QTest::newRow(".lan") << "http://nas.lan" << true;
    QTest::newRow("no dot host") << "http://nas:5005" << true;

    // 公网
    QTest::newRow("public ip") << "http://8.8.8.8" << false;
    QTest::newRow("172.15 edge") << "http://172.15.0.1" << false;
    QTest::newRow("172.32 edge") << "http://172.32.0.1" << false;
    QTest::newRow("domain") << "https://dav.example.com" << false;
    QTest::newRow("subdomain") << "https://a.b.example.org/dav" << false;
}

void TestNetworkHeuristics::privateHosts()
{
    QFETCH(QString, url);
    QFETCH(bool, isPrivate);
    QCOMPARE(NetworkHeuristics::isPrivateHost(url), isPrivate);
}

void TestNetworkHeuristics::hostExtraction_data()
{
    QTest::addColumn<QString>("input");
    QTest::addColumn<QString>("host");

    QTest::newRow("full url") << "https://dav.example.com:8443/path" << "dav.example.com";
    QTest::newRow("no scheme") << "192.168.1.2:5005" << "192.168.1.2";
    QTest::newRow("bare host") << "nas" << "nas";
    QTest::newRow("with path") << "http://nas.local/dav/files" << "nas.local";
    QTest::newRow("empty") << "" << "";
}

void TestNetworkHeuristics::hostExtraction()
{
    QFETCH(QString, input);
    QFETCH(QString, host);
    QCOMPARE(NetworkHeuristics::hostOf(input), host);
}

void TestNetworkHeuristics::scopeMapping()
{
    QCOMPARE(NetworkHeuristics::scopeOf("http://192.168.1.1"), NetworkHeuristics::Internal);
    QCOMPARE(NetworkHeuristics::scopeOf("https://example.com"), NetworkHeuristics::External);
    QCOMPARE(NetworkHeuristics::scopeOf(""), NetworkHeuristics::Unknown);

    QCOMPARE(NetworkHeuristics::scopeName(NetworkHeuristics::Internal), QStringLiteral("internal"));
    QVERIFY(!NetworkHeuristics::scopeDisplayText(NetworkHeuristics::Internal).isEmpty());
}

QTEST_APPLESS_MAIN(TestNetworkHeuristics)
#include "tst_networkheuristics.moc"
