// ComicBridge：漫画阅读器的真实链路（§6 PC-207）
//
// 全部走真实路径：真实 cbz 落盘 → LocalAdapter → AdapterRangeSource → 解包 → 页缓存落盘，
// 进度写真实 sqlite。不 mock 适配器，否则「页码存没存进去、缓存键对不对」这类
// 只有真跑才现形的问题会被漏掉。

#include "RarTestBuilder.h"

#include "core/comic/ComicDetector.h"
#include "core/comic/ComicPageStore.h"
#include "core/database/AppDatabase.h"
#include "core/history/ProgressRepository.h"
#include "core/preferences/AppSettings.h"
#include "core/utils/AppPaths.h"
#include "features/connections/ConnectionStore.h"
#include "features/reading/ComicBridge.h"

#include <QBuffer>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImage>
#include <QSignalSpy>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QUrl>
#include <QtTest>

#include <zlib.h>

using namespace myhub;

namespace {

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

/// 只写 stored 条目的最小 zip：桥接测试关心「页能不能显示」，不关心压缩
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

/// 真 PNG 字节：`ComicBridge` 会用 QImageReader 验一遍，假字节过不了
QByteArray pngOf(const QColor &color, int size = 24)
{
    QImage image(size, size, QImage::Format_RGB32);
    image.fill(color);
    QByteArray bytes;
    QBuffer buffer(&bytes);
    buffer.open(QIODevice::WriteOnly);
    image.save(&buffer, "PNG");
    return bytes;
}

const QString kComicPath = QStringLiteral("/漫画/第一卷.cbz");
const QString kNotComicPath = QStringLiteral("/漫画/不是漫画.zip");
const QString kImageEpubPath = QStringLiteral("/漫画/图集.epub");
const QString kTextEpubPath = QStringLiteral("/漫画/文字书.epub");

const QByteArray kContainerXml = QByteArrayLiteral(
    "<?xml version='1.0' encoding='utf-8'?>"
    "<container version='1.0' xmlns='urn:oasis:names:tc:opendocument:xmlns:container'>"
    "<rootfiles><rootfile full-path='OEBPS/content.opf' "
    "media-type='application/oebps-package+xml'/></rootfiles></container>");

/// 图集 epub：spine 顺序刻意与条目名相反（002 → 001 → 003），
/// 若漫画侧还按条目名排序，打开后第一页就会是 001
QByteArray imageEpub()
{
    const QByteArray opf = QByteArrayLiteral(
        "<?xml version='1.0' encoding='utf-8'?>"
        "<package xmlns='http://www.idpf.org/2007/opf' version='3.0'>"
        "<metadata xmlns:dc='http://purl.org/dc/elements/1.1/'>"
        "<dc:title>图集</dc:title></metadata>"
        "<manifest>"
        "<item id='p1' href='pages/001.png' media-type='image/png'/>"
        "<item id='p2' href='pages/002.png' media-type='image/png'/>"
        "<item id='p3' href='pages/003.png' media-type='image/png'/>"
        "</manifest>"
        "<spine><itemref idref='p2'/><itemref idref='p1'/><itemref idref='p3'/></spine>"
        "</package>");
    return buildZip({
        {QStringLiteral("mimetype"), QByteArrayLiteral("application/epub+zip")},
        {QStringLiteral("META-INF/container.xml"), kContainerXml},
        {QStringLiteral("OEBPS/content.opf"), opf},
        {QStringLiteral("OEBPS/pages/001.png"), pngOf(Qt::red)},
        {QStringLiteral("OEBPS/pages/002.png"), pngOf(Qt::green)},
        {QStringLiteral("OEBPS/pages/003.png"), pngOf(Qt::blue)},
    });
}

/// 文字书 epub：手动「以漫画阅读器打开」用错了地方的情形
QByteArray textEpub()
{
    const QByteArray opf =
        QByteArrayLiteral("<?xml version='1.0' encoding='utf-8'?>"
                          "<package xmlns='http://www.idpf.org/2007/opf' version='3.0'>"
                          "<metadata xmlns:dc='http://purl.org/dc/elements/1.1/'>"
                          "<dc:title>文字书</dc:title></metadata>"
                          "<manifest>"
                          "<item id='c1' href='text/ch1.xhtml' media-type='application/xhtml+xml'/>"
                          "</manifest>"
                          "<spine><itemref idref='c1'/></spine>"
                          "</package>");
    return buildZip({
        {QStringLiteral("mimetype"), QByteArrayLiteral("application/epub+zip")},
        {QStringLiteral("META-INF/container.xml"), kContainerXml},
        {QStringLiteral("OEBPS/content.opf"), opf},
        {QStringLiteral("OEBPS/text/ch1.xhtml"),
         QByteArrayLiteral("<html><body><p>正文</p></body></html>")},
    });
}

} // namespace

class TestComicBridge : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void init();
    void cleanupTestCase();

    void opensArchiveAndShowsFirstPage();
    void pagesHitDiskCache();
    void flipsPagesAndStoresProgress();
    void resumesAtSavedPage();
    void exposesPagesOnDemand();
    void tracksScrollPositionWithoutDecoding();
    void remembersDisplayPreferences();
    void detectsDirectionFromTitleAndKeepsManualChoice();
    void rejectsArchiveWithoutImages();
    void rejectsNonComicExtension();
    void invalidatesPagesWhenFileChanges();
    void opensLocalCbrAndShowsPage();
    void prefetchesNeighborPages();
    void suggestsNextComicWhenFinished();
    void suggestsNextImageEpubWhenFinished();
    void storesPageListOnOpen();
    void opensOfflineFromPageCache();
    void opensImageEpubInSpineOrder();
    void rejectsTextEpubAsComic();

private:
    void writeComic(const QByteArray &bytes);

    QTemporaryDir m_dbDir;
    QTemporaryDir m_root;
    QString m_connectionId = QStringLiteral("conn-comic-test");
};

void TestComicBridge::initTestCase()
{
    QCoreApplication::setApplicationName(
        QStringLiteral("MyHubComicBridgeTest-%1").arg(QCoreApplication::applicationPid()));
    QStandardPaths::setTestModeEnabled(true);
    AppPaths::initializeAll();
    AppSettings::instance().initialize();

    QVERIFY(m_dbDir.isValid());
    QVERIFY(AppDatabase::instance().open(m_dbDir.filePath(QStringLiteral("myhub.sqlite"))));

    QVERIFY(m_root.isValid());
    QVERIFY(QDir(m_root.path()).mkpath(QStringLiteral("漫画")));

    writeComic(buildZip({{QStringLiteral("p/1.png"), pngOf(Qt::red)},
                         {QStringLiteral("p/2.png"), pngOf(Qt::green)},
                         {QStringLiteral("p/10.png"), pngOf(Qt::blue)}}));

    QFile imageBook(m_root.filePath(QStringLiteral("漫画/图集.epub")));
    QVERIFY(imageBook.open(QIODevice::WriteOnly));
    QVERIFY(imageBook.write(imageEpub()) > 0);
    imageBook.close();

    QFile textBook(m_root.filePath(QStringLiteral("漫画/文字书.epub")));
    QVERIFY(textBook.open(QIODevice::WriteOnly));
    QVERIFY(textBook.write(textEpub()) > 0);
    textBook.close();

    QFile notComic(m_root.filePath(QStringLiteral("漫画/不是漫画.zip")));
    QVERIFY(notComic.open(QIODevice::WriteOnly));
    notComic.write(buildZip({{QStringLiteral("readme.txt"), QByteArrayLiteral("hello")}}));
    notComic.close();

    ConnectionRecord record;
    record.id = m_connectionId;
    record.name = QStringLiteral("临时漫画柜");
    record.type = ConnectionType::Local;
    record.config.insert(QStringLiteral("path"), m_root.path());
    QVERIFY(ConnectionStore::instance().upsert(record));
}

void TestComicBridge::init()
{
    ComicBridge::instance()->close();
    QVERIFY(AppDatabase::instance().execute(QStringLiteral("DELETE FROM readingProgress")));
    QVERIFY(AppDatabase::instance().execute(QStringLiteral("DELETE FROM comicPages")));
    // 判定缓存也要清干净：上一个用例写下的 epub 结论不能漏进这一个
    QVERIFY(AppDatabase::instance().execute(QStringLiteral("DELETE FROM comicVerdict")));
    ComicDetector::resetMemory();
}

void TestComicBridge::cleanupTestCase()
{
    ComicBridge::instance()->close();
    AppDatabase::instance().close();
}

void TestComicBridge::writeComic(const QByteArray &bytes)
{
    QFile file(m_root.filePath(QStringLiteral("漫画/第一卷.cbz")));
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    file.write(bytes);
    file.close();
}

void TestComicBridge::opensArchiveAndShowsFirstPage()
{
    ComicBridge &comic = *ComicBridge::instance();
    comic.open(m_connectionId, kComicPath, QString());

    QTRY_VERIFY_WITH_TIMEOUT(comic.opened() || !comic.errorText().isEmpty(), 5000);
    QVERIFY2(comic.errorText().isEmpty(), qPrintable(comic.errorText()));

    // 页数是「图片条目数」，按自然排序：1 / 2 / 10
    QCOMPARE(comic.pageCount(), 3);
    QCOMPARE(comic.title(), QStringLiteral("第一卷.cbz"));
    QCOMPARE(comic.pageIndex(), 0);
    QCOMPARE(comic.pageName(), QStringLiteral("p/1.png"));

    QTRY_VERIFY_WITH_TIMEOUT(!comic.pageUrl().isEmpty(), 5000);
    QVERIFY(comic.pageUrl().startsWith(QStringLiteral("file://")));

    // 缓存文件得是真的图片，QML 才能直接显示
    const QString local = QUrl(comic.pageUrl()).toLocalFile();
    QVERIFY(QFileInfo::exists(local));
    QImage shown(local);
    QVERIFY(!shown.isNull());
    QCOMPARE(shown.size(), QSize(24, 24));

    QCOMPARE(comic.percent(), 1.0 / 3.0);
}

void TestComicBridge::pagesHitDiskCache()
{
    ComicBridge &comic = *ComicBridge::instance();
    comic.open(m_connectionId, kComicPath, QString());
    QTRY_VERIFY_WITH_TIMEOUT(!comic.pageUrl().isEmpty(), 5000);
    const QString first = comic.pageUrl();

    comic.close();
    comic.open(m_connectionId, kComicPath, QString());
    QTRY_VERIFY_WITH_TIMEOUT(!comic.pageUrl().isEmpty(), 5000);

    // 同一连接源 + 同一路径 + 同一指纹 + 同一页 → 仍是同一个缓存文件
    QCOMPARE(comic.pageUrl(), first);
}

void TestComicBridge::flipsPagesAndStoresProgress()
{
    ComicBridge &comic = *ComicBridge::instance();
    comic.open(m_connectionId, kComicPath, QString());
    QTRY_VERIFY_WITH_TIMEOUT(!comic.pageUrl().isEmpty(), 5000);

    comic.nextPage();
    QTRY_COMPARE_WITH_TIMEOUT(comic.pageIndex(), 1, 5000);
    QTRY_VERIFY_WITH_TIMEOUT(comic.pageUrl().length() > 0, 5000);
    QCOMPARE(comic.pageName(), QStringLiteral("p/2.png"));

    ProgressRecord record;
    QTRY_VERIFY_WITH_TIMEOUT(
        ProgressRepository::instance().find(m_connectionId, kComicPath, &record), 5000);
    QCOMPARE(record.mediaType, QStringLiteral("comic"));
    QCOMPARE(record.progress.value(QStringLiteral("page")).toInt(), 1);
    QCOMPARE(record.progress.value(QStringLiteral("pageName")).toString(),
             QStringLiteral("p/2.png"));
    QVERIFY(record.percent > 0.6 && record.percent < 0.7);
    QVERIFY(!record.finished);

    // 末页才算读完
    comic.goToPage(2);
    QTRY_VERIFY_WITH_TIMEOUT(comic.pageUrl().length() > 0 && comic.pageIndex() == 2, 5000);
    QTRY_VERIFY_WITH_TIMEOUT(
        ProgressRepository::instance().find(m_connectionId, kComicPath, &record), 5000);
    QVERIFY(record.finished);
    QCOMPARE(record.percent, 1.0);

    // 越界不崩、不误存
    comic.goToPage(99);
    QTest::qWait(50);
    QCOMPARE(comic.pageIndex(), 2);
}

void TestComicBridge::resumesAtSavedPage()
{
    ComicBridge &comic = *ComicBridge::instance();
    comic.open(m_connectionId, kComicPath, QString());
    QTRY_VERIFY_WITH_TIMEOUT(!comic.pageUrl().isEmpty(), 5000);
    comic.nextPage();
    QTRY_COMPARE_WITH_TIMEOUT(comic.pageIndex(), 1, 5000);

    comic.close();
    comic.open(m_connectionId, kComicPath, QString());

    // 重开回到上次那页（不是第一页）
    QTRY_COMPARE_WITH_TIMEOUT(comic.pageIndex(), 1, 5000);
    QTRY_VERIFY_WITH_TIMEOUT(comic.pageUrl().length() > 0, 5000);
    QCOMPARE(comic.pageName(), QStringLiteral("p/2.png"));
}

void TestComicBridge::exposesPagesOnDemand()
{
    ComicBridge &comic = *ComicBridge::instance();
    comic.open(m_connectionId, kComicPath, QString());
    QTRY_VERIFY_WITH_TIMEOUT(!comic.pageUrl().isEmpty(), 5000);

    // 越界一律空串：双页的右页经常落在末尾之外，QML 不该被迫判边界
    QCOMPARE(comic.pageUrlAt(-1), QString());
    QCOMPARE(comic.pageUrlAt(99), QString());

    // 双页/条漫要的「第二张图」：按需解一页，落盘后 pageCached 才通知 QML
    QSignalSpy cached(&comic, &ComicBridge::pageCached);
    QVERIFY(cached.isValid());
    comic.ensurePage(2);

    QTRY_VERIFY_WITH_TIMEOUT(!comic.pageUrlAt(2).isEmpty(), 5000);
    QVERIFY(QFileInfo(QUrl(comic.pageUrlAt(2)).toLocalFile()).size() > 0);

    bool announced = false;
    for (const QList<QVariant> &args : cached) {
        if (args.at(0).toInt() == 2) {
            announced = true;
        }
    }
    QVERIFY2(announced, "解出来的页没有 pageCached 通知，QML 就永远等不到");

    // 已经在缓存里的页：立即回一个 pageCached，QML 不必再等一次往返
    const int before = cached.count();
    comic.ensurePage(2);
    QCOMPARE(cached.count(), before + 1);

    // 当前页仍然由 pageUrl 管，两套口径不许打架
    QCOMPARE(comic.pageIndex(), 0);
    QVERIFY(comic.pageUrlAt(0).length() > 0);
}

void TestComicBridge::tracksScrollPositionWithoutDecoding()
{
    ComicBridge &comic = *ComicBridge::instance();
    comic.open(m_connectionId, kComicPath, QString());
    QTRY_VERIFY_WITH_TIMEOUT(!comic.pageUrl().isEmpty(), 5000);

    // 条漫滚动：只更新「读到第几页」，不去解压 —— 解压归 ensurePage
    comic.trackPage(2);
    QCOMPARE(comic.pageIndex(), 2);
    QCOMPARE(comic.percent(), 1.0);

    ProgressRecord record;
    QTRY_VERIFY_WITH_TIMEOUT(
        ProgressRepository::instance().find(m_connectionId, kComicPath, &record), 5000);
    QCOMPARE(record.progress.value(QStringLiteral("page")).toInt(), 2);
    QCOMPARE(record.progress.value(QStringLiteral("pageName")).toString(),
             QStringLiteral("p/10.png"));
    QVERIFY(record.finished);

    // 同一页重复上报不重复写库、也不重复发信号
    QSignalSpy pageChanged(&comic, &ComicBridge::pageChanged);
    comic.trackPage(2);
    QCOMPARE(pageChanged.count(), 0);
}

void TestComicBridge::remembersDisplayPreferences()
{
    ComicBridge &comic = *ComicBridge::instance();
    comic.setMode(2);
    comic.setRightToLeft(false);
    comic.setBrightness(0.4);

    QCOMPARE(comic.mode(), 2);
    QVERIFY(!comic.rightToLeft());
    QCOMPARE(comic.brightness(), 0.4);

    // 落盘的键名是契约：模式/方向是本阅读器的，亮度与小说**共用**同一个键
    QCOMPARE(AppSettings::instance().value(QStringLiteral("reader.comic.mode")).toInt(), 2);
    // 方向换成三态键：点一下就写成手动值（0 左到右 / 1 右到左），不再动老的布尔键
    QCOMPARE(comic.direction(), 0);
    QCOMPARE(AppSettings::instance().value(QStringLiteral("reader.comic.direction")).toInt(), 0);
    QCOMPARE(AppSettings::instance().value(QStringLiteral("reader.comic.rtl")).isValid(), false);
    QCOMPARE(AppSettings::instance().value(QStringLiteral("reader.brightness")).toDouble(), 0.4);

    // 越界夹紧，不写脏值进配置
    comic.setMode(99);
    QCOMPARE(comic.mode(), 2);
    comic.setMode(-3);
    QCOMPARE(comic.mode(), 0);

    // 复原，别把偏好漏给其它用例
    comic.setRightToLeft(true);
    comic.setBrightness(-1.0);
    QVERIFY(comic.rightToLeft());
}

void TestComicBridge::detectsDirectionFromTitleAndKeepsManualChoice()
{
    ComicBridge &comic = *ComicBridge::instance();

    // 自动（默认）：日文书名判成右到左，界面拿到 autoDirection 才能显示「自动（右→左）」
    comic.setDirection(-1);
    comic.open(m_connectionId, kComicPath, QStringLiteral("進撃の巨人 第1巻"));
    QTRY_VERIFY_WITH_TIMEOUT(comic.opened() || !comic.errorText().isEmpty(), 8000);
    QVERIFY(comic.opened());
    QCOMPARE(comic.direction(), -1);
    QCOMPARE(comic.autoDirection(), 1);
    QVERIFY(comic.rightToLeft());

    // 中文条漫：同一本书换个标题就翻成左到右（判定跟着书走，不是全局一次）
    comic.open(m_connectionId, kComicPath, QStringLiteral("某条漫 第12话"));
    QTRY_VERIFY_WITH_TIMEOUT(comic.opened() || !comic.errorText().isEmpty(), 8000);
    QVERIFY(comic.opened());
    QCOMPARE(comic.autoDirection(), 0);
    QVERIFY(!comic.rightToLeft());

    // 判不出来：回到默认（右到左），不继承上一本的结论
    comic.open(m_connectionId, kComicPath, QStringLiteral("第一卷"));
    QTRY_VERIFY_WITH_TIMEOUT(comic.opened() || !comic.errorText().isEmpty(), 8000);
    QVERIFY(comic.opened());
    QVERIFY(comic.rightToLeft());

    // 手动定过之后，自动判定只用于显示，不再改生效方向
    comic.setDirection(0);
    QCOMPARE(AppSettings::instance().value(QStringLiteral("reader.comic.direction")).toInt(), 0);
    comic.open(m_connectionId, kComicPath, QStringLiteral("進撃の巨人 第1巻"));
    QTRY_VERIFY_WITH_TIMEOUT(comic.opened() || !comic.errorText().isEmpty(), 8000);
    QVERIFY(comic.opened());
    QCOMPARE(comic.autoDirection(), 1);
    QVERIFY(!comic.rightToLeft());

    // 老版本只存过布尔键：读到时当成手动值迁移过来（已选过的方向不该被重新猜）
    comic.setDirection(1);
    QCOMPARE(comic.direction(), 1);
    AppSettings::instance().remove(QStringLiteral("reader.comic.direction"));
    AppSettings::instance().setValue(QStringLiteral("reader.comic.rtl"), false);
    QTRY_COMPARE(comic.direction(), 0);
    QVERIFY(!comic.rightToLeft());

    // 复原：回到自动，且清掉老键，别把状态漏给其它用例
    comic.setDirection(-1);
    AppSettings::instance().remove(QStringLiteral("reader.comic.rtl"));
}

void TestComicBridge::rejectsArchiveWithoutImages()
{
    ComicBridge &comic = *ComicBridge::instance();
    comic.open(m_connectionId, kNotComicPath, QString());

    QTRY_VERIFY_WITH_TIMEOUT(!comic.errorText().isEmpty(), 5000);
    QVERIFY(!comic.opened());
    QCOMPARE(comic.pageCount(), 0);
    QVERIFY2(comic.errorText().contains(QStringLiteral("不是漫画")), qPrintable(comic.errorText()));
}

void TestComicBridge::rejectsNonComicExtension()
{
    // 「以漫画阅读器打开」被用在 txt/mp4 上：扩展名这道闸要直说支持什么，
    // 不能走到 zip 解析再报「不是压缩包」；也不该留下一直转的加载态
    ComicBridge &comic = *ComicBridge::instance();
    comic.open(m_connectionId, QStringLiteral("/漫画/说明.txt"), QString());

    QTRY_VERIFY_WITH_TIMEOUT(!comic.errorText().isEmpty(), 5000);
    QVERIFY(!comic.opened());
    QVERIFY(!comic.loading());
    QCOMPARE(comic.pageCount(), 0);
    QVERIFY2(comic.errorText().contains(QStringLiteral("不是漫画文件")),
             qPrintable(comic.errorText()));
}

void TestComicBridge::invalidatesPagesWhenFileChanges()
{
    ComicBridge &comic = *ComicBridge::instance();
    comic.open(m_connectionId, kComicPath, QString());
    QTRY_VERIFY_WITH_TIMEOUT(!comic.pageUrl().isEmpty(), 5000);
    const QString before = comic.pageUrl();
    comic.close();

    // 换一版文件（大小与修改时间都变）：旧页缓存必须失效，否则会看到上一版的图
    writeComic(buildZip({{QStringLiteral("p/1.png"), pngOf(Qt::yellow, 32)},
                         {QStringLiteral("p/2.png"), pngOf(Qt::cyan, 32)}}));

    comic.open(m_connectionId, kComicPath, QString());
    QTRY_VERIFY_WITH_TIMEOUT(!comic.pageUrl().isEmpty(), 5000);
    QCOMPARE(comic.pageCount(), 2);
    QVERIFY2(comic.pageUrl() != before, "改了文件却复用了旧页缓存");

    const QImage shown(QUrl(comic.pageUrl()).toLocalFile());
    QCOMPARE(shown.size(), QSize(32, 32));
}

void TestComicBridge::opensLocalCbrAndShowsPage()
{
    // 本地 cbr 走 libarchive 直读路径（不经 RangeSource）：页序、页缓存、进度条都要对
    const QByteArray png = pngOf(Qt::magenta);
    rartest::RarBuilder rar;
    rar.add(QStringLiteral("p/1.png"), png);
    rar.add(QStringLiteral("p/2.png"), pngOf(Qt::darkGreen));
    rar.add(QStringLiteral("p/10.png"), pngOf(Qt::gray));

    const QString relative = QStringLiteral("漫画/短篇.cbr");
    QFile file(m_root.filePath(relative));
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    file.write(rar.build());
    file.close();

    ComicBridge &comic = *ComicBridge::instance();
    comic.open(m_connectionId, QStringLiteral("/漫画/短篇.cbr"), QString());
    QTRY_VERIFY_WITH_TIMEOUT(comic.opened() || !comic.errorText().isEmpty(), 5000);
    QVERIFY2(comic.errorText().isEmpty(), qPrintable(comic.errorText()));

    // 页序仍是自然排序：1 / 2 / 10
    QCOMPARE(comic.pageCount(), 3);
    QCOMPARE(comic.pageName(), QStringLiteral("p/1.png"));
    // 本地文件不用整包落地，进度条不该出现
    QCOMPARE(comic.downloadProgress(), -1.0);

    QTRY_VERIFY_WITH_TIMEOUT(!comic.pageUrl().isEmpty(), 5000);
    const QString local = QUrl(comic.pageUrl()).toLocalFile();
    QVERIFY(QFileInfo::exists(local));
    const QImage shown(local);
    QVERIFY2(!shown.isNull(), "缓存的页必须是真图片");
    QCOMPARE(shown.size(), QSize(24, 24));
}

void TestComicBridge::prefetchesNeighborPages()
{
    // 预取窗口：打开后当前页两侧各 3 页自己解，不用 QML 逐个 ensurePage；
    // 但窗口之外的页不许提前解 —— 厚本从第一页一路解到最后一页会把弱网压死
    rartest::RarBuilder rar;
    for (int i = 1; i <= 7; ++i) {
        rar.add(QStringLiteral("p/%1.png").arg(i),
                pngOf(QColor::fromHsv((i * 40) % 360, 200, 200)));
    }

    const QString relative = QStringLiteral("漫画/预取.cbr");
    QFile file(m_root.filePath(relative));
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    file.write(rar.build());
    file.close();

    ComicBridge &comic = *ComicBridge::instance();
    comic.open(m_connectionId, QStringLiteral("/漫画/预取.cbr"), QString());
    QTRY_VERIFY_WITH_TIMEOUT(comic.opened() || !comic.errorText().isEmpty(), 5000);
    QVERIFY2(comic.errorText().isEmpty(), qPrintable(comic.errorText()));
    QCOMPARE(comic.pageCount(), 7);

    // 第 0 页的两侧 1 / 2 / 3：没人 ensurePage 过，得靠预取自己解出来
    QTRY_VERIFY_WITH_TIMEOUT(!comic.pageUrlAt(1).isEmpty() && !comic.pageUrlAt(2).isEmpty()
                                 && !comic.pageUrlAt(3).isEmpty(),
                             5000);
    QVERIFY2(comic.pageUrlAt(6).isEmpty(), "预取越界了：窗口外的页不该提前解");

    // 往后翻一页：窗口跟着走，4 号页成了新的「后一页」
    comic.nextPage();
    QTRY_COMPARE_WITH_TIMEOUT(comic.pageIndex(), 1, 5000);
    QTRY_VERIFY_WITH_TIMEOUT(!comic.pageUrlAt(4).isEmpty(), 5000);
}

void TestComicBridge::suggestsNextComicWhenFinished()
{
    // 同目录按名排序：第1话.cbz → 第2话.cbz（夹着的封面图不该被推上来）
    QVERIFY(QDir(m_root.path()).mkpath(QStringLiteral("漫画/连载")));
    const auto writeArchive = [this](const QString &name) {
        QFile file(m_root.filePath(QStringLiteral("漫画/连载/%1").arg(name)));
        QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
        file.write(buildZip({{QStringLiteral("p/1.png"), pngOf(Qt::yellow)}}));
        file.close();
    };
    writeArchive(QStringLiteral("第1话.cbz"));
    writeArchive(QStringLiteral("第2话.cbz"));
    QFile cover(m_root.filePath(QStringLiteral("漫画/连载/封面.jpg")));
    QVERIFY(cover.open(QIODevice::WriteOnly | QIODevice::Truncate));
    cover.write(pngOf(Qt::white));
    cover.close();

    const QString firstPath = QStringLiteral("/漫画/连载/第1话.cbz");
    ComicBridge &comic = *ComicBridge::instance();
    comic.open(m_connectionId, firstPath, QString());
    QTRY_VERIFY_WITH_TIMEOUT(comic.opened() || !comic.errorText().isEmpty(), 5000);
    QVERIFY2(comic.errorText().isEmpty(), qPrintable(comic.errorText()));
    QTRY_VERIFY_WITH_TIMEOUT(!comic.pageUrl().isEmpty(), 5000);

    // 没翻到底之前不该有候选
    QVERIFY(comic.nextSuggestion().isEmpty());

    comic.setAtBookEnd(true);
    QTRY_VERIFY_WITH_TIMEOUT(!comic.nextSuggestion().isEmpty(), 5000);
    QCOMPARE(comic.nextSuggestion().value(QStringLiteral("name")).toString(),
             QStringLiteral("第2话.cbz"));
    QCOMPARE(comic.nextSuggestion().value(QStringLiteral("path")).toString(),
             QStringLiteral("/漫画/连载/第2话.cbz"));
    QCOMPARE(comic.nextSuggestion().value(QStringLiteral("connectionId")).toString(),
             m_connectionId);

    // 读到底 = 已读完：进度落 finished，百分比恒定 100%
    // （双页最后一屏的 pageIndex 停在倒数第二页，靠页码算会漏成 99%）
    ProgressRecord record;
    QTRY_VERIFY_WITH_TIMEOUT(
        ProgressRepository::instance().find(m_connectionId, firstPath, &record), 5000);
    QVERIFY(record.finished);
    QCOMPARE(record.percent, 1.0);
    QCOMPARE(comic.percent(), 1.0);

    // 往回翻：提示条撤销，且「已收起」复位（下次读到底还能再推一次）
    comic.setAtBookEnd(false);
    QVERIFY(comic.nextSuggestion().isEmpty());

    // 点叉收起之后，本次读到底不再重复弹
    comic.setAtBookEnd(true);
    QTRY_VERIFY_WITH_TIMEOUT(!comic.nextSuggestion().isEmpty(), 5000);
    comic.dismissNextSuggestion();
    QVERIFY(comic.nextSuggestion().isEmpty());

    // 离开末尾再回来：重新可以推荐
    comic.setAtBookEnd(false);
    comic.setAtBookEnd(true);
    QTRY_VERIFY_WITH_TIMEOUT(!comic.nextSuggestion().isEmpty(), 5000);

    // 点「打开」真的换到下一卷
    comic.openNextSuggestion();
    QTRY_VERIFY_WITH_TIMEOUT(comic.opened() && !comic.loading(), 8000);
    QCOMPARE(comic.title(), QStringLiteral("第2话.cbz"));
    QVERIFY2(comic.nextSuggestion().isEmpty(), "换书之后旧候选必须撤掉");
}

void TestComicBridge::storesPageListOnOpen()
{
    // 别依赖别的用例留下的文件内容：自己写一本页数已知的
    writeComic(buildZip({{QStringLiteral("p/1.png"), pngOf(Qt::red)},
                         {QStringLiteral("p/2.png"), pngOf(Qt::green)},
                         {QStringLiteral("p/10.png"), pngOf(Qt::blue)}}));

    ComicBridge &comic = *ComicBridge::instance();
    comic.open(m_connectionId, kComicPath, QString());
    QTRY_VERIFY_WITH_TIMEOUT(comic.opened(), 5000);
    QTRY_VERIFY_WITH_TIMEOUT(!comic.pageUrl().isEmpty(), 5000);

    // 页名清单必须落库：下次打开靠它秒开、离线靠它进降级阅读
    const QFileInfo file(m_root.filePath(QStringLiteral("漫画/第一卷.cbz")));
    ComicPageList stored;
    QVERIFY(ComicPageStore::find(m_connectionId, kComicPath, &stored));
    QCOMPARE(stored.pages,
             (QStringList{QStringLiteral("p/1.png"), QStringLiteral("p/2.png"),
                          QStringLiteral("p/10.png")}));
    QVERIFY(ComicPageStore::load(m_connectionId, kComicPath, file.size(),
                                 file.lastModified().toMSecsSinceEpoch(), &stored));

    // 文件换了（大小/时间变了）：指纹失配，清单必须作废，否则会按旧页序乱翻
    QVERIFY(AppDatabase::instance().execute(
        QStringLiteral("UPDATE comicPages SET fileSize = fileSize + 1")));
    QVERIFY(!ComicPageStore::load(m_connectionId, kComicPath, file.size(),
                                  file.lastModified().toMSecsSinceEpoch(), &stored));
}

void TestComicBridge::opensImageEpubInSpineOrder()
{
    ComicBridge &comic = *ComicBridge::instance();
    comic.open(m_connectionId, kImageEpubPath, QString());

    QTRY_VERIFY_WITH_TIMEOUT(comic.opened() || !comic.errorText().isEmpty(), 8000);
    QVERIFY2(comic.errorText().isEmpty(), qPrintable(comic.errorText()));

    // 页序取自 OPF 的 spine（002 → 001 → 003），不是条目名排序（001 打头）
    QCOMPARE(comic.pageCount(), 3);
    QCOMPARE(comic.pageName(), QStringLiteral("OEBPS/pages/002.png"));

    QTRY_VERIFY_WITH_TIMEOUT(!comic.pageUrl().isEmpty(), 5000);
    const QImage shown(QUrl(comic.pageUrl()).toLocalFile());
    QVERIFY(!shown.isNull());
    QCOMPARE(shown.pixelColor(1, 1), QColor(Qt::green)); // 002 页是绿色

    comic.nextPage();
    QTRY_COMPARE_WITH_TIMEOUT(comic.pageIndex(), 1, 5000);
    QCOMPARE(comic.pageName(), QStringLiteral("OEBPS/pages/001.png"));
}

void TestComicBridge::rejectsTextEpubAsComic()
{
    ComicBridge &comic = *ComicBridge::instance();
    comic.open(m_connectionId, kTextEpubPath, QString());

    QTRY_VERIFY_WITH_TIMEOUT(!comic.errorText().isEmpty(), 8000);
    QVERIFY(!comic.opened());
    // 说清楚该换哪个阅读器，而不是「压缩包里没有图片」
    QVERIFY2(comic.errorText().contains(QStringLiteral("不是图集")), qPrintable(comic.errorText()));
}

void TestComicBridge::opensOfflineFromPageCache()
{
    // 9 页：预取窗口（±3）只覆盖前 4 页，第 9 页注定没缓存，用它验证「缺口」表现
    QList<QPair<QString, QByteArray>> files;
    for (int i = 1; i <= 9; ++i) {
        files.append({QStringLiteral("p/%1.png").arg(i), pngOf(QColor::fromHsv(i * 30, 200, 200))});
    }
    writeComic(buildZip(files));

    ComicBridge &comic = *ComicBridge::instance();
    comic.open(m_connectionId, kComicPath, QString());
    QTRY_VERIFY_WITH_TIMEOUT(comic.opened(), 5000);
    QTRY_VERIFY_WITH_TIMEOUT(!comic.pageUrl().isEmpty(), 5000);
    const QString firstPage = comic.pageUrl();
    comic.close();
    QVERIFY(!comic.offline());

    // 源够不着了（文件被移走 / 盘掉线）：页名清单 + 页缓存还在，应当进降级阅读
    const QString real = m_root.filePath(QStringLiteral("漫画/第一卷.cbz"));
    QVERIFY(QFile::rename(real, real + QStringLiteral(".moved")));

    comic.open(m_connectionId, kComicPath, QString());
    QTRY_VERIFY_WITH_TIMEOUT(comic.opened() || !comic.errorText().isEmpty(), 5000);
    QVERIFY2(comic.errorText().isEmpty(), qPrintable(comic.errorText()));
    QVERIFY(comic.offline());

    // 页数来自清单：能翻、能看读过的页
    QCOMPARE(comic.pageCount(), 9);
    QTRY_VERIFY_WITH_TIMEOUT(!comic.pageUrl().isEmpty(), 5000);
    QCOMPARE(comic.pageUrl(), firstPage);

    // 没缓存的页给一句明确的话，而不是一直转圈
    comic.goToPage(8);
    QTRY_COMPARE_WITH_TIMEOUT(comic.pageIndex(), 8, 2000);
    QVERIFY(comic.pageUrl().isEmpty());
    QVERIFY2(!comic.pageLoading(), "离线时不该停在 loading 态");
    QVERIFY2(comic.statusText().contains(QStringLiteral("离线")), qPrintable(comic.statusText()));
    // 翻不到的内容不许写进度：续读点还该停在打开时那一页
    ProgressRecord record;
    QVERIFY(ProgressRepository::instance().find(m_connectionId, kComicPath, &record));
    QCOMPARE(record.progress.value(QStringLiteral("page")).toInt(), 0);

    // 读到底也别盖章「已读完」：离线只看得到恰好缓存的页，未必是全书结尾
    comic.setAtBookEnd(true);
    QVERIFY(ProgressRepository::instance().find(m_connectionId, kComicPath, &record));
    QVERIFY2(!record.finished, "离线翻到末尾不等于读完全书");
    QVERIFY(comic.nextSuggestion().isEmpty());

    QVERIFY(QFile::rename(real + QStringLiteral(".moved"), real));
}

void TestComicBridge::suggestsNextImageEpubWhenFinished()
{
    // 图集 epub 要能和 cbz 一样互推。
    // 浏览页把 .epub 一律归成小说，光看扩展名推不出来 —— 这里验证的是
    // 「打开时把判定结论写进 `ComicDetector`，读到底后靠它认出下一本图集」这条链。
    QVERIFY(QDir(m_root.path()).mkpath(QStringLiteral("漫画/图集连载")));
    const auto writeEpub = [this](const QString &name, const QByteArray &payload) {
        QFile file(m_root.filePath(QStringLiteral("漫画/图集连载/%1").arg(name)));
        QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
        file.write(payload);
        file.close();
    };
    // 用数字前缀固定顺序，避开中文排序的歧义
    writeEpub(QStringLiteral("01-第1卷.epub"), imageEpub());
    writeEpub(QStringLiteral("02-第2卷.epub"), imageEpub());
    writeEpub(QStringLiteral("03-番外.epub"), textEpub()); // 文字书不该被推上来

    ComicBridge &comic = *ComicBridge::instance();
    comic.open(m_connectionId, QStringLiteral("/漫画/图集连载/01-第1卷.epub"), QString());
    QTRY_VERIFY_WITH_TIMEOUT(comic.opened() || !comic.errorText().isEmpty(), 5000);
    QVERIFY2(comic.errorText().isEmpty(), qPrintable(comic.errorText()));
    QTRY_VERIFY_WITH_TIMEOUT(!comic.pageUrl().isEmpty(), 5000);

    QVERIFY(comic.nextSuggestion().isEmpty());

    comic.setAtBookEnd(true);
    QTRY_VERIFY_WITH_TIMEOUT(!comic.nextSuggestion().isEmpty(), 5000);
    // 关键断言：图集 epub 之间的互推成立
    QCOMPARE(comic.nextSuggestion().value(QStringLiteral("name")).toString(),
             QStringLiteral("02-第2卷.epub"));
    QCOMPARE(comic.nextSuggestion().value(QStringLiteral("path")).toString(),
             QStringLiteral("/漫画/图集连载/02-第2卷.epub"));
}

QTEST_MAIN(TestComicBridge)
#include "tst_comicbridge.moc"
