// ComicBridge：漫画阅读器的真实链路（§6 PC-207）
//
// 全部走真实路径：真实 cbz 落盘 → LocalAdapter → AdapterRangeSource → 解包 → 页缓存落盘，
// 进度写真实 sqlite。不 mock 适配器，否则「页码存没存进去、缓存键对不对」这类
// 只有真跑才现形的问题会被漏掉。

#include "RarTestBuilder.h"

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
    void rejectsArchiveWithoutImages();
    void invalidatesPagesWhenFileChanges();
    void opensLocalCbrAndShowsPage();

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
    QCOMPARE(AppSettings::instance().value(QStringLiteral("reader.comic.rtl")).toBool(), false);
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

void TestComicBridge::rejectsArchiveWithoutImages()
{
    ComicBridge &comic = *ComicBridge::instance();
    comic.open(m_connectionId, kNotComicPath, QString());

    QTRY_VERIFY_WITH_TIMEOUT(!comic.errorText().isEmpty(), 5000);
    QVERIFY(!comic.opened());
    QCOMPARE(comic.pageCount(), 0);
    QVERIFY2(comic.errorText().contains(QStringLiteral("不是漫画")), qPrintable(comic.errorText()));
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

QTEST_MAIN(TestComicBridge)
#include "tst_comicbridge.moc"
