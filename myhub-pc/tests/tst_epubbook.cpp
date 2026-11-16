// EpubBook：container → OPF → NAV/NCX → 章节段落（§5.1 PC-205）
//
// 全部用内存 RangeSource + 现场拼出来的 epub，不依赖外部样本文件。

#include <QtTest>

#include <zlib.h>

#include "core/novel/EpubBook.h"

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
        if (start < 0 || length <= 0 || start >= m_data.size()) {
            cb(QByteArray(), StorageError(StorageError::InvalidPath, QStringLiteral("区间非法")));
            return;
        }
        cb(m_data.mid(static_cast<int>(start), static_cast<int>(length)), StorageError());
    }

private:
    QByteArray m_data;
};

void putU16(QByteArray &out, quint16 value)
{
    out.append(static_cast<char>(value & 0xFF));
    out.append(static_cast<char>((value >> 8) & 0xFF));
}

void putU32(QByteArray &out, quint32 value)
{
    for (int i = 0; i < 4; ++i) {
        out.append(static_cast<char>((value >> (8 * i)) & 0xFF));
    }
}

quint32 crcOf(const QByteArray &data)
{
    return static_cast<quint32>(crc32(crc32(0L, Z_NULL, 0),
                                      reinterpret_cast<const Bytef *>(data.constData()),
                                      static_cast<uInt>(data.size())));
}

/// 只写 stored 条目的最小 zip：epub 测试不关心压缩，先保证结构正确
QByteArray buildZip(const QVector<QPair<QString, QByteArray>> &files)
{
    QByteArray out;
    QByteArray central;

    for (const auto &file : files) {
        const QByteArray name = file.first.toUtf8();
        const QByteArray &data = file.second;
        const quint32 crc = crcOf(data);
        const qint64 offset = out.size();

        putU32(out, 0x04034b50);
        putU16(out, 20);
        putU16(out, 0);
        putU16(out, 0); // stored
        putU16(out, 0);
        putU16(out, 0);
        putU32(out, crc);
        putU32(out, static_cast<quint32>(data.size()));
        putU32(out, static_cast<quint32>(data.size()));
        putU16(out, static_cast<quint16>(name.size()));
        putU16(out, 0);
        out.append(name);
        out.append(data);

        putU32(central, 0x02014b50);
        putU16(central, 20);
        putU16(central, 20);
        putU16(central, 0);
        putU16(central, 0);
        putU16(central, 0);
        putU16(central, 0);
        putU32(central, crc);
        putU32(central, static_cast<quint32>(data.size()));
        putU32(central, static_cast<quint32>(data.size()));
        putU16(central, static_cast<quint16>(name.size()));
        putU16(central, 0);
        putU16(central, 0);
        putU16(central, 0);
        putU16(central, 0);
        putU32(central, 0);
        putU32(central, static_cast<quint32>(offset));
        central.append(name);
    }

    const qint64 cdOffset = out.size();
    const qint64 cdSize = central.size();
    out.append(central);

    putU32(out, 0x06054b50);
    putU16(out, 0);
    putU16(out, 0);
    putU16(out, static_cast<quint16>(files.size()));
    putU16(out, static_cast<quint16>(files.size()));
    putU32(out, static_cast<quint32>(cdSize));
    putU32(out, static_cast<quint32>(cdOffset));
    putU16(out, 0);
    return out;
}

// 样本一律用普通字符串字面量：moc 的 lexer 遇到 raw string 会走偏，
// 整个文件被当成「无相关类」，moc 产物为空就会在链接期报 metaObject 未定义
const QByteArray kContainerXml = QByteArrayLiteral(
    "<?xml version='1.0' encoding='utf-8'?>"
    "<container version='1.0' xmlns='urn:oasis:names:tc:opendocument:xmlns:container'>"
    "<rootfiles>"
    "<rootfile full-path='OEBPS/content.opf' "
    "media-type='application/oebps-package+xml'/>"
    "</rootfiles></container>");

const QByteArray kEpub3Opf = QByteArrayLiteral(
    "<?xml version='1.0' encoding='utf-8'?>"
    "<package xmlns='http://www.idpf.org/2007/opf' version='3.0' unique-identifier='uid'>"
    "<metadata xmlns:dc='http://purl.org/dc/elements/1.1/'>"
    "<dc:title>测试之书</dc:title><dc:creator>某作者</dc:creator>"
    "<dc:language>zh-CN</dc:language></metadata>"
    "<manifest>"
    "<item id='nav' href='nav.xhtml' media-type='application/xhtml+xml' properties='nav'/>"
    "<item id='ch1' href='text/ch1.xhtml' media-type='application/xhtml+xml'/>"
    "<item id='ch2' href='text/ch2.xhtml' media-type='application/xhtml+xml'/>"
    "</manifest>"
    "<spine><itemref idref='ch1'/><itemref idref='ch2'/></spine>"
    "</package>");

const QByteArray kEpub3Nav = QByteArrayLiteral(
    "<?xml version='1.0' encoding='utf-8'?>"
    "<html xmlns='http://www.w3.org/1999/xhtml' xmlns:epub='http://www.idpf.org/2007/ops'>"
    "<head><title>目录</title></head><body>"
    "<nav epub:type='toc' id='toc'><ol>"
    "<li><a href='text/ch1.xhtml'>第一章 起风了</a></li>"
    "<li><a href='text/ch2.xhtml#sec2'>第二章 雨停了</a></li>"
    "</ol></nav></body></html>");

const QByteArray kChapter1 =
    QByteArrayLiteral("<?xml version='1.0' encoding='utf-8'?>"
                      "<html xmlns='http://www.w3.org/1999/xhtml'>"
                      "<head><title>第一章</title><style>p{color:red}</style>"
                      "<script>var x=1;</script></head>"
                      "<body><h1>第一章 起风了</h1>"
                      "<p>第一段&nbsp;正文</p>"
                      "<p>第二段 &amp; 有 <em>强调</em> 文字<br/>换行后的第三段</p>"
                      "</body></html>");

const QByteArray kChapter2 = QByteArrayLiteral(
    "<?xml version='1.0' encoding='utf-8'?>"
    "<html xmlns='http://www.w3.org/1999/xhtml'><body><p>第二章正文</p></body></html>");

QByteArray epub3()
{
    return buildZip({
        {QStringLiteral("mimetype"), QByteArray("application/epub+zip")},
        {QStringLiteral("META-INF/container.xml"), kContainerXml},
        {QStringLiteral("OEBPS/content.opf"), kEpub3Opf},
        {QStringLiteral("OEBPS/nav.xhtml"), kEpub3Nav},
        {QStringLiteral("OEBPS/text/ch1.xhtml"), kChapter1},
        {QStringLiteral("OEBPS/text/ch2.xhtml"), kChapter2},
    });
}

EpubMetadata loadOf(EpubBook &book, StorageError *error = nullptr)
{
    EpubMetadata metadata;
    StorageError captured;
    book.load([&metadata, &captured](EpubMetadata meta, StorageError err) {
        metadata = std::move(meta);
        captured = err;
    });
    if (error) {
        *error = captured;
    }
    return metadata;
}

} // namespace

class TestEpubBook : public QObject
{
    Q_OBJECT

private slots:
    void loadsEpub3NavToc();
    void appliesNavRelativeToNavFile();
    void fallsBackToNcx();
    void fallsBackToSpineWithoutToc();
    void rejectsBrokenPackage();
    void parsesEpub3CoverImage();
    void parsesEpub2CoverMeta();
    void reportsMissingCover();
    void resolveHrefHandlesDotsAndEncoding();
    void htmlToParagraphsStripsMarkup();
};

void TestEpubBook::loadsEpub3NavToc()
{
    MemoryRangeSource source(epub3());
    EpubBook book(&source);

    StorageError error;
    const EpubMetadata metadata = loadOf(book, &error);

    QVERIFY2(error.isNull(), qPrintable(error.message()));
    QCOMPARE(metadata.title, QStringLiteral("测试之书"));
    QCOMPARE(metadata.author, QStringLiteral("某作者"));
    QCOMPARE(metadata.language, QStringLiteral("zh-CN"));
    QCOMPARE(metadata.chapters.size(), 2);
    QCOMPARE(metadata.chapters.at(0).title, QStringLiteral("第一章 起风了"));
    QCOMPARE(metadata.chapters.at(1).title, QStringLiteral("第二章 雨停了"));
    QCOMPARE(metadata.chapters.at(0).href, QStringLiteral("OEBPS/text/ch1.xhtml"));

    // 章内段落：标题行单独成段，style/script 不进正文，实体已解码，<br/> 断段
    QStringList paragraphs;
    book.readChapter(0, [&paragraphs](QStringList list, StorageError) { paragraphs = list; });
    QCOMPARE(paragraphs.size(), 4);
    QCOMPARE(paragraphs.at(0), QStringLiteral("第一章 起风了"));
    QCOMPARE(paragraphs.at(1), QStringLiteral("第一段 正文"));
    QCOMPARE(paragraphs.at(2), QStringLiteral("第二段 & 有 强调 文字"));
    QCOMPARE(paragraphs.at(3), QStringLiteral("换行后的第三段"));
    QVERIFY(!paragraphs.join(QString()).contains(QStringLiteral("color:red")));

    QStringList second;
    book.readChapter(1, [&second](QStringList list, StorageError) { second = list; });
    QCOMPARE(second, QStringList{QStringLiteral("第二章正文")});
}

void TestEpubBook::appliesNavRelativeToNavFile()
{
    // nav 放在 OEBPS/nav/ 下，href 相对它自己是 ../text/ch1.xhtml
    QByteArray opf = kEpub3Opf;
    opf.replace("href='nav.xhtml'", "href='nav/nav.xhtml'");
    const QByteArray nav = QByteArrayLiteral(
        "<html xmlns='http://www.w3.org/1999/xhtml' xmlns:epub='http://www.idpf.org/2007/ops'>"
        "<body><nav epub:type='toc'><ol>"
        "<li><a href='../text/ch1.xhtml'>目录里的第一章</a></li>"
        "</ol></nav></body></html>");

    MemoryRangeSource source(buildZip({
        {QStringLiteral("META-INF/container.xml"), kContainerXml},
        {QStringLiteral("OEBPS/content.opf"), opf},
        {QStringLiteral("OEBPS/nav/nav.xhtml"), nav},
        {QStringLiteral("OEBPS/text/ch1.xhtml"), kChapter1},
        {QStringLiteral("OEBPS/text/ch2.xhtml"), kChapter2},
    }));
    EpubBook book(&source);

    const EpubMetadata metadata = loadOf(book);
    QCOMPARE(metadata.chapters.size(), 2);
    QCOMPARE(metadata.chapters.at(0).title, QStringLiteral("目录里的第一章"));
    // spine 里没有目录的项就用文件名兜底
    QCOMPARE(metadata.chapters.at(1).title, QStringLiteral("ch2"));
}

void TestEpubBook::fallsBackToNcx()
{
    const QByteArray opf = QByteArrayLiteral(
        "<?xml version='1.0' encoding='utf-8'?>"
        "<package xmlns='http://www.idpf.org/2007/opf' version='2.0'>"
        "<metadata xmlns:dc='http://purl.org/dc/elements/1.1/'>"
        "<dc:title>旧书</dc:title></metadata>"
        "<manifest>"
        "<item id='ncx' href='toc.ncx' media-type='application/x-dtbncx+xml'/>"
        "<item id='ch1' href='text/ch1.xhtml' media-type='application/xhtml+xml'/>"
        "</manifest>"
        "<spine toc='ncx'><itemref idref='ch1'/></spine>"
        "</package>");
    const QByteArray ncx =
        QByteArrayLiteral("<?xml version='1.0' encoding='utf-8'?>"
                          "<ncx xmlns='http://www.daisy.org/z3986/2005/ncx/' version='2005-1'>"
                          "<navMap><navPoint id='n1' playOrder='1'>"
                          "<navLabel><text>楔子</text></navLabel>"
                          "<content src='text/ch1.xhtml'/>"
                          "</navPoint></navMap></ncx>");

    MemoryRangeSource source(buildZip({
        {QStringLiteral("META-INF/container.xml"), kContainerXml},
        {QStringLiteral("OEBPS/content.opf"), opf},
        {QStringLiteral("OEBPS/toc.ncx"), ncx},
        {QStringLiteral("OEBPS/text/ch1.xhtml"), kChapter1},
    }));
    EpubBook book(&source);

    const EpubMetadata metadata = loadOf(book);
    QCOMPARE(metadata.title, QStringLiteral("旧书"));
    QCOMPARE(metadata.chapters.size(), 1);
    QCOMPARE(metadata.chapters.at(0).title, QStringLiteral("楔子"));
}

void TestEpubBook::fallsBackToSpineWithoutToc()
{
    const QByteArray opf =
        QByteArrayLiteral("<?xml version='1.0' encoding='utf-8'?>"
                          "<package xmlns='http://www.idpf.org/2007/opf' version='3.0'>"
                          "<metadata xmlns:dc='http://purl.org/dc/elements/1.1/'>"
                          "<dc:title>没目录</dc:title></metadata>"
                          "<manifest>"
                          "<item id='a' href='text/ch1.xhtml' media-type='application/xhtml+xml'/>"
                          "<item id='b' href='text/ch2.xhtml' media-type='application/xhtml+xml'/>"
                          "</manifest>"
                          "<spine><itemref idref='a'/><itemref idref='b'/></spine>"
                          "</package>");

    MemoryRangeSource source(buildZip({
        {QStringLiteral("META-INF/container.xml"), kContainerXml},
        {QStringLiteral("OEBPS/content.opf"), opf},
        {QStringLiteral("OEBPS/text/ch1.xhtml"), kChapter1},
        {QStringLiteral("OEBPS/text/ch2.xhtml"), kChapter2},
    }));
    EpubBook book(&source);

    const EpubMetadata metadata = loadOf(book);
    QCOMPARE(metadata.chapters.size(), 2);
    // 没有目录信息时用文件名当章节名，至少能读
    QCOMPARE(metadata.chapters.at(0).title, QStringLiteral("ch1"));
    QCOMPARE(metadata.chapters.at(1).title, QStringLiteral("ch2"));
    QCOMPARE(metadata.chapters.at(0).href, QStringLiteral("OEBPS/text/ch1.xhtml"));
}

void TestEpubBook::rejectsBrokenPackage()
{
    // 是 zip，但没有 container.xml 也没有 .opf
    MemoryRangeSource source(buildZip({{QStringLiteral("readme.txt"), QByteArray("hello")}}));
    EpubBook book(&source);

    StorageError error;
    const EpubMetadata metadata = loadOf(book, &error);
    QVERIFY(metadata.chapters.isEmpty());
    QVERIFY(!error.isNull());

    // 根本不是 zip
    MemoryRangeSource plain(QByteArray("这不是压缩包，只是一段纯文本"));
    EpubBook plainBook(&plain);
    StorageError plainError;
    loadOf(plainBook, &plainError);
    QVERIFY(!plainError.isNull());
}

void TestEpubBook::parsesEpub3CoverImage()
{
    // EPUB3：manifest 上的 properties="cover-image" 就是声明
    QByteArray opf = kEpub3Opf;
    opf.replace("<item id='ch2'",
                "<item id='cover' href='images/cover.jpg' media-type='image/jpeg' "
                "properties='cover-image'/><item id='ch2'");
    const QByteArray coverBytes("COVER-JPEG-BYTES");

    MemoryRangeSource source(buildZip({
        {QStringLiteral("META-INF/container.xml"), kContainerXml},
        {QStringLiteral("OEBPS/content.opf"), opf},
        {QStringLiteral("OEBPS/nav.xhtml"), kEpub3Nav},
        {QStringLiteral("OEBPS/text/ch1.xhtml"), kChapter1},
        {QStringLiteral("OEBPS/text/ch2.xhtml"), kChapter2},
        {QStringLiteral("OEBPS/images/cover.jpg"), coverBytes},
    }));
    EpubBook book(&source);
    QCOMPARE(loadOf(book).chapters.size(), 2);
    QCOMPARE(book.coverHref(), QStringLiteral("OEBPS/images/cover.jpg"));

    QByteArray bytes;
    StorageError error;
    book.readCover([&bytes, &error](QByteArray data, StorageError err) {
        bytes = std::move(data);
        error = err;
    });
    QVERIFY2(error.isNull(), qPrintable(error.message()));
    QCOMPARE(bytes, coverBytes);
}

void TestEpubBook::parsesEpub2CoverMeta()
{
    // EPUB2：metadata 的 <meta name="cover" content="id"/> 指向 manifest 项
    const QByteArray opf = QByteArrayLiteral(
        "<?xml version='1.0' encoding='utf-8'?>"
        "<package xmlns='http://www.idpf.org/2007/opf' version='2.0'>"
        "<metadata xmlns:dc='http://purl.org/dc/elements/1.1/'>"
        "<dc:title>旧书封面</dc:title>"
        "<meta name='cover' content='cover-img'/>"
        "</metadata>"
        "<manifest>"
        "<item id='cover-img' href='images/front.png' media-type='image/png'/>"
        "<item id='ch1' href='text/ch1.xhtml' media-type='application/xhtml+xml'/>"
        "</manifest>"
        "<spine><itemref idref='ch1'/></spine>"
        "</package>");
    const QByteArray coverBytes("PNGDATA");

    MemoryRangeSource source(buildZip({
        {QStringLiteral("META-INF/container.xml"), kContainerXml},
        {QStringLiteral("OEBPS/content.opf"), opf},
        {QStringLiteral("OEBPS/text/ch1.xhtml"), kChapter1},
        {QStringLiteral("OEBPS/images/front.png"), coverBytes},
    }));
    EpubBook book(&source);
    QCOMPARE(loadOf(book).chapters.size(), 1);
    QCOMPARE(book.coverHref(), QStringLiteral("OEBPS/images/front.png"));

    QByteArray bytes;
    book.readCover([&bytes](QByteArray data, StorageError) { bytes = std::move(data); });
    QCOMPARE(bytes, coverBytes);
}

void TestEpubBook::reportsMissingCover()
{
    MemoryRangeSource source(epub3());
    EpubBook book(&source);
    loadOf(book);

    QVERIFY(book.coverHref().isEmpty());

    bool called = false;
    StorageError error;
    book.readCover([&called, &error](QByteArray, StorageError err) {
        called = true;
        error = err;
    });
    QVERIFY(called);
    QCOMPARE(error.kind(), StorageError::NotFound);
}

void TestEpubBook::resolveHrefHandlesDotsAndEncoding()
{
    QCOMPARE(
        EpubBook::resolveHref(QStringLiteral("OEBPS/"), QStringLiteral("../Text/ch%201.xhtml#x")),
        QStringLiteral("Text/ch 1.xhtml"));
    QCOMPARE(EpubBook::resolveHref(QString(), QStringLiteral("./a/b.xhtml")),
             QStringLiteral("a/b.xhtml"));
    // 外链不是 zip 条目
    QVERIFY(EpubBook::resolveHref(QStringLiteral("OEBPS/"), QStringLiteral("http://e.com/a"))
                .isEmpty());
    QVERIFY(
        EpubBook::resolveHref(QStringLiteral("OEBPS/"), QStringLiteral("data:image/png;base64,AA"))
            .isEmpty());
    QVERIFY(EpubBook::resolveHref(QStringLiteral("OEBPS/"), QStringLiteral("#anchor")).isEmpty());
}

void TestEpubBook::htmlToParagraphsStripsMarkup()
{
    const QStringList paragraphs = EpubBook::htmlToParagraphs(
        QStringLiteral("<html><head><style>p{}</style></head><body>"
                       "<p>一段文字&#20013;文</p><div>二段<br/>三段</div>"
                       "<p>   </p></body></html>"));
    const QStringList expected{QStringLiteral("一段文字中文"), QStringLiteral("二段"),
                               QStringLiteral("三段")};
    QCOMPARE(paragraphs, expected);
}

QTEST_MAIN(TestEpubBook)
#include "tst_epubbook.moc"
