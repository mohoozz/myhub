// TextCodec：编码检测与「沿用原编码、不可表示回退 UTF-8」的纪律（PC-103 / PC-108）
#include "core/text/TextCodec.h"

#include <QStringEncoder>
#include <QtTest>

using myhub::TextCodec;

class TestTextCodec : public QObject
{
    Q_OBJECT

private slots:
    void emptyIsUtf8();
    void asciiIsUtf8();
    void utf8BomKeepFlag();
    void utf16Boms();
    void utf16WithoutBomByZeroHeuristic();
    void gb18030RoundTrip();
    void big5RoundTrip();
    void encodeFallsBackToUtf8WhenUnrepresentable();
    void encodeKeepsEncodingWhenRepresentable();
    void nameRoundTrip();
    void brokenUtf8DoesNotThrow();
};

// GB18030（GBK）里「中文测试，一二三。」的字节，用于不依赖平台 API 的固定样本
static QByteArray gbSample()
{
    return QByteArray::fromHex("D6D0CEC4B2E2CAD4A3ACD2BBB6FEC8FDA1A3");
}

static QByteArray big5Sample()
{
    // Big5：中文測試，一二三。 —— 传统字形，含低位 0x40-0x7E 的常见字
    return QByteArray::fromHex("A4A4A4E5B4FAB8D5A1A3A440A447A454A1A3");
}

void TestTextCodec::emptyIsUtf8()
{
    const auto decoded = TextCodec::decode(QByteArray());
    QCOMPARE(decoded.encoding, TextCodec::Utf8);
    QVERIFY(decoded.text.isEmpty());
    QVERIFY(!decoded.hadErrors);
}

void TestTextCodec::asciiIsUtf8()
{
    const auto decoded = TextCodec::decode(QByteArrayLiteral("hello world\n"));
    QCOMPARE(decoded.encoding, TextCodec::Utf8);
    QCOMPARE(decoded.text, QStringLiteral("hello world\n"));
}

void TestTextCodec::utf8BomKeepFlag()
{
    const QByteArray data = QByteArray::fromHex("EFBBBF") + QStringLiteral("第 1 章").toUtf8();
    const auto decoded = TextCodec::decode(data);
    QCOMPARE(decoded.encoding, TextCodec::Utf8);
    QVERIFY(decoded.hadBom);
    QCOMPARE(decoded.text, QStringLiteral("第 1 章"));
    QVERIFY(!decoded.hadErrors);

    // 回写时保留 BOM
    const auto encoded = TextCodec::encode(decoded.text, decoded.encoding, decoded.hadBom);
    QCOMPARE(encoded.data, data);
    QVERIFY(!encoded.fellBackToUtf8);
}

void TestTextCodec::utf16Boms()
{
    const QString text = QStringLiteral("第一章 起点");
    for (bool little : {true, false}) {
        const auto *codec = little ? "UTF-16LE" : "UTF-16BE";
        QStringEncoder encoder(codec);
        const QByteArray bom = QByteArray::fromHex(little ? "FFFE" : "FEFF");
        const auto decoded = TextCodec::decode(bom + encoder(text));
        QCOMPARE(decoded.encoding, little ? TextCodec::Utf16LE : TextCodec::Utf16BE);
        QCOMPARE(decoded.text, text);
        QVERIFY(decoded.hadBom);
        QVERIFY(!decoded.hadErrors);
    }
}

void TestTextCodec::utf16WithoutBomByZeroHeuristic()
{
    const QString text = QStringLiteral("chapter one");
    QStringEncoder encoder("UTF-16LE");
    const auto decoded = TextCodec::decode(encoder(text));
    QCOMPARE(decoded.encoding, TextCodec::Utf16LE);
    QCOMPARE(decoded.text, text);
    QVERIFY(!decoded.hadBom);
}

void TestTextCodec::gb18030RoundTrip()
{
    const auto decoded = TextCodec::decode(gbSample());
    QCOMPARE(decoded.encoding, TextCodec::Gb18030);
    QCOMPARE(decoded.text, QStringLiteral("中文测试，一二三。"));
    QVERIFY(!decoded.hadErrors);

    const auto encoded = TextCodec::encode(decoded.text, decoded.encoding, decoded.hadBom);
    QCOMPARE(encoded.encoding, TextCodec::Gb18030);
    QVERIFY(!encoded.fellBackToUtf8);
    QCOMPARE(encoded.data, gbSample());
}

void TestTextCodec::big5RoundTrip()
{
    const auto decoded = TextCodec::decode(big5Sample());
    QCOMPARE(decoded.encoding, TextCodec::Big5);
    QVERIFY(!decoded.hadErrors);

    const auto encoded = TextCodec::encode(decoded.text, decoded.encoding, decoded.hadBom);
    QCOMPARE(encoded.encoding, TextCodec::Big5);
    QVERIFY(!encoded.fellBackToUtf8);
    QCOMPARE(encoded.data, big5Sample());
}

void TestTextCodec::encodeFallsBackToUtf8WhenUnrepresentable()
{
    // 「发」为简体字形，Big5 无对应码位（GB18030 覆盖全 UCS，不会触发回退）：
    // 必须回退 UTF-8，不能写问号、不能静默丢字
    const QString text = QStringLiteral("你好 发");
    QVERIFY(!TextCodec::canEncode(text, TextCodec::Big5));
    const auto encoded = TextCodec::encode(text, TextCodec::Big5, false);
    QVERIFY(encoded.fellBackToUtf8);
    QCOMPARE(encoded.encoding, TextCodec::Utf8);
    QCOMPARE(encoded.data, text.toUtf8());
    QCOMPARE(QString::fromUtf8(encoded.data), text);
}

void TestTextCodec::encodeKeepsEncodingWhenRepresentable()
{
    const QString text = QStringLiteral("第一章 山村");
    QVERIFY(TextCodec::canEncode(text, TextCodec::Gb18030));
    const auto encoded = TextCodec::encode(text, TextCodec::Gb18030, false);
    QVERIFY(!encoded.fellBackToUtf8);
    QCOMPARE(encoded.encoding, TextCodec::Gb18030);
    QCOMPARE(TextCodec::decode(encoded.data).text, text);
}

void TestTextCodec::nameRoundTrip()
{
    const TextCodec::Encoding all[] = {TextCodec::Utf8, TextCodec::Utf16LE, TextCodec::Utf16BE,
                                       TextCodec::Gb18030, TextCodec::Big5};
    for (auto encoding : all) {
        QCOMPARE(TextCodec::fromName(TextCodec::name(encoding)), encoding);
    }
    QCOMPARE(TextCodec::fromName(QStringLiteral("gbk")), TextCodec::Gb18030);
    QCOMPARE(TextCodec::fromName(QStringLiteral("unknown-cp")), TextCodec::Unknown);
    QCOMPARE(TextCodec::name(TextCodec::Unknown), QStringLiteral("UTF-8"));
}

void TestTextCodec::brokenUtf8DoesNotThrow()
{
    // 随机高位字节：不崩溃、必定给出可展示文本，且标记 hadErrors
    QByteArray junk = QByteArray::fromHex("80FFFE81FDFE8180");
    const auto decoded = TextCodec::decode(junk);
    QVERIFY(!decoded.text.isEmpty());
    QVERIFY(decoded.hadErrors);
}

QTEST_MAIN(TestTextCodec)
#include "tst_textcodec.moc"
