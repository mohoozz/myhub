// PlainTextDocument：纯文本阅读器的取文器（PC-210）
//
// 全部用内存 RangeSource，不依赖外部样本文件。重点验证三件事：
//   · 编码探测只读头块，整本沿用同一个编码（逐块检测会抖）
//   · 块切在换行符之后 —— 不丢行、不重行、不劈开多字节字符
//   · 懒加载：读到哪算哪，绝不整本读进内存

#include <QtTest>

#include "core/text/PlainTextDocument.h"
#include "core/text/TextCodec.h"

using namespace myhub;

namespace {

class MemoryRangeSource : public RangeSource
{
public:
    explicit MemoryRangeSource(QByteArray data, QObject *parent = nullptr)
        : RangeSource(parent)
        , m_data(std::move(data))
    {}

    qint64 size() const override { return m_data.size(); }

    void readRange(qint64 start, qint64 length, Callback cb) override
    {
        m_requests.append({start, length});
        if (start < 0 || length <= 0 || start >= m_data.size()) {
            cb(QByteArray(), StorageError(StorageError::InvalidPath, QStringLiteral("区间非法")));
            return;
        }
        cb(m_data.mid(static_cast<int>(start), static_cast<int>(length)), StorageError());
    }

    struct Request
    {
        qint64 start = 0;
        qint64 length = 0;
    };
    QList<Request> m_requests;

private:
    QByteArray m_data;
};

QString sampleNovelText()
{
    QString text;
    for (int i = 1; i <= 40; ++i) {
        text +=
            QStringLiteral("第 %1 行：雨停了，他把伞收起来，站在书店的屋檐下看街上的人来人往。\n")
                .arg(i);
    }
    return text;
}

/**
 * 把整本按块读完，拼接结果写进 out。
 *
 * `requireLineAligned` = 「每一块都必须以换行结尾」。这一条只在**行比块短**时成立；
 * 一行本身就比块长（压缩过的 json、单行日志）时只能在字符边界硬切，
 * 那种情况由调用方单独断言「不劈字符」。
 */
bool drain(PlainTextDocument &doc, QString *out, bool requireLineAligned)
{
    QString rebuilt;
    int guard = 0;
    bool ok = true;
    while (!doc.atEnd()) {
        QString piece;
        bool chunkOk = true;
        doc.readNext([&](const PlainTextDocument::Result &result) {
            chunkOk = result.ok();
            piece = result.text;
        });
        if (!chunkOk || piece.isEmpty()) {
            ok = false;
            break;
        }
        if (requireLineAligned && !piece.endsWith(QLatin1Char('\n'))) {
            ok = false;
            break;
        }
        rebuilt += piece;
        if (++guard > 10000) {
            ok = false; // 防死循环：真出错时让调用方的断言去报，不要卡住 ctest
            break;
        }
    }
    if (out) {
        *out = rebuilt;
    }
    return ok;
}

} // namespace

class TestPlainTextDocument : public QObject
{
    Q_OBJECT

private slots:
    void readsWholeFileInLineAlignedChunks();
    void keepsGb18030AcrossChunks();
    void neverSplitsMultibyteCharacter();
    void detectsUtf16AndFindsTwoByteNewline();
    void handlesEmptyFile();
    void readsLazily();
    void longLineWithoutNewlineStillAdvances();
    void reportsReadFailure();
};

void TestPlainTextDocument::readsWholeFileInLineAlignedChunks()
{
    const QString text = sampleNovelText();
    const QByteArray bytes = text.toUtf8();
    MemoryRangeSource source(bytes);

    PlainTextDocument doc(&source);
    doc.setChunkBytes(64); // 小到每行都会被切开：逼出「对齐到整行」的逻辑

    StorageError probeError;
    doc.probe(bytes.size(), [&](const StorageError &error) { probeError = error; });
    QVERIFY(probeError.isNull());
    QCOMPARE(doc.encoding(), TextCodec::Utf8);
    QCOMPARE(doc.fileSize(), qint64(bytes.size()));
    QVERIFY(!doc.atEnd());

    QString rebuilt;
    QVERIFY(drain(doc, &rebuilt, true));
    QCOMPARE(rebuilt, text);
    QVERIFY(doc.loadedCount() > 1);
    QVERIFY(doc.atEnd());
    QCOMPARE(doc.loadedBytes(), qint64(bytes.size()));

    // 再读一次：已到末尾，给空块而不是报错
    QString tail = QStringLiteral("未清空");
    StorageError tailError;
    doc.readNext([&](const PlainTextDocument::Result &result) {
        tail = result.text;
        tailError = result.error;
    });
    QVERIFY(tailError.isNull());
    QVERIFY(tail.isEmpty());
}

void TestPlainTextDocument::keepsGb18030AcrossChunks()
{
    // 逐块各自检测会抖：一屏里恰好没有汉字时 GB18030 / Big5 无法区分。
    // 整本只探一次编码，后面每块都按它解
    QString text;
    for (int i = 1; i <= 30; ++i) {
        text += QStringLiteral("第 %1 章 汉字编码测试行\n").arg(i);
    }
    const QByteArray bytes = TextCodec::encode(text, TextCodec::Gb18030).data;
    QVERIFY(!bytes.isEmpty());
    MemoryRangeSource source(bytes);

    PlainTextDocument doc(&source);
    doc.setChunkBytes(48);

    StorageError probeError;
    doc.probe(bytes.size(), [&](const StorageError &error) { probeError = error; });
    QVERIFY(probeError.isNull());
    QCOMPARE(doc.encoding(), TextCodec::Gb18030);
    QCOMPARE(doc.encodingName(), QStringLiteral("GB18030"));

    QString rebuilt;
    QVERIFY(drain(doc, &rebuilt, true));
    QCOMPARE(rebuilt, text);
}

void TestPlainTextDocument::neverSplitsMultibyteCharacter()
{
    const QString text = sampleNovelText();
    const QByteArray bytes = text.toUtf8();
    MemoryRangeSource source(bytes);

    PlainTextDocument doc(&source);
    doc.setChunkBytes(7); // 比一个汉字还小：不同整行切就必然出现 U+FFFD

    doc.probe(bytes.size(), [](const StorageError &) {});
    QString rebuilt;
    // 块比一行还小：允许在字符边界硬切，但绝不能出现 U+FFFD
    QVERIFY(drain(doc, &rebuilt, false));
    QCOMPARE(rebuilt, text);
    QVERIFY(!rebuilt.contains(QChar(0xFFFD)));
}

void TestPlainTextDocument::detectsUtf16AndFindsTwoByteNewline()
{
    // UTF-16 的 0x0A 会出现在汉字的字节里（U+4E0A 的 LE 编码就有），
    // 按单字节扫换行会把一行劈成两半
    QString text;
    for (int i = 1; i <= 20; ++i) {
        text += QStringLiteral("第 %1 行 上海上工人上门\n").arg(i);
    }
    const QByteArray bytes = TextCodec::encode(text, TextCodec::Utf16LE, true).data;
    MemoryRangeSource source(bytes);

    PlainTextDocument doc(&source);
    doc.setChunkBytes(24);

    StorageError probeError;
    doc.probe(bytes.size(), [&](const StorageError &error) { probeError = error; });
    QVERIFY(probeError.isNull());
    QCOMPARE(doc.encoding(), TextCodec::Utf16LE);

    QString rebuilt;
    QVERIFY(drain(doc, &rebuilt, true));
    QCOMPARE(rebuilt, text);
    QVERIFY(!rebuilt.contains(QChar(0xFFFD)));
}

void TestPlainTextDocument::handlesEmptyFile()
{
    MemoryRangeSource source{QByteArray()};
    PlainTextDocument doc(&source);

    StorageError probeError = StorageError(StorageError::Underlying, QStringLiteral("未调用"));
    doc.probe(0, [&](const StorageError &error) { probeError = error; });
    QVERIFY(probeError.isNull());
    QVERIFY(doc.atEnd());
    QCOMPARE(doc.loadedCount(), 0);
    QVERIFY(source.m_requests.isEmpty()); // 空文件连头块都不该读
}

void TestPlainTextDocument::readsLazily()
{
    // 1MB 假文件：只有真正读的时候才发请求，且每次请求不超过一块 + 对齐余量
    QByteArray bytes;
    bytes.reserve(qsizetype(1024) * 1024);
    for (int i = 0; i < 8192; ++i) {
        bytes += "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0"
                 "123456789abcdef0123456789abcdef0123456789abcdef\n";
    }
    MemoryRangeSource source(bytes);
    PlainTextDocument doc(&source);

    doc.probe(bytes.size(), [](const StorageError &) {});
    QCOMPARE(source.m_requests.size(), 1); // 只读了头块
    QCOMPARE(source.m_requests.first().start, qint64(0));
    QVERIFY(source.m_requests.first().length <= qint64(64) * 1024);

    source.m_requests.clear();
    doc.readNext([](const PlainTextDocument::Result &) {});
    QCOMPARE(source.m_requests.size(), 1);
    const MemoryRangeSource::Request request = source.m_requests.first();
    QCOMPARE(request.start, qint64(0));
    // 一块 64KB + 对齐余量，绝不整本读进来
    QVERIFY(request.length < qint64(200) * 1024);
    QVERIFY(request.length < bytes.size());

    // 连读两块：第二块从第一块终点开始，不重叠
    doc.readNext([](const PlainTextDocument::Result &) {});
    QCOMPARE(source.m_requests.size(), 2);
    QVERIFY(source.m_requests.at(1).start > 0);
    QVERIFY(source.m_requests.at(1).start < bytes.size());
    QVERIFY(!doc.atEnd());
}

void TestPlainTextDocument::longLineWithoutNewlineStillAdvances()
{
    // 一行就是一整本（压缩过的 json、单行日志）：窗口里找不到换行，也必须推进，
    // 否则 readNext 会原地打转
    QByteArray bytes(qsizetype(200) * 1024, 'a');
    MemoryRangeSource source(bytes);

    PlainTextDocument doc(&source);
    doc.setChunkBytes(1024);
    doc.probe(bytes.size(), [](const StorageError &) {});

    qint64 previous = 0;
    for (int i = 0; i < 5; ++i) {
        doc.readNext([](const PlainTextDocument::Result &) {});
        QVERIFY(doc.loadedBytes() > previous);
        previous = doc.loadedBytes();
    }
    QVERIFY(doc.loadedCount() >= 5);
}

void TestPlainTextDocument::reportsReadFailure()
{
    // stat 说有内容，实际读不到：错误要原样传出去，不能默默返回空块
    MemoryRangeSource source{QByteArray()};
    PlainTextDocument doc(&source);

    StorageError probeError;
    doc.probe(4096, [&](const StorageError &error) { probeError = error; });
    QVERIFY(!probeError.isNull());

    // 探测失败后 readNext 应拒绝，而不是拿 Unknown 编码硬解
    StorageError readError;
    doc.readNext([&](const PlainTextDocument::Result &result) { readError = result.error; });
    QVERIFY(!readError.isNull());
}

QTEST_MAIN(TestPlainTextDocument)

#include "tst_plaintextdocument.moc"
