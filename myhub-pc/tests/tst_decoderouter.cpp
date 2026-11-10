// 解码路由单测（《需求分析文档》§4.3「双引擎解码策略」）
//
// 覆盖三档决策：偏好强制 > 已知无硬解容器 > 默认硬解优先（auto-safe）。
// 同时验证「本地魔数优先于扩展名」——扩展名骗人（或没有扩展名）时仍能判对容器。

#include <QTemporaryDir>
#include <QtTest>

#include "core/player/DecodeRouter.h"

using namespace myhub;

namespace {

/// 写一个只含指定魔数前缀的假媒体文件
QString writeFake(const QString &dir, const QString &name, const QByteArray &head)
{
    QString path = dir + QLatin1Char('/') + name;
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly))
        return {};
    // 补齐到探测窗口长度，模拟真实文件的长度分布
    QByteArray payload = head;
    payload.append(QByteArray(200 - head.size(), '\0'));
    file.write(payload);
    file.close();
    return path;
}

QByteArray matroskaHead()
{
    return QByteArray::fromHex("1a45dfa3a34286810142f7810142f2810442f3810842f581");
}

} // namespace

class TestDecodeRouter : public QObject
{
    Q_OBJECT

private slots:
    void preferenceOverridesEverything();
    void suffixRoutesToSoftware();
    void suffixRoutesToHardware();
    void magicBeatsMisleadingSuffix();
    void magicDetectsMpegTs();
    void remoteSourceUsesSuffixOnly();
    void unknownFallsBackToAutoSafe();
};

void TestDecodeRouter::preferenceOverridesEverything()
{
    // 强制软解：即便容器/扩展名支持硬解也必须 hwdec=no，且标记为强制
    const DecodeDecision soft =
        DecodeRouter::decide(QStringLiteral("software"), QStringLiteral("/media/a.mp4"));
    QCOMPARE(soft.hwdec, QStringLiteral("no"));
    QVERIFY(soft.forced);
    QCOMPARE(soft.reason, QStringLiteral("preference:software"));

    // 强制硬解：即便容器在软解名单里也要用硬解
    const DecodeDecision hard =
        DecodeRouter::decide(QStringLiteral("hardware"), QStringLiteral("/media/a.rmvb"));
    QCOMPARE(hard.hwdec, QStringLiteral("auto"));
    QVERIFY(hard.forced);
    QCOMPARE(hard.reason, QStringLiteral("preference:hardware"));
}

void TestDecodeRouter::suffixRoutesToSoftware()
{
    for (const QString &suffix : DecodeRouter::softwareOnlySuffixes()) {
        const QString path = QStringLiteral("/media/movie.") + suffix;
        const DecodeDecision decision = DecodeRouter::decide(QStringLiteral("auto"), path);
        QCOMPARE(decision.hwdec, QStringLiteral("no"));
        QVERIFY2(!decision.forced, qPrintable(suffix)); // 非强制：运行期仍可被回退逻辑改判
        QVERIFY2(decision.reason.startsWith(QStringLiteral("container:")), qPrintable(suffix));
    }
}

void TestDecodeRouter::suffixRoutesToHardware()
{
    const QStringList autoSuffixes{QStringLiteral("mp4"),  QStringLiteral("mkv"),
                                   QStringLiteral("webm"), QStringLiteral("ts"),
                                   QStringLiteral("m2ts"), QStringLiteral("mov")};
    for (const QString &suffix : autoSuffixes) {
        const DecodeDecision decision =
            DecodeRouter::decide(QStringLiteral("auto"), QStringLiteral("/media/movie.") + suffix);
        QCOMPARE(decision.hwdec, QStringLiteral("auto-safe"));
        QCOMPARE(decision.reason, QStringLiteral("auto"));
    }

    // 大小写不敏感
    QCOMPARE(DecodeRouter::probe(QStringLiteral("/media/MOVIE.MKV")), MediaContainer::Matroska);
    QCOMPARE(DecodeRouter::probe(QStringLiteral("/media/MOVIE.RMVB")), MediaContainer::RealMedia);
}

void TestDecodeRouter::magicBeatsMisleadingSuffix()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());

    // 内容其实是 mkv，扩展名却是 mp4：应以魔数为准（硬解可用）
    const QString mkAsMp4 = writeFake(dir.path(), QStringLiteral("real-mkv.mp4"), matroskaHead());
    QVERIFY(!mkAsMp4.isEmpty());
    QCOMPARE(DecodeRouter::probe(mkAsMp4), MediaContainer::Matroska);
    QCOMPARE(DecodeRouter::decide(QStringLiteral("auto"), mkAsMp4).hwdec,
             QStringLiteral("auto-safe"));

    // 内容其实是 avi（RIFF....AVI ），扩展名却是 mp4：应判为软解
    QByteArray avi = QByteArrayLiteral("RIFF");
    avi.append(QByteArray::fromHex("40260b00"));
    avi.append(QByteArrayLiteral("AVI "));
    const QString aviAsMp4 = writeFake(dir.path(), QStringLiteral("real-avi.mp4"), avi);
    QVERIFY(!aviAsMp4.isEmpty());
    QCOMPARE(DecodeRouter::probe(aviAsMp4), MediaContainer::Avi);
    QCOMPARE(DecodeRouter::decide(QStringLiteral("auto"), aviAsMp4).hwdec, QStringLiteral("no"));
}

void TestDecodeRouter::magicDetectsMpegTs()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());

    // 无扩展名的 ts：第 0 与第 188 字节都是同步字节 0x47
    QByteArray head(200, '\0');
    head[0] = 0x47;
    head[188] = 0x47;
    const QString path = writeFake(dir.path(), QStringLiteral("recording"), head);
    QVERIFY(!path.isEmpty());
    QCOMPARE(DecodeRouter::probe(path), MediaContainer::MpegTs);
    // ts 允许硬解（广播/录播多为 H.264+AAC）
    QCOMPARE(DecodeRouter::decide(QStringLiteral("auto"), path).hwdec, QStringLiteral("auto-safe"));
}

void TestDecodeRouter::remoteSourceUsesSuffixOnly()
{
    // 回环代理 / WebDAV：不探测网络内容，只按扩展名（避免额外请求与超时）
    const DecodeDecision viaProxy = DecodeRouter::decide(
        QStringLiteral("auto"),
        QStringLiteral("http://127.0.0.1:51234/stream/7/电影.rmvb?token=abc.def"));
    QCOMPARE(viaProxy.hwdec, QStringLiteral("no"));
    QCOMPARE(viaProxy.reason, QStringLiteral("container:realmedia"));

    // 查询串里的点不能影响扩展名解析
    const DecodeDecision withQuery = DecodeRouter::decide(
        QStringLiteral("auto"), QStringLiteral("http://127.0.0.1:51234/stream/7/a.mkv?v=1.2"));
    QCOMPARE(withQuery.hwdec, QStringLiteral("auto-safe"));
}

void TestDecodeRouter::unknownFallsBackToAutoSafe()
{
    const DecodeDecision noSuffix =
        DecodeRouter::decide(QStringLiteral("auto"), QStringLiteral("/media/mystery"));
    QCOMPARE(noSuffix.hwdec, QStringLiteral("auto-safe"));
    QCOMPARE(noSuffix.reason, QStringLiteral("auto"));
    QVERIFY(!noSuffix.forced);

    // 偏好为空（老版本没写过该键）等同 auto
    QCOMPARE(DecodeRouter::decide(QString(), QStringLiteral("/media/a.mkv")).hwdec,
             QStringLiteral("auto-safe"));
}

QTEST_GUILESS_MAIN(TestDecodeRouter)
#include "tst_decoderouter.moc"
