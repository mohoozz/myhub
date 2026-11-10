// 内嵌封面提取单测（PC-702）
//
// 覆盖三种容器的正常路径与「没有封面 / 数据不像图片」的拒绝路径。
// 全部用合成字节构造，不依赖磁盘上的真实媒体文件。

#include <QtTest>

#include "core/cover/EmbeddedCoverExtractor.h"

using namespace myhub;

namespace {

QByteArray be32(quint32 value)
{
    QByteArray out(4, '\0');
    out[0] = static_cast<char>((value >> 24) & 0xff);
    out[1] = static_cast<char>((value >> 16) & 0xff);
    out[2] = static_cast<char>((value >> 8) & 0xff);
    out[3] = static_cast<char>(value & 0xff);
    return out;
}

QByteArray syncSafe(quint32 value)
{
    QByteArray out(4, '\0');
    out[0] = static_cast<char>((value >> 21) & 0x7f);
    out[1] = static_cast<char>((value >> 14) & 0x7f);
    out[2] = static_cast<char>((value >> 7) & 0x7f);
    out[3] = static_cast<char>(value & 0x7f);
    return out;
}

/// MP4 盒子：4 字节长度 + 4 字节类型 + 内容
QByteArray box(const char *type, const QByteArray &content)
{
    return be32(static_cast<quint32>(content.size() + 8)) + QByteArray(type) + content;
}

const QByteArray &jpegBytes()
{
    static const QByteArray data = QByteArray::fromHex("ffd8ffe000104a464946") + "jpeg-payload";
    return data;
}

const QByteArray &pngBytes()
{
    static const QByteArray data = QByteArray::fromHex("89504e470d0a1a0a") + "png-payload";
    return data;
}

/// ID3v2 的 APIC 帧体（encoding=latin1 + image/jpeg + front cover + 空描述）
QByteArray apicBody(const QByteArray &image)
{
    QByteArray body;
    body.append('\0');
    body.append("image/jpeg");
    body.append('\0');
    body.append(char(3));
    body.append('\0');
    body.append(image);
    return body;
}

/// ID3v2.2 的 PIC 帧体：encoding + 3 字节图像格式 + 图片类型 + 空描述 + 图片
QByteArray picBodyV22(const QByteArray &image)
{
    QByteArray body;
    body.append('\0');
    body.append("JPG");
    body.append(char(3));
    body.append('\0');
    body.append(image);
    return body;
}

QByteArray id3Tag(int version, const QByteArray &frames)
{
    QByteArray tag = "ID3";
    tag.append(char(version));
    tag.append('\0');
    tag.append('\0'); // flags
    tag.append(syncSafe(static_cast<quint32>(frames.size())));
    tag.append(frames);
    return tag;
}

QByteArray id3Frame(int version, const QByteArray &body)
{
    const QByteArray &image = body;
    if (version == 2) {
        QByteArray frame = "PIC";
        const quint32 size = static_cast<quint32>(image.size());
        frame.append(char((size >> 16) & 0xff));
        frame.append(char((size >> 8) & 0xff));
        frame.append(char(size & 0xff));
        frame.append(image);
        return frame;
    }
    QByteArray frame = "APIC";
    frame.append(version == 4 ? syncSafe(static_cast<quint32>(image.size()))
                              : be32(static_cast<quint32>(image.size())));
    frame.append('\0');
    frame.append('\0');
    frame.append(image);
    return frame;
}

/// MP4：moov.udta.meta.ilst.covr.data
QByteArray mp4Moov(const QByteArray &image)
{
    const QByteArray dataBox = box("data", be32(13) + be32(0) + image);
    return box("moov",
               box("udta", box("meta", QByteArray(4, '\0') + box("ilst", box("covr", dataBox)))));
}

} // namespace

class TestEmbeddedCover : public QObject
{
    Q_OBJECT

private slots:
    void readRangeHints();

    void id3v22Pic();
    void id3v23Apic();
    void id3v24Apic();
    void id3WithoutPictureFrame();
    void id3RejectsNonImagePayload();

    void flacPicture();
    void flacWithoutPicture();

    void mp4CovrInHead();
    void mp4CovrInTail();
    void mp4WithoutCovr();

    void unsupportedExtension();
};

void TestEmbeddedCover::readRangeHints()
{
    constexpr qint64 bigFile = 10LL * 1024 * 1024;
    QCOMPARE(EmbeddedCoverExtractor::headLength(1024), qint64(1024));
    QCOMPARE(EmbeddedCoverExtractor::headLength(bigFile), EmbeddedCoverExtractor::kHeadBytes);
    QCOMPARE(EmbeddedCoverExtractor::tailOffset(1024), qint64(0));
    QCOMPARE(EmbeddedCoverExtractor::tailOffset(bigFile),
             bigFile - EmbeddedCoverExtractor::kTailBytes);
}

void TestEmbeddedCover::id3v22Pic()
{
    const QByteArray tag = id3Tag(2, id3Frame(2, picBodyV22(jpegBytes())));
    QCOMPARE(EmbeddedCoverExtractor::extract("mp3", tag.size(), tag), jpegBytes());
}

void TestEmbeddedCover::id3v23Apic()
{
    const QByteArray tag = id3Tag(3, id3Frame(3, apicBody(jpegBytes())));
    QCOMPARE(EmbeddedCoverExtractor::extract("mp3", tag.size(), tag), jpegBytes());
}

void TestEmbeddedCover::id3v24Apic()
{
    const QByteArray tag = id3Tag(4, id3Frame(4, apicBody(pngBytes())));
    QCOMPARE(EmbeddedCoverExtractor::extract("mp3", tag.size(), tag), pngBytes());
}

void TestEmbeddedCover::id3WithoutPictureFrame()
{
    QByteArray titleFrame = "TIT2";
    titleFrame.append(be32(6));
    titleFrame.append('\0');
    titleFrame.append('\0');
    titleFrame.append('\0');
    titleFrame.append("demo");
    const QByteArray tag = id3Tag(3, titleFrame);
    QVERIFY(EmbeddedCoverExtractor::extract("mp3", tag.size(), tag).isEmpty());
}

void TestEmbeddedCover::id3RejectsNonImagePayload()
{
    const QByteArray tag = id3Tag(3, id3Frame(3, apicBody("not-an-image")));
    QVERIFY(EmbeddedCoverExtractor::extract("mp3", tag.size(), tag).isEmpty());
}

void TestEmbeddedCover::flacPicture()
{
    QByteArray body;
    body.append(be32(3)); // front cover
    body.append(be32(9)); // "image/png"
    body.append("image/png");
    body.append(be32(0)); // 描述长度
    body.append(be32(0)); // width
    body.append(be32(0)); // height
    body.append(be32(0)); // depth
    body.append(be32(0)); // colors
    body.append(be32(static_cast<quint32>(pngBytes().size())));
    body.append(pngBytes());

    QByteArray block;
    block.append(char(0x80 | 6)); // 最后一个块 + PICTURE
    const quint32 len = static_cast<quint32>(body.size());
    block.append(char((len >> 16) & 0xff));
    block.append(char((len >> 8) & 0xff));
    block.append(char(len & 0xff));
    block.append(body);

    const QByteArray flac = QByteArray("fLaC") + block;
    QCOMPARE(EmbeddedCoverExtractor::extract("flac", flac.size(), flac), pngBytes());
}

void TestEmbeddedCover::flacWithoutPicture()
{
    QByteArray block;
    block.append(char(0x80 | 0)); // 最后一个块 + STREAMINFO
    block.append('\0');
    block.append('\0');
    block.append(char(34));
    block.append(QByteArray(34, '\0'));

    const QByteArray flac = QByteArray("fLaC") + block;
    QVERIFY(EmbeddedCoverExtractor::extract("flac", flac.size(), flac).isEmpty());
}

void TestEmbeddedCover::mp4CovrInHead()
{
    const QByteArray file =
        box("ftyp", "isom0000") + mp4Moov(jpegBytes()) + box("mdat", QByteArray(64, 'x'));
    QCOMPARE(EmbeddedCoverExtractor::extract("mp4", file.size(), file), jpegBytes());
}

void TestEmbeddedCover::mp4CovrInTail()
{
    const QByteArray moov = mp4Moov(jpegBytes());
    const QByteArray file = box("ftyp", "isom0000") + box("mdat", QByteArray(4096, 'x')) + moov;

    // 头部片段里 moov 被 mdat 挡在后面；尾部片段正好是 moov
    const QByteArray head = file.left(1024);
    QCOMPARE(EmbeddedCoverExtractor::extract("m4a", file.size(), head, moov), jpegBytes());
}

void TestEmbeddedCover::mp4WithoutCovr()
{
    const QByteArray moov =
        box("moov",
            box("udta",
                box("meta",
                    QByteArray(4, '\0')
                        + box("ilst", box("trkn", box("data", be32(0) + be32(0) + "x"))))));
    const QByteArray file = box("ftyp", "isom0000") + moov;
    QVERIFY(EmbeddedCoverExtractor::extract("mp4", file.size(), file).isEmpty());
}

void TestEmbeddedCover::unsupportedExtension()
{
    QVERIFY(!EmbeddedCoverExtractor::supports(QStringLiteral("mkv")));
    QVERIFY(!EmbeddedCoverExtractor::supports(QStringLiteral("epub")));
    QVERIFY(EmbeddedCoverExtractor::supports(QStringLiteral("flac")));
    const QByteArray tag = id3Tag(3, id3Frame(3, apicBody(jpegBytes())));
    QVERIFY(EmbeddedCoverExtractor::extract("mkv", tag.size(), tag).isEmpty());
}

QTEST_MAIN(TestEmbeddedCover)
#include "tst_embeddedcover.moc"
