// ComicBook：zip / cbz 的页序与按页解包（§6 PC-207）
//
// 用内存 RangeSource 喂字节，不碰真实文件。重点验证三件事：
//   - 页序是**自然排序**且只含图片（目录 / txt / `__MACOSX` 资源叉 / 隐藏文件都不算页）
//   - 列页只读尾部 + 中央目录，**不整包下载**；取一页只读那一页
//   - 没有图片条目时明确报「不是漫画文件」，而不是给个空列表让上层去猜

#include <QTemporaryDir>
#include <QtTest>

#include <zlib.h>

#include "RarTestBuilder.h"
#include "core/archive/RangeZipReader.h"
#include "core/comic/ComicBook.h"

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

/// 最小 zip 构造器（只写本用例需要解析的字段）
class ZipBuilder
{
public:
    void add(const QString &name, const QByteArray &data, bool deflate = false)
    {
        Item item;
        item.name = name;
        item.data = data;
        item.deflate = deflate;
        m_items.append(item);
    }

    QByteArray build() const
    {
        QByteArray out;
        QByteArray central;

        for (const Item &item : m_items) {
            const QByteArray name = item.name.toUtf8();
            const QByteArray payload = item.deflate ? deflateRaw(item.data) : item.data;
            const quint32 crc = crcOf(item.data);
            const quint16 method = item.deflate ? 8 : 0;
            const qint64 localOffset = out.size();

            putU32(out, 0x04034b50);
            putU16(out, 20);
            putU16(out, 0);
            putU16(out, method);
            putU16(out, 0);
            putU16(out, 0);
            putU32(out, crc);
            putU32(out, static_cast<quint32>(payload.size()));
            putU32(out, static_cast<quint32>(item.data.size()));
            putU16(out, static_cast<quint16>(name.size()));
            putU16(out, 0);
            out.append(name);
            out.append(payload);

            putU32(central, 0x02014b50);
            putU16(central, 20);
            putU16(central, 20);
            putU16(central, 0);
            putU16(central, method);
            putU16(central, 0);
            putU16(central, 0);
            putU32(central, crc);
            putU32(central, static_cast<quint32>(payload.size()));
            putU32(central, static_cast<quint32>(item.data.size()));
            putU16(central, static_cast<quint16>(name.size()));
            putU16(central, 0); // extra
            putU16(central, 0); // comment
            putU16(central, 0); // disk start
            putU16(central, 0); // internal attr
            putU32(central, 0); // external attr
            putU32(central, static_cast<quint32>(localOffset));
            central.append(name);
        }

        const qint64 cdOffset = out.size();
        const qint64 cdSize = central.size();
        out.append(central);

        putU32(out, 0x06054b50);
        putU16(out, 0);
        putU16(out, 0);
        putU16(out, static_cast<quint16>(m_items.size()));
        putU16(out, static_cast<quint16>(m_items.size()));
        putU32(out, static_cast<quint32>(cdSize));
        putU32(out, static_cast<quint32>(cdOffset));
        putU16(out, 0);
        return out;
    }

private:
    struct Item
    {
        QString name;
        QByteArray data;
        bool deflate = false;
    };
    QVector<Item> m_items;
};

/// 延迟 RangeSource：请求先攒着，由用例决定什么时候放行。
/// 用来验证「多页同时在途」——同步源一回调就把状态推到底，看不到并发。
class DeferredRangeSource : public RangeSource
{
public:
    explicit DeferredRangeSource(QByteArray data, QObject *parent = nullptr)
        : RangeSource(parent)
        , m_data(std::move(data))
    {}

    qint64 size() const override { return m_data.size(); }

    void readRange(qint64 start, qint64 length, Callback cb) override
    {
        Request request;
        request.start = start;
        request.length = length;
        request.callback = std::move(cb);
        m_queue.append(request);
    }

    /// 放行全部在途请求。解一页要两跳（先读本地文件头、再读数据），
    /// 所以一轮放行之后还会冒出新的请求，循环几轮直到清空。
    void flushAll()
    {
        for (int round = 0; round < 8 && !m_queue.isEmpty(); ++round) {
            const QVector<Request> batch = m_queue;
            m_queue.clear();
            for (const Request &request : batch) {
                if (request.start < 0 || request.length <= 0 || request.start >= m_data.size()) {
                    request.callback(
                        QByteArray(),
                        StorageError(StorageError::InvalidPath, QStringLiteral("区间非法")));
                    continue;
                }
                request.callback(
                    m_data.mid(static_cast<int>(request.start), static_cast<int>(request.length)),
                    StorageError());
            }
        }
    }

private:
    struct Request
    {
        qint64 start = 0;
        qint64 length = 0;
        Callback callback;
    };

    QByteArray m_data;
    QVector<Request> m_queue;
};

/// 一页「图片」的占位字节（内容不重要，只要求能原样往返）
QByteArray pageBytes(int size)
{
    QByteArray data;
    data.resize(size);
    for (int i = 0; i < size; ++i) {
        data[i] = static_cast<char>((i * 7) & 0xFF);
    }
    return data;
}

} // namespace

class TestComicBook : public QObject
{
    Q_OBJECT

private slots:
    void listsPagesInNaturalOrder();
    void ignoresNonImageEntries();
    void listsWithoutReadingWholeArchive();
    void readsPageBytes();
    void rejectsPageOutOfRange();
    void rejectsArchiveWithoutImages();
    void firstImageEntryMatchesPageOrder();
    void recognizesComicPathByExtension();
    void opensLocalRarAndReadsPage();
    void rarPageOrderMatchesZip();
    void deliversConcurrentPageRequests();
    void appliesExplicitPageOrder();
    void fallsBackToNaturalOrderWhenNamesDoNotMatch();
};

void TestComicBook::listsPagesInNaturalOrder()
{
    ZipBuilder zip;
    // 故意乱序写入：页序必须由页名自然排序决定，而不是打包顺序
    zip.add(QStringLiteral("c/10.png"), pageBytes(64));
    zip.add(QStringLiteral("c/2.png"), pageBytes(64));
    zip.add(QStringLiteral("c/1.png"), pageBytes(64));

    MemoryRangeSource source(zip.build());
    ComicBook book(&source);

    QStringList pages;
    StorageError error = StorageError(StorageError::Underlying, QStringLiteral("未回调"));
    book.open([&pages, &error](QStringList names, StorageError openError) {
        pages = names;
        error = openError;
    });

    QVERIFY(error.isNull());
    const QStringList expected{QStringLiteral("c/1.png"), QStringLiteral("c/2.png"),
                               QStringLiteral("c/10.png")};
    QCOMPARE(pages, expected);
    QCOMPARE(book.pageCount(), 3);
    QCOMPARE(book.pageName(1), QStringLiteral("c/2.png"));
}

void TestComicBook::ignoresNonImageEntries()
{
    ZipBuilder zip;
    zip.add(QStringLiteral("c/"), QByteArray()); // 目录
    zip.add(QStringLiteral("c/1.jpg"), pageBytes(32));
    zip.add(QStringLiteral("c/notes.txt"), QByteArrayLiteral("readme"));
    zip.add(QStringLiteral("__MACOSX/c/._1.jpg"), pageBytes(8)); // macOS 资源叉
    zip.add(QStringLiteral("c/.hidden.jpg"), pageBytes(8));
    zip.add(QStringLiteral("c/2.webp"), pageBytes(32));

    MemoryRangeSource source(zip.build());
    ComicBook book(&source);

    QStringList pages;
    book.open([&pages](QStringList names, StorageError) { pages = names; });

    const QStringList expected{QStringLiteral("c/1.jpg"), QStringLiteral("c/2.webp")};
    QCOMPARE(pages, expected);
}

void TestComicBook::listsWithoutReadingWholeArchive()
{
    ZipBuilder zip;
    // 每页 256KB：列页只该读尾部与中央目录，绝不能把整包拖下来
    for (int i = 1; i <= 8; ++i) {
        zip.add(QStringLiteral("c/%1.png").arg(i), pageBytes(256 * 1024));
    }
    const QByteArray data = zip.build();
    MemoryRangeSource source(data);
    ComicBook book(&source);

    int count = 0;
    book.open([&count](QStringList names, StorageError) { count = names.size(); });

    QCOMPARE(count, 8);
    QVERIFY2(
        source.requested * 4 < data.size(),
        qPrintable(QStringLiteral("列页读了 %1 / %2 字节").arg(source.requested).arg(data.size())));
}

void TestComicBook::readsPageBytes()
{
    const QByteArray stored = pageBytes(200);
    const QByteArray deflatedSource = pageBytes(4096);
    ZipBuilder zip;
    zip.add(QStringLiteral("c/1.png"), stored);
    zip.add(QStringLiteral("c/2.png"), deflatedSource, true);

    MemoryRangeSource source(zip.build());
    ComicBook book(&source);
    book.open([](QStringList, StorageError) {});

    QByteArray first;
    StorageError firstError = StorageError(StorageError::Underlying, QStringLiteral("未回调"));
    book.readPage(0, [&first, &firstError](QByteArray bytes, StorageError error) {
        first = bytes;
        firstError = error;
    });
    QVERIFY(firstError.isNull());
    QCOMPARE(first, stored);

    QByteArray second;
    book.readPage(1, [&second](QByteArray bytes, StorageError) { second = bytes; });
    QCOMPARE(second, deflatedSource);
}

void TestComicBook::rejectsPageOutOfRange()
{
    ZipBuilder zip;
    zip.add(QStringLiteral("c/1.png"), pageBytes(32));

    MemoryRangeSource source(zip.build());
    ComicBook book(&source);
    book.open([](QStringList, StorageError) {});

    bool callbackCalled = false;
    StorageError error;
    book.readPage(5, [&callbackCalled, &error](QByteArray, StorageError readError) {
        callbackCalled = true;
        error = readError;
    });

    QVERIFY(callbackCalled);
    QVERIFY(!error.isNull());
}

void TestComicBook::rejectsArchiveWithoutImages()
{
    ZipBuilder zip;
    zip.add(QStringLiteral("readme.txt"), QByteArrayLiteral("hello"));

    MemoryRangeSource source(zip.build());
    ComicBook book(&source);

    bool callbackCalled = false;
    StorageError error;
    book.open([&callbackCalled, &error](QStringList names, StorageError openError) {
        callbackCalled = true;
        error = openError;
        QVERIFY(names.isEmpty());
    });

    QVERIFY(callbackCalled);
    QVERIFY(!error.isNull());
    QVERIFY2(error.userMessage().contains(QStringLiteral("不是漫画")),
             qPrintable(error.userMessage()));
    QCOMPARE(book.pageCount(), 0);
}

void TestComicBook::firstImageEntryMatchesPageOrder()
{
    ZipBuilder zip;
    zip.add(QStringLiteral("c/10.png"), pageBytes(16));
    zip.add(QStringLiteral("c/1.png"), pageBytes(16));
    zip.add(QStringLiteral("c/2.png"), pageBytes(16));
    const QByteArray data = zip.build();

    MemoryRangeSource source(data);
    ComicBook book(&source);
    book.open([](QStringList, StorageError) {});

    // 封面取第一页，页序取自然排序的第一页 —— 两者必须是同一张
    RangeZipReader reader(&source);
    QVector<ZipEntry> entries;
    reader.open([&entries](QVector<ZipEntry> list, StorageError) { entries = list; });
    const int first = RangeZipReader::firstImageEntry(entries);
    QVERIFY(first >= 0);
    QCOMPARE(entries.at(first).name, book.pageName(0));
}

void TestComicBook::recognizesComicPathByExtension()
{
    QVERIFY(ComicBook::isComicArchivePath(QStringLiteral("/书架/vol1.cbz")));
    QVERIFY(ComicBook::isComicArchivePath(QStringLiteral("/书架/vol1.ZIP")));
    QVERIFY(ComicBook::isComicArchivePath(QStringLiteral("/书架/vol1.cbr")));
    QVERIFY(!ComicBook::isComicArchivePath(QStringLiteral("/书架/book.epub")));
    QVERIFY(!ComicBook::isComicArchivePath(QStringLiteral("/书架/movie.mkv")));
}

void TestComicBook::opensLocalRarAndReadsPage()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());

    const QByteArray first = pageBytes(180);
    const QByteArray second = pageBytes(64 * 1024);
    rartest::RarBuilder rar;
    rar.add(QStringLiteral("c/1.png"), first);
    rar.add(QStringLiteral("c/2.png"), second);
    const QString path = rartest::writeArchive(dir.path(), rar.build());
    QVERIFY(!path.isEmpty());

    ComicBook book(path);
    QStringList pages;
    StorageError error = StorageError(StorageError::Underlying, QStringLiteral("未回调"));
    // 本地 rar 的列页在后台线程跑，回调投递回本线程：转事件循环等它
    book.open([&pages, &error](QStringList names, StorageError openError) {
        pages = names;
        error = openError;
    });
    QTRY_VERIFY_WITH_TIMEOUT(pages.size() == 2, 5000);
    QVERIFY2(error.isNull(), qPrintable(error.userMessage()));
    QCOMPARE(book.pageCount(), 2);
    QCOMPARE(book.pageName(0), QStringLiteral("c/1.png"));

    QByteArray bytes;
    bool pageDone = false;
    StorageError pageError;
    book.readPage(1, [&bytes, &pageDone, &pageError](QByteArray data, StorageError readError) {
        bytes = std::move(data);
        pageDone = true;
        pageError = readError;
    });
    QTRY_VERIFY_WITH_TIMEOUT(pageDone, 5000);
    QVERIFY2(pageError.isNull(), qPrintable(pageError.userMessage()));
    QCOMPARE(bytes, second);
}

void TestComicBook::rarPageOrderMatchesZip()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());

    // 同一套页名分别打进 zip 与 rar：页序必须一致（换格式不能翻页错乱）
    ZipBuilder zip;
    rartest::RarBuilder rar;
    const QStringList names{QStringLiteral("c/10.png"), QStringLiteral("c/2.png"),
                            QStringLiteral("c/1.png")};
    for (const QString &name : names) {
        zip.add(name, pageBytes(32));
        rar.add(name, pageBytes(32));
    }

    MemoryRangeSource source(zip.build());
    ComicBook zipBook(&source);
    zipBook.open([](QStringList, StorageError) {});

    const QString path = rartest::writeArchive(dir.path(), rar.build());
    ComicBook rarBook(path);
    QStringList rarPages;
    rarBook.open([&rarPages](QStringList pageNames, StorageError) { rarPages = pageNames; });
    QTRY_VERIFY_WITH_TIMEOUT(rarPages.size() == 3, 5000);

    QStringList zipPages;
    for (int i = 0; i < zipBook.pageCount(); ++i) {
        zipPages.append(zipBook.pageName(i));
    }
    QCOMPARE(rarPages, zipPages);
}

void TestComicBook::deliversConcurrentPageRequests()
{
    const QByteArray p0 = pageBytes(1000);
    const QByteArray p1 = pageBytes(2000);
    const QByteArray p2 = pageBytes(3000);
    ZipBuilder zip;
    zip.add(QStringLiteral("c/1.png"), p0);
    zip.add(QStringLiteral("c/2.png"), p1);
    zip.add(QStringLiteral("c/3.png"), p2);

    DeferredRangeSource source(zip.build());
    ComicBook book(&source);

    bool opened = false;
    book.open([&opened](QStringList, StorageError) { opened = true; });
    QVERIFY2(!opened, "源还没放行，列页不该已经完成");
    source.flushAll();
    QVERIFY(opened);
    QCOMPARE(book.pageCount(), 3);

    // 桥接层的预取就是这么用的：几页一起要。单槽位实现下后一次请求会把
    // 前一次的回调顶掉，只有最后一页能收到回调 —— 这正是要防的回归
    QByteArray got0;
    QByteArray got1;
    QByteArray got2;
    bool done0 = false;
    bool done1 = false;
    bool done2 = false;
    book.readPage(0, [&got0, &done0](QByteArray bytes, StorageError) {
        got0 = std::move(bytes);
        done0 = true;
    });
    book.readPage(1, [&got1, &done1](QByteArray bytes, StorageError) {
        got1 = std::move(bytes);
        done1 = true;
    });
    book.readPage(2, [&got2, &done2](QByteArray bytes, StorageError) {
        got2 = std::move(bytes);
        done2 = true;
    });
    QVERIFY(!done0);
    QVERIFY(!done1);
    QVERIFY(!done2);

    source.flushAll();
    QVERIFY2(done0 && done1 && done2, "并发解页的回调被互相顶掉了");
    QCOMPARE(got0, p0);
    QCOMPARE(got1, p1);
    QCOMPARE(got2, p2);

    // 关书：在途请求一律作废，迟到的结果不许再回调
    bool stale = false;
    book.readPage(0, [&stale](QByteArray, StorageError) { stale = true; });
    book.cancel();
    source.flushAll();
    QVERIFY2(!stale, "取消之后仍回调了旧请求");
}

void TestComicBook::appliesExplicitPageOrder()
{
    ZipBuilder zip;
    zip.add(QStringLiteral("c/1.png"), pageBytes(32));
    zip.add(QStringLiteral("c/2.png"), pageBytes(32));
    zip.add(QStringLiteral("c/10.png"), pageBytes(32));
    zip.add(QStringLiteral("c/cover.png"), pageBytes(16)); // 封面不在 spine 里

    MemoryRangeSource source(zip.build());
    ComicBook book(&source);
    // 条目名排序会给出 1 → 2 → 10；spine 要求 10 → 1 → 2。
    // 第一条故意写错大小写：自制包的 href 与条目名常只差大小写，得能对上
    book.setPageOrder(
        {QStringLiteral("C/10.PNG"), QStringLiteral("c/1.png"), QStringLiteral("c/2.png")});

    QStringList pages;
    StorageError error = StorageError(StorageError::Underlying, QStringLiteral("未回调"));
    book.open([&pages, &error](QStringList names, StorageError openError) {
        pages = names;
        error = openError;
    });

    QVERIFY(error.isNull());
    const QStringList expected{QStringLiteral("c/10.png"), QStringLiteral("c/1.png"),
                               QStringLiteral("c/2.png")};
    QCOMPARE(pages, expected);
    // 名单外的封面图丢掉：否则会作为末页混进正文
    QCOMPARE(book.pageCount(), 3);
}

void TestComicBook::fallsBackToNaturalOrderWhenNamesDoNotMatch()
{
    ZipBuilder zip;
    zip.add(QStringLiteral("c/2.png"), pageBytes(32));
    zip.add(QStringLiteral("c/1.png"), pageBytes(32));

    MemoryRangeSource source(zip.build());
    ComicBook book(&source);
    book.setPageOrder({QStringLiteral("Text/ch1.xhtml")});

    QStringList pages;
    book.open([&pages](QStringList names, StorageError) { pages = names; });

    // 一个都对不上时宁可退回自然排序，也不能开成空书
    const QStringList expected{QStringLiteral("c/1.png"), QStringLiteral("c/2.png")};
    QCOMPARE(pages, expected);
}

QTEST_GUILESS_MAIN(TestComicBook)
#include "tst_comicbook.moc"
