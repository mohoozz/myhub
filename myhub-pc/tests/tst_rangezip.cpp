// RangeZipReader：EOCD / ZIP64 / 中央目录 / 按条目解压（§5.1 epub、§6 漫画的底座）
//
// 用内存 RangeSource 喂字节，不碰真实文件。重点验证三件事：
//   - 列目录只读尾部两次 Range，**不整包下载**
//   - 解压结果与原始字节一致（stored / deflate），CRC 不对必须报错
//   - ZIP64 的两种写法（目录结尾记录 / 条目字段扩展）都能解

#include <QtTest>

#include <zlib.h>

#include "core/archive/RangeZipReader.h"

using namespace myhub;

namespace {

/// 内存 RangeSource：记录每次请求，便于断言「没有整包读」
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
        ++requests;
        requested += length;
        if (start < 0 || length <= 0 || start >= m_data.size()) {
            cb(QByteArray(), StorageError(StorageError::InvalidPath, QStringLiteral("区间非法")));
            return;
        }
        // 越界部分截断（与真实文件尾行为一致）
        cb(m_data.mid(static_cast<int>(start), static_cast<int>(length)), StorageError());
    }

    int requests = 0;
    qint64 requested = 0;

private:
    QByteArray m_data;
};

QByteArray deflateRaw(const QByteArray &input)
{
    z_stream stream{};
    if (deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY)
        != Z_OK) {
        return {};
    }
    QByteArray out;
    out.resize(static_cast<int>(deflateBound(&stream, static_cast<uLong>(input.size()))) + 32);
    // 与生产代码同理：zlib 的 next_in 非 const，但只读
    stream.next_in = reinterpret_cast<Bytef *>(const_cast<char *>(input.constData())); // NOLINT
    stream.avail_in = static_cast<uInt>(input.size());
    stream.next_out = reinterpret_cast<Bytef *>(out.data());
    stream.avail_out = static_cast<uInt>(out.size());
    const int rc = deflate(&stream, Z_FINISH);
    const int produced = out.size() - static_cast<int>(stream.avail_out);
    deflateEnd(&stream);
    if (rc != Z_STREAM_END) {
        return {};
    }
    out.resize(produced);
    return out;
}

quint32 crcOf(const QByteArray &data)
{
    return static_cast<quint32>(crc32(crc32(0L, Z_NULL, 0),
                                      reinterpret_cast<const Bytef *>(data.constData()),
                                      static_cast<uInt>(data.size())));
}

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

void putU64(QByteArray &out, quint64 value)
{
    for (int i = 0; i < 8; ++i) {
        out.append(static_cast<char>((value >> (8 * i)) & 0xFF));
    }
}

/// 最小 zip 构造器（只写本类需要解析的字段）
class ZipBuilder
{
public:
    struct Item
    {
        QString name;
        QByteArray data;
        bool deflate = false;
        bool corruptCrc = false;
        /// 把尺寸/偏移写成 0xFFFFFFFF，真值塞进 ZIP64 extra（练习条目级 ZIP64）
        bool zip64Fields = false;
    };

    void add(const QString &name, const QByteArray &data, bool deflate = false)
    {
        m_items.append(Item{name, data, deflate, false, false});
    }

    void addCorruptCrc(const QString &name, const QByteArray &data)
    {
        m_items.append(Item{name, data, false, true, false});
    }

    void addZip64Fields(const QString &name, const QByteArray &data, bool deflate = false)
    {
        m_items.append(Item{name, data, deflate, false, true});
    }

    /// @param zip64End 目录结尾记录改用 ZIP64 形式（条目数/偏移写 0xFFFF/0xFFFFFFFF）
    QByteArray build(bool zip64End = false) const
    {
        QByteArray out;
        QByteArray central;

        for (const Item &item : m_items) {
            const QByteArray name = item.name.toUtf8();
            const QByteArray payload = item.deflate ? deflateRaw(item.data) : item.data;
            const quint32 crc = crcOf(item.data) + (item.corruptCrc ? 1u : 0u);
            const quint16 method = item.deflate ? 8 : 0;
            const qint64 localOffset = out.size();

            // ---- 本地文件头 ----
            putU32(out, 0x04034b50);
            putU16(out, 20);     // version needed
            putU16(out, 0);      // flags
            putU16(out, method); // method
            putU16(out, 0);      // mod time
            putU16(out, 0);      // mod date
            putU32(out, crc);
            putU32(out, static_cast<quint32>(payload.size()));
            putU32(out, static_cast<quint32>(item.data.size()));
            putU16(out, static_cast<quint16>(name.size()));
            putU16(out, 0); // extra
            out.append(name);
            out.append(payload);

            // ---- 中央目录条目 ----
            QByteArray extra;
            if (item.zip64Fields) {
                putU16(extra, 0x0001);
                putU16(extra, 24);
                putU64(extra, static_cast<quint64>(item.data.size()));
                putU64(extra, static_cast<quint64>(payload.size()));
                putU64(extra, static_cast<quint64>(localOffset));
            }

            putU32(central, 0x02014b50);
            putU16(central, 20); // version made by
            putU16(central, 20); // version needed
            putU16(central, 0);  // flags
            putU16(central, method);
            putU16(central, 0);
            putU16(central, 0);
            putU32(central, crc);
            putU32(central, item.zip64Fields ? 0xFFFFFFFFu : static_cast<quint32>(payload.size()));
            putU32(central,
                   item.zip64Fields ? 0xFFFFFFFFu : static_cast<quint32>(item.data.size()));
            putU16(central, static_cast<quint16>(name.size()));
            putU16(central, static_cast<quint16>(extra.size()));
            putU16(central, 0); // comment
            putU16(central, 0); // disk start
            putU16(central, 0); // internal attr
            putU32(central, 0); // external attr
            putU32(central, item.zip64Fields ? 0xFFFFFFFFu : static_cast<quint32>(localOffset));
            central.append(name);
            central.append(extra);
        }

        const qint64 cdOffset = out.size();
        const qint64 cdSize = central.size();
        out.append(central);

        if (zip64End) {
            const qint64 zip64RecordOffset = out.size();
            putU32(out, 0x06064b50);
            putU64(out, 44); // size of remaining record
            putU16(out, 45); // version made by
            putU16(out, 45); // version needed
            putU32(out, 0);  // this disk
            putU32(out, 0);  // cd disk
            putU64(out, static_cast<quint64>(m_items.size()));
            putU64(out, static_cast<quint64>(m_items.size()));
            putU64(out, static_cast<quint64>(cdSize));
            putU64(out, static_cast<quint64>(cdOffset));

            putU32(out, 0x07064b50);
            putU32(out, 0); // locator disk
            putU64(out, static_cast<quint64>(zip64RecordOffset));
            putU32(out, 1); // total disks

            putU32(out, 0x06054b50);
            putU16(out, 0);
            putU16(out, 0);
            putU16(out, 0xFFFF);
            putU16(out, 0xFFFF);
            putU32(out, 0xFFFFFFFFu);
            putU32(out, 0xFFFFFFFFu);
            putU16(out, 0);
            return out;
        }

        putU32(out, 0x06054b50);
        putU16(out, 0); // this disk
        putU16(out, 0); // cd disk
        putU16(out, static_cast<quint16>(m_items.size()));
        putU16(out, static_cast<quint16>(m_items.size()));
        putU32(out, static_cast<quint32>(cdSize));
        putU32(out, static_cast<quint32>(cdOffset));
        putU16(out, 0); // comment
        return out;
    }

private:
    QVector<Item> m_items;
};

/// 同步跑完 open（内存 RangeSource 的回调是同步的）
QVector<ZipEntry> openZip(RangeZipReader &reader, StorageError *error = nullptr)
{
    QVector<ZipEntry> captured;
    StorageError capturedError;
    reader.open([&captured, &capturedError](QVector<ZipEntry> entries, StorageError err) {
        captured = entries;
        capturedError = err;
    });
    if (error) {
        *error = capturedError;
    }
    return captured;
}

QByteArray readEntry(RangeZipReader &reader, const ZipEntry &entry, StorageError *error = nullptr)
{
    QByteArray captured;
    StorageError capturedError;
    reader.readEntry(entry, [&captured, &capturedError](QByteArray data, StorageError err) {
        captured = data;
        capturedError = err;
    });
    if (error) {
        *error = capturedError;
    }
    return captured;
}

/// 不可压缩的确定性字节：用来把「只读尾部」的断言做出区分度（压缩后的文本太小了）
QByteArray incompressible(int bytes)
{
    QRandomGenerator rng(20261111u);
    QByteArray out(bytes, Qt::Uninitialized);
    for (int i = 0; i < bytes; ++i) {
        out[i] = static_cast<char>(rng.bounded(256));
    }
    return out;
}

QByteArray bigText(int bytes)
{
    // 可压缩但不会压没的内容，避免「压缩后比元数据还小」影响请求量断言
    QByteArray out;
    out.reserve(bytes);
    int line = 0;
    while (out.size() < bytes) {
        out.append(
            QStringLiteral("第%1段：这是一段用来撑大文件的正文，混合 english words 与数字 %2。\n")
                .arg(line)
                .arg(line * 7)
                .toUtf8());
        ++line;
    }
    return out;
}

} // namespace

class TestRangeZip : public QObject
{
    Q_OBJECT

private slots:
    void listsEntriesWithoutReadingWholeFile();
    void readsStoredAndDeflatedEntries();
    void reportsCrcMismatch();
    void rejectsNonZip();
    void readsZip64EndRecord();
    void readsZip64EntryFields();
    void firstImageEntrySkipsNoise();
    void indexOfIsExactMatch();
};

void TestRangeZip::listsEntriesWithoutReadingWholeFile()
{
    // 400KB 随机字节：压不动，文件确实是 400KB 量级，才能证明「没有整包读」
    const QByteArray blob = incompressible(400 * 1024);

    ZipBuilder builder;
    builder.add(QStringLiteral("mimetype"), QByteArray("application/epub+zip"));
    builder.add(QStringLiteral("OEBPS/images/cover.jpg"), blob);

    MemoryRangeSource source(builder.build());
    RangeZipReader reader(&source);

    StorageError error;
    const QVector<ZipEntry> entries = openZip(reader, &error);

    QVERIFY2(error.isNull(), qPrintable(error.message()));
    QCOMPARE(entries.size(), 2);
    QCOMPARE(entries.at(0).name, QStringLiteral("mimetype"));
    QCOMPARE(entries.at(1).name, QStringLiteral("OEBPS/images/cover.jpg"));
    QCOMPARE(entries.at(1).uncompressedSize, qint64(blob.size()));
    QVERIFY(entries.at(1).supported());

    // 只读了「尾部找 EOCD」+「中央目录」两次，且总量不到文件的一半
    QCOMPARE(source.requests, 2);
    QVERIFY2(source.requested * 2 < source.size(),
             qPrintable(QStringLiteral("请求了 %1 字节 / 文件 %2 字节")
                            .arg(source.requested)
                            .arg(source.size())));
}

void TestRangeZip::readsStoredAndDeflatedEntries()
{
    const QByteArray plain = QByteArray("stored payload 中文内容");
    const QByteArray longText = bigText(64 * 1024);

    ZipBuilder builder;
    builder.add(QStringLiteral("plain.txt"), plain);
    builder.add(QStringLiteral("text/chapter.xhtml"), longText, true);

    MemoryRangeSource source(builder.build());
    RangeZipReader reader(&source);
    const QVector<ZipEntry> entries = openZip(reader);
    QCOMPARE(entries.size(), 2);

    StorageError storedError;
    QCOMPARE(readEntry(reader, entries.at(0), &storedError), plain);
    QVERIFY(storedError.isNull());

    StorageError deflateError;
    QCOMPARE(readEntry(reader, entries.at(1), &deflateError), longText);
    QVERIFY(deflateError.isNull());
}

void TestRangeZip::reportsCrcMismatch()
{
    ZipBuilder builder;
    builder.addCorruptCrc(QStringLiteral("broken.txt"), QByteArray("内容没问题但校验和是错的"));

    MemoryRangeSource source(builder.build());
    RangeZipReader reader(&source);
    const QVector<ZipEntry> entries = openZip(reader);
    QCOMPARE(entries.size(), 1);

    StorageError error;
    const QByteArray data = readEntry(reader, entries.constFirst(), &error);
    QVERIFY(data.isEmpty());
    QVERIFY(!error.isNull());
    QVERIFY(error.message().contains(QStringLiteral("CRC")));
}

void TestRangeZip::rejectsNonZip()
{
    MemoryRangeSource source(bigText(4096));
    RangeZipReader reader(&source);

    StorageError error;
    const QVector<ZipEntry> entries = openZip(reader, &error);
    QVERIFY(entries.isEmpty());
    QVERIFY(!error.isNull());
    QCOMPARE(error.kind(), StorageError::InvalidResponse);
}

void TestRangeZip::readsZip64EndRecord()
{
    ZipBuilder builder;
    builder.add(QStringLiteral("mimetype"), QByteArray("application/epub+zip"));
    builder.add(QStringLiteral("OEBPS/text/chapter1.xhtml"), bigText(8 * 1024), true);

    MemoryRangeSource source(builder.build(true));
    RangeZipReader reader(&source);

    StorageError error;
    const QVector<ZipEntry> entries = openZip(reader, &error);
    QVERIFY2(error.isNull(), qPrintable(error.message()));
    QCOMPARE(entries.size(), 2);

    StorageError readError;
    QCOMPARE(readEntry(reader, entries.at(1), &readError), bigText(8 * 1024));
    QVERIFY(readError.isNull());
}

void TestRangeZip::readsZip64EntryFields()
{
    const QByteArray text = bigText(32 * 1024);

    ZipBuilder builder;
    builder.addZip64Fields(QStringLiteral("OEBPS/text/chapter1.xhtml"), text, true);

    MemoryRangeSource source(builder.build());
    RangeZipReader reader(&source);

    StorageError error;
    const QVector<ZipEntry> entries = openZip(reader, &error);
    QVERIFY2(error.isNull(), qPrintable(error.message()));
    QCOMPARE(entries.size(), 1);
    QCOMPARE(entries.constFirst().uncompressedSize, qint64(text.size()));
    QVERIFY(entries.constFirst().compressedSize > 0);

    StorageError readError;
    QCOMPARE(readEntry(reader, entries.constFirst(), &readError), text);
    QVERIFY(readError.isNull());
}

void TestRangeZip::firstImageEntrySkipsNoise()
{
    QVector<ZipEntry> entries;
    const auto add = [&entries](const QString &name) {
        ZipEntry entry;
        entry.name = name;
        entry.method = 8;
        entries.append(entry);
    };
    add(QStringLiteral("Comic/"));
    add(QStringLiteral("Comic/info.txt"));
    add(QStringLiteral("__MACOSX/Comic/._page2.jpg"));
    add(QStringLiteral("Comic/.hidden.png"));
    add(QStringLiteral("Comic/page10.jpg"));
    add(QStringLiteral("Comic/page2.jpg"));

    const int index = RangeZipReader::firstImageEntry(entries);
    QVERIFY(index >= 0);
    // 自然排序：page2 在 page10 之前
    QCOMPARE(entries.at(index).name, QStringLiteral("Comic/page2.jpg"));

    QVector<ZipEntry> noImages;
    ZipEntry textEntry;
    textEntry.name = QStringLiteral("readme.txt");
    noImages.append(textEntry);
    QCOMPARE(RangeZipReader::firstImageEntry(noImages), -1);
}

void TestRangeZip::indexOfIsExactMatch()
{
    QVector<ZipEntry> entries;
    ZipEntry entry;
    entry.name = QStringLiteral("OEBPS/Text/Chapter1.xhtml");
    entries.append(entry);

    QCOMPARE(RangeZipReader::indexOf(entries, QStringLiteral("OEBPS/Text/Chapter1.xhtml")), 0);
    QCOMPARE(RangeZipReader::indexOf(entries, QStringLiteral("OEBPS/text/chapter1.xhtml")), -1);
}

QTEST_MAIN(TestRangeZip)
#include "tst_rangezip.moc"
