// NovelBridge 的 epub / txt 接入（§5.1 PC-206、§13 离线阅读）
//
// 覆盖七件事，全部走真实链路（本地适配器 + 真实 sqlite + 磁盘上的书）：
//   · 打开 epub：目录来自 OPF/NAV，书名取 OPF 而不是文件名
//   · 按章加载：段落流直接进 `paragraphs`，上一章下一章可用
//   · 锚点：epub 用「章号 + 段落下标」落库（不写字节偏移），再次打开能回到同一段
//   · 封面：CoverService 从 epub 里取出封面并落盘，第二次同步命中
//   · 离线：文件够不着时，靠分章索引 + 章节落盘缓存继续读读过的章
//   · epub 离线：目录来自 `EpubMetaStore` 快照，正文只放缓存过的章
//   · 偏好：设置页改 `reader.*` 键后桥接立即反映（阅读器与设置页共用一份）

#include "core/database/AppDatabase.h"
#include "core/history/ProgressRepository.h"
#include "core/novel/EpubMetaStore.h"
#include "core/novel/NovelChapterCache.h"
#include "core/preferences/AppSettings.h"
#include "core/storage/StorageAdapterFactory.h"
#include "core/utils/AppPaths.h"
#include "features/connections/ConnectionStore.h"
#include "features/cover/CoverService.h"
#include "features/reading/BundledFonts.h"
#include "features/reading/ComicBridge.h"
#include "features/reading/NovelBridge.h"

#include <QBuffer>
#include <QColor>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImage>
#include <QSignalSpy>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QScopeGuard>
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

/// 只写 stored 条目的最小 zip：桥接测试关心的是「章节 → 段落」，不关心压缩
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

// 样本一律用普通字符串字面量：moc 的 lexer 遇到 raw string 会把整个文件当「无相关类」
const QByteArray kContainerXml = QByteArrayLiteral(
    "<?xml version='1.0' encoding='utf-8'?>"
    "<container version='1.0' xmlns='urn:oasis:names:tc:opendocument:xmlns:container'>"
    "<rootfiles><rootfile full-path='OEBPS/content.opf' "
    "media-type='application/oebps-package+xml'/></rootfiles></container>");

const QByteArray kOpf = QByteArrayLiteral(
    "<?xml version='1.0' encoding='utf-8'?>"
    "<package xmlns='http://www.idpf.org/2007/opf' version='3.0' unique-identifier='uid'>"
    "<metadata xmlns:dc='http://purl.org/dc/elements/1.1/'>"
    "<dc:title>桥接测试书</dc:title><dc:creator>某作者</dc:creator>"
    "<dc:language>zh-CN</dc:language>"
    "</metadata>"
    "<manifest>"
    "<item id='nav' href='nav.xhtml' media-type='application/xhtml+xml' properties='nav'/>"
    "<item id='cover' href='images/cover.png' media-type='image/png' properties='cover-image'/>"
    "<item id='c1' href='text/ch1.xhtml' media-type='application/xhtml+xml'/>"
    "<item id='c2' href='text/ch2.xhtml' media-type='application/xhtml+xml'/>"
    "</manifest>"
    "<spine><itemref idref='c1'/><itemref idref='c2'/></spine>"
    "</package>");

const QByteArray kNav = QByteArrayLiteral(
    "<?xml version='1.0' encoding='utf-8'?>"
    "<html xmlns='http://www.w3.org/1999/xhtml' xmlns:epub='http://www.idpf.org/2007/ops'>"
    "<head><title>目录</title></head><body><nav epub:type='toc'><ol>"
    "<li><a href='text/ch1.xhtml'>第一章 起风了</a></li>"
    "<li><a href='text/ch2.xhtml'>第二章 雨停了</a></li>"
    "</ol></nav></body></html>");

const QByteArray kChapter1 =
    QByteArrayLiteral("<html xmlns='http://www.w3.org/1999/xhtml'><body>"
                      "<h1>第一章 起风了</h1><p>第一段</p><p>第二段</p><p>第三段</p>"
                      "</body></html>");

const QByteArray kChapter2 = QByteArrayLiteral("<html xmlns='http://www.w3.org/1999/xhtml'><body>"
                                               "<p>第二章甲</p><p>第二章乙</p>"
                                               "</body></html>");

/// 封面得是真图：CoverService 要 QImage 解码后缩放写盘
QByteArray coverPng()
{
    QImage image(90, 120, QImage::Format_ARGB32);
    image.fill(QColor(20, 120, 140));
    QByteArray bytes;
    QBuffer buffer(&bytes);
    buffer.open(QIODevice::WriteOnly);
    image.save(&buffer, "PNG");
    return bytes;
}

QByteArray sampleEpub()
{
    return buildZip({
        {QStringLiteral("mimetype"), QByteArray("application/epub+zip")},
        {QStringLiteral("META-INF/container.xml"), kContainerXml},
        {QStringLiteral("OEBPS/content.opf"), kOpf},
        {QStringLiteral("OEBPS/nav.xhtml"), kNav},
        {QStringLiteral("OEBPS/text/ch1.xhtml"), kChapter1},
        {QStringLiteral("OEBPS/text/ch2.xhtml"), kChapter2},
        {QStringLiteral("OEBPS/images/cover.png"), coverPng()},
    });
}

/// 三章 txt：离线用例要靠它验证「索引 + 章节缓存」能顶住文件消失。
/// 正文必须撑够长度 —— 分章规则要求「文件长度 / 章节数 ≥ 64 字节」，
/// 三章几十字节的样本会被判成假命中、退回「整本单章」
QByteArray sampleTxt()
{
    QByteArray text;
    text += "第1章 开端\n";
    text +=
        "雨停了，他把伞收起来，站在书店的屋檐下看街上的人来人往，忽然觉得这个下午长得没有尽头。\n";
    text +=
        "书架上的那本旧书还在原来的位置，翻开第一页，字迹已经淡了，可他还是认得出那是谁写的。\n";
    text += "第2章 转折\n";
    text +=
        "第二天的报纸送到了门口，他看了很久，最终把那一版折起来，塞进了抽屉最里面，谁也没提。\n";
    text += "第3章 收束\n";
    text +=
        "多年以后他重新走过那条街，屋檐还在，伞却早就丢了，只剩下雨声和记忆里那句没说完的话。\n";
    return text;
}

// 必须是 QString：QLatin1String 会把 UTF-8 字节按 Latin-1 解释，中文路径直接找不到文件
/// 图集 epub：spine 直接指向整页图片（漫画打包成 epub 的常见形态）
const QByteArray kImageOpf = QByteArrayLiteral(
    "<?xml version='1.0' encoding='utf-8'?>"
    "<package xmlns='http://www.idpf.org/2007/opf' version='3.0' unique-identifier='uid'>"
    "<metadata xmlns:dc='http://purl.org/dc/elements/1.1/'>"
    "<dc:title>图集测试书</dc:title><dc:language>zh-CN</dc:language></metadata>"
    "<manifest>"
    "<item id='p1' href='pages/001.png' media-type='image/png'/>"
    "<item id='p2' href='pages/002.png' media-type='image/png'/>"
    "<item id='p3' href='pages/003.png' media-type='image/png'/>"
    "</manifest>"
    // spine 顺序刻意与条目名不同：转交后页序要跟着 spine 走
    "<spine><itemref idref='p2'/><itemref idref='p1'/><itemref idref='p3'/></spine>"
    "</package>");

QByteArray sampleImageEpub()
{
    const QByteArray page = coverPng();
    return buildZip({
        {QStringLiteral("mimetype"), QByteArray("application/epub+zip")},
        {QStringLiteral("META-INF/container.xml"), kContainerXml},
        {QStringLiteral("OEBPS/content.opf"), kImageOpf},
        {QStringLiteral("OEBPS/pages/001.png"), page},
        {QStringLiteral("OEBPS/pages/002.png"), page},
        {QStringLiteral("OEBPS/pages/003.png"), page},
    });
}

/// 普通小说 + 插图：一章文字中间夹一张图（`../images/` 相对章节文件，不相对 OPF）
const QByteArray kIllustratedOpf = QByteArrayLiteral(
    "<?xml version='1.0' encoding='utf-8'?>"
    "<package xmlns='http://www.idpf.org/2007/opf' version='3.0' unique-identifier='uid'>"
    "<metadata xmlns:dc='http://purl.org/dc/elements/1.1/'>"
    "<dc:title>插图测试书</dc:title><dc:language>zh-CN</dc:language></metadata>"
    "<manifest>"
    "<item id='ch1' href='text/ch1.xhtml' media-type='application/xhtml+xml'/>"
    "<item id='pic' href='images/pic.png' media-type='image/png'/>"
    "</manifest>"
    "<spine><itemref idref='ch1'/></spine>"
    "</package>");

const QByteArray kIllustratedChapter =
    QByteArrayLiteral("<html xmlns='http://www.w3.org/1999/xhtml'><body>"
                      "<p>前一段</p><p><img src='../images/pic.png' alt='插图'/></p><p>后一段</p>"
                      "</body></html>");

QByteArray sampleIllustratedEpub()
{
    return buildZip({
        {QStringLiteral("mimetype"), QByteArray("application/epub+zip")},
        {QStringLiteral("META-INF/container.xml"), kContainerXml},
        {QStringLiteral("OEBPS/content.opf"), kIllustratedOpf},
        {QStringLiteral("OEBPS/text/ch1.xhtml"), kIllustratedChapter},
        {QStringLiteral("OEBPS/images/pic.png"), coverPng()},
    });
}

/// 单段长文：一段话就占好几页，专门用来验证「段内偏移」锚点
const QByteArray kLongOpf = QByteArrayLiteral(
    "<?xml version='1.0' encoding='utf-8'?>"
    "<package xmlns='http://www.idpf.org/2007/opf' version='3.0' unique-identifier='uid'>"
    "<metadata xmlns:dc='http://purl.org/dc/elements/1.1/'>"
    "<dc:title>长段测试书</dc:title><dc:language>zh-CN</dc:language></metadata>"
    "<manifest>"
    "<item id='ch1' href='text/long.xhtml' media-type='application/xhtml+xml'/>"
    "</manifest>"
    "<spine><itemref idref='ch1'/></spine>"
    "</package>");

QByteArray longChapter()
{
    QString text = QStringLiteral("第一章 长夜");
    QStringList sentences;
    for (int i = 0; i < 60; ++i) {
        sentences.append(QStringLiteral("他在雨里走了很久，街灯把水洼照成一片一片的碎银。"));
    }
    return QByteArrayLiteral("<html xmlns='http://www.w3.org/1999/xhtml'><body><h1>")
        + text.toUtf8() + QByteArrayLiteral("</h1><p>") + sentences.join(QString()).toUtf8()
        + QByteArrayLiteral("</p><p>末尾一段。</p></body></html>");
}

QByteArray sampleLongChapterEpub()
{
    return buildZip({
        {QStringLiteral("mimetype"), QByteArray("application/epub+zip")},
        {QStringLiteral("META-INF/container.xml"), kContainerXml},
        {QStringLiteral("OEBPS/content.opf"), kLongOpf},
        {QStringLiteral("OEBPS/text/long.xhtml"), longChapter()},
    });
}

const QString kBookPath = QStringLiteral("/书架/桥接测试.epub");
const QString kImageBookPath = QStringLiteral("/书架/图集测试.epub");
const QString kIllustratedPath = QStringLiteral("/书架/插图测试.epub");
const QString kLongPath = QStringLiteral("/书架/长段测试.epub");
const QString kTxtPath = QStringLiteral("/书架/桥接测试.txt");

} // namespace

class TestNovelBridge : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void init();
    void cleanupTestCase();

    void opensEpubAndListsToc();
    void loadsChapterParagraphs();
    void storesChapterParagraphAnchor();
    void resumesToSavedParagraph();
    void generatesEpubCover();
    void validatesCoverCacheByFingerprint();
    void prefetchesAdjacentChapter();
    void cachesChapterOnDisk();
    void opensOfflineFromCachedChapters();
    void refusesOfflineWithoutCache();
    void opensOfflineEpubFromSnapshot();
    void refusesOfflineEpubWithoutSnapshot();
    void handsImageCollectionToComic();
    void keepsIllustrationSnapshotOnDisk();
    void showsCachedIllustrationOffline();
    void paginatesChapterIntoPages();
    void resumesInsideLongParagraph();
    void remembersSerifPreference();
    void marksChapterHeadingForDisplay();
    void prefersBundledSerif();
    void suggestsNextBookWhenFinished();
    void syncsPreferencesFromSettingsPage();

private:
    QTemporaryDir m_dbDir;
    QTemporaryDir m_root;
    QString m_connectionId = QStringLiteral("conn-novel-test");
};

void TestNovelBridge::initTestCase()
{
    QCoreApplication::setApplicationName(
        QStringLiteral("MyHubNovelBridgeTest-%1").arg(QCoreApplication::applicationPid()));
    QStandardPaths::setTestModeEnabled(true);
    AppPaths::initializeAll();
    AppSettings::instance().initialize();

    QVERIFY(m_dbDir.isValid());
    QVERIFY(AppDatabase::instance().open(m_dbDir.filePath(QStringLiteral("myhub.sqlite"))));

    // 真实 epub 落盘：桥接走的是 LocalAdapter → AdapterRangeSource，不碰内存源
    QVERIFY(m_root.isValid());
    QVERIFY(QDir(m_root.path()).mkpath(QStringLiteral("书架")));
    QFile book(m_root.filePath(QStringLiteral("书架/桥接测试.epub")));
    QVERIFY(book.open(QIODevice::WriteOnly));
    QCOMPARE(book.write(sampleEpub()), qint64(sampleEpub().size()));
    book.close();

    QFile album(m_root.filePath(QStringLiteral("书架/图集测试.epub")));
    QVERIFY(album.open(QIODevice::WriteOnly));
    QCOMPARE(album.write(sampleImageEpub()), qint64(sampleImageEpub().size()));
    album.close();

    QFile illustrated(m_root.filePath(QStringLiteral("书架/插图测试.epub")));
    QVERIFY(illustrated.open(QIODevice::WriteOnly));
    QCOMPARE(illustrated.write(sampleIllustratedEpub()), qint64(sampleIllustratedEpub().size()));
    illustrated.close();

    QFile longChapterBook(m_root.filePath(QStringLiteral("书架/长段测试.epub")));
    QVERIFY(longChapterBook.open(QIODevice::WriteOnly));
    QCOMPARE(longChapterBook.write(sampleLongChapterEpub()),
             qint64(sampleLongChapterEpub().size()));
    longChapterBook.close();

    QFile novel(m_root.filePath(QStringLiteral("书架/桥接测试.txt")));
    QVERIFY(novel.open(QIODevice::WriteOnly));
    QCOMPARE(novel.write(sampleTxt()), qint64(sampleTxt().size()));
    novel.close();

    ConnectionRecord record;
    record.id = m_connectionId;
    record.name = QStringLiteral("临时书架");
    record.type = ConnectionType::Local;
    record.config.insert(QStringLiteral("path"), m_root.path());
    QVERIFY(ConnectionStore::instance().upsert(record));
}

void TestNovelBridge::init()
{
    // 单例跨用例复用：先关上一本，再清进度与章节缓存，避免上一例的状态影响下一例
    NovelBridge::instance()->close();
    ComicBridge::instance()->close();
    QVERIFY(AppDatabase::instance().execute(QStringLiteral("DELETE FROM readingProgress")));
    QVERIFY(AppDatabase::instance().execute(QStringLiteral("DELETE FROM novelChapter")));
    // 目录快照同理：否则上一例打开 epub 时写的快照会让「没有快照」这一例假失败
    QVERIFY(AppDatabase::instance().execute(QStringLiteral("DELETE FROM epubMeta")));
}

void TestNovelBridge::cleanupTestCase()
{
    NovelBridge::instance()->close();
    ComicBridge::instance()->close();
    AppDatabase::instance().close();
}

void TestNovelBridge::opensEpubAndListsToc()
{
    NovelBridge &novel = *NovelBridge::instance();
    novel.open(m_connectionId, kBookPath, QString());

    QTRY_VERIFY_WITH_TIMEOUT(novel.opened() || !novel.errorText().isEmpty(), 5000);
    QVERIFY2(novel.errorText().isEmpty(), qPrintable(novel.errorText()));

    // OPF 里的书名优先于文件名（文件名是「桥接测试.epub」）
    QCOMPARE(novel.title(), QStringLiteral("桥接测试书"));
    QCOMPARE(novel.chapterCount(), 2);

    const QVariantList toc = novel.chapters();
    QCOMPARE(toc.size(), 2);
    QCOMPARE(toc.at(0).toMap().value(QStringLiteral("title")).toString(),
             QStringLiteral("第一章 起风了"));
    QCOMPARE(toc.at(1).toMap().value(QStringLiteral("title")).toString(),
             QStringLiteral("第二章 雨停了"));
}

void TestNovelBridge::loadsChapterParagraphs()
{
    NovelBridge &novel = *NovelBridge::instance();
    novel.open(m_connectionId, kBookPath, QString());

    QTRY_VERIFY_WITH_TIMEOUT(novel.opened(), 5000);
    QTRY_VERIFY_WITH_TIMEOUT(!novel.paragraphs().isEmpty(), 5000);
    QCOMPARE(novel.chapterIndex(), 0);
    QCOMPARE(novel.chapterTitle(), QStringLiteral("第一章 起风了"));
    QVERIFY(novel.paragraphs().join(QLatin1Char('|')).contains(QStringLiteral("第三段")));

    novel.nextChapter();
    QTRY_COMPARE_WITH_TIMEOUT(novel.chapterIndex(), 1, 5000);
    QTRY_VERIFY_WITH_TIMEOUT(
        novel.paragraphs().join(QLatin1Char('|')).contains(QStringLiteral("第二章乙")), 5000);
    QCOMPARE(novel.chapterTitle(), QStringLiteral("第二章 雨停了"));

    // 末章再往后不越界，也不会把当前章清掉
    novel.nextChapter();
    QTest::qWait(50);
    QCOMPARE(novel.chapterIndex(), 1);
}

void TestNovelBridge::storesChapterParagraphAnchor()
{
    NovelBridge &novel = *NovelBridge::instance();
    novel.open(m_connectionId, kBookPath, QString());

    QTRY_VERIFY_WITH_TIMEOUT(novel.paragraphs().size() >= 3, 5000);
    novel.reportParagraph(2);
    QTRY_VERIFY_WITH_TIMEOUT(novel.percent() > 0.0, 5000);

    ProgressRecord record;
    QVERIFY(ProgressRepository::instance().find(m_connectionId, kBookPath, &record));
    QCOMPARE(record.progress.value(QStringLiteral("chapter")).toInt(), 0);
    QCOMPARE(record.progress.value(QStringLiteral("paragraph")).toInt(), 2);
    QCOMPARE(record.progress.value(QStringLiteral("chapterTitle")).toString(),
             QStringLiteral("第一章 起风了"));
    // epub 没有连续字节坐标：不得写入 offset，否则会被误当成 txt 的字节锚点
    QVERIFY(!record.progress.contains(QStringLiteral("offset")));
    QVERIFY(record.percent > 0.0);
    QVERIFY(record.percent < 1.0);
}

void TestNovelBridge::resumesToSavedParagraph()
{
    // 直接写一条「第 2 章第 2 段」的记录，模拟上次读到那里
    ProgressRecord saved;
    saved.connectionId = m_connectionId;
    saved.path = kBookPath;
    saved.mediaType = QStringLiteral("novel");
    saved.title = QStringLiteral("桥接测试书");
    saved.progress.insert(QStringLiteral("chapter"), 1);
    saved.progress.insert(QStringLiteral("paragraph"), 1);
    saved.progress.insert(QStringLiteral("chapterTitle"), QStringLiteral("第二章 雨停了"));
    saved.percent = 0.75;
    QVERIFY(ProgressRepository::instance().upsert(saved));

    NovelBridge &novel = *NovelBridge::instance();
    novel.open(m_connectionId, kBookPath, QString());

    QTRY_COMPARE_WITH_TIMEOUT(novel.chapterIndex(), 1, 5000);
    QTRY_COMPARE_WITH_TIMEOUT(novel.anchorParagraph(), 1, 5000);
    QCOMPARE(novel.chapterTitle(), QStringLiteral("第二章 雨停了"));
}

void TestNovelBridge::generatesEpubCover()
{
    CoverService &covers = CoverService::instance();
    QVERIFY(covers.cachedCover(m_connectionId, kBookPath).isEmpty());

    QSignalSpy ready(&covers, &CoverService::coverReady);
    QSignalSpy failed(&covers, &CoverService::coverFailed);
    // 不带指纹请求：CoverService 自己要 stat 补齐，否则缓存 meta 永远对不上
    covers.requestCover(m_connectionId, kBookPath);

    QTRY_VERIFY_WITH_TIMEOUT(ready.count() + failed.count() > 0, 15000);
    QCOMPARE(failed.count(), 0);

    const QString url = covers.cachedCover(m_connectionId, kBookPath);
    QVERIFY(!url.isEmpty());
    QCOMPARE(ready.first().at(1).toString(), url);

    QImage image;
    QVERIFY(image.load(QUrl(url).toLocalFile()));
    // 小图不放大：90x120 原尺寸落盘
    QCOMPARE(image.size(), QSize(90, 120));
}

void TestNovelBridge::validatesCoverCacheByFingerprint()
{
    CoverService &covers = CoverService::instance();

    // 不依赖用例顺序：缓存里还没有就先让它自己画一张（这是「没给指纹」的正常路径）
    if (covers.cachedCover(m_connectionId, kBookPath).isEmpty()) {
        QSignalSpy warm(&covers, &CoverService::coverReady);
        covers.requestCover(m_connectionId, kBookPath);
        QTRY_VERIFY_WITH_TIMEOUT(warm.count() > 0, 15000);
    }

    // 按真实文件的指纹校验：命中就不该再发请求
    const QFileInfo info(m_root.filePath(QStringLiteral("书架/桥接测试.epub")));
    const qint64 size = info.size();
    const qint64 modSecs = info.lastModified().toSecsSinceEpoch();
    QVERIFY(size > 0);
    QVERIFY(modSecs > 0);

    QVERIFY(!covers.cachedCover(m_connectionId, kBookPath, size, modSecs).isEmpty());

    // 文件被换过（大小或修改时间变了）→ 旧图不可信，同步查缓存必须落空，逼调用方重取
    QVERIFY(covers.cachedCover(m_connectionId, kBookPath, size + 1, modSecs).isEmpty());
    QVERIFY(covers.cachedCover(m_connectionId, kBookPath, size, modSecs + 5).isEmpty());

    // 重取时上游传的还是旧指纹：不能拿它当真实长度去读远程，必须先 stat 再画
    QSignalSpy ready(&covers, &CoverService::coverReady);
    QSignalSpy failed(&covers, &CoverService::coverFailed);
    covers.requestCover(m_connectionId, kBookPath, size + 1, modSecs);
    QTRY_VERIFY_WITH_TIMEOUT(ready.count() + failed.count() > 0, 15000);
    QCOMPARE(failed.count(), 0);

    // 重画之后按真实指纹又能同步命中
    QVERIFY(!covers.cachedCover(m_connectionId, kBookPath, size, modSecs).isEmpty());
}

void TestNovelBridge::prefetchesAdjacentChapter()
{
    NovelBridge &novel = *NovelBridge::instance();
    novel.open(m_connectionId, kBookPath, QString());

    QTRY_VERIFY_WITH_TIMEOUT(novel.opened(), 5000);
    QTRY_COMPARE_WITH_TIMEOUT(novel.chapterIndex(), 0, 5000);

    // 可见章不占缓存位；邻章由后台预取装进来
    QVERIFY(!novel.hasCachedChapter(0));
    QTRY_VERIFY_WITH_TIMEOUT(novel.hasCachedChapter(1), 5000);

    // 命中预取 = 同步切章：函数返回时新章已经在屏上，不必再等一次 Range 往返
    novel.nextChapter();
    QCOMPARE(novel.chapterIndex(), 1);
    QCOMPARE(novel.chapterTitle(), QStringLiteral("第二章 雨停了"));
    QVERIFY(!novel.paragraphs().isEmpty());

    // 反向也预取（末章之后没有 +1，队列里只剩上一章）
    QTRY_VERIFY_WITH_TIMEOUT(novel.hasCachedChapter(0), 5000);
    novel.prevChapter();
    QCOMPARE(novel.chapterIndex(), 0);
}

void TestNovelBridge::cachesChapterOnDisk()
{
    NovelBridge &novel = *NovelBridge::instance();
    novel.open(m_connectionId, kBookPath, QString());

    QTRY_COMPARE_WITH_TIMEOUT(novel.chapterIndex(), 0, 5000);
    const QStringList paragraphs = novel.paragraphs();
    QVERIFY(!paragraphs.isEmpty());

    // 上屏的章必须已经落盘（写回是同步的，不必等预取）
    QTRY_VERIFY_WITH_TIMEOUT(NovelChapterCache::count() > 0, 5000);
    QStringList cached;
    // 指纹未知 = 离线视角：命中说明重启后同一个文件能直接从这里复原
    QVERIFY(NovelChapterCache::loadEpub(m_connectionId, kBookPath, {}, 0, &cached));
    QCOMPARE(cached, paragraphs);
}

void TestNovelBridge::opensOfflineFromCachedChapters()
{
    NovelBridge &novel = *NovelBridge::instance();
    novel.open(m_connectionId, kTxtPath, QString());
    QTRY_VERIFY_WITH_TIMEOUT(novel.opened(), 8000);
    QTRY_VERIFY_WITH_TIMEOUT(!novel.paragraphs().isEmpty(), 8000);
    QCOMPARE(novel.chapterCount(), 3);
    QVERIFY(!novel.offline());

    const QStringList firstChapter = novel.paragraphs();
    novel.close();
    QVERIFY(!novel.opened());

    // 文件够不着（源离线 / 被移走）：stat 失败，但索引与第 1 章正文都还在库里。
    // 用 qScopeGuard 补回文件：断言失败时测试会立刻返回，手动收尾等于把后续用例全部带崩
    const QString filePath = m_root.filePath(QStringLiteral("书架/桥接测试.txt"));
    const auto restore = qScopeGuard([filePath] {
        QFile file(filePath);
        if (file.open(QIODevice::WriteOnly)) {
            file.write(sampleTxt());
        }
    });
    QVERIFY(QFile::remove(filePath));
    novel.open(m_connectionId, kTxtPath, QString());

    QTRY_VERIFY_WITH_TIMEOUT(novel.opened() || !novel.errorText().isEmpty(), 8000);
    QVERIFY2(novel.errorText().isEmpty(), qPrintable(novel.errorText()));
    QVERIFY(novel.offline());
    // 目录来自缓存的索引：章数与章名一个不少
    QCOMPARE(novel.chapterCount(), 3);
    QCOMPARE(novel.chapters().value(1).toMap().value(QStringLiteral("title")).toString(),
             QStringLiteral("第2章 转折"));
    QVERIFY(novel.statusText().contains(QStringLiteral("离线")));

    // 续读章（第 1 章）直接从落盘缓存上屏，正文与在线时完全一致
    QTRY_COMPARE_WITH_TIMEOUT(novel.chapterIndex(), 0, 5000);
    QCOMPARE(novel.paragraphs(), firstChapter);

    // 没缓存的章：停在空章上提示，**不能**进错误页（那会把整块阅读器顶下屏）。
    // 第 3 章一定没缓存：预取只覆盖 ±1，第 1 章读着的时候只碰过第 2 章
    novel.goToChapter(2);
    QTRY_COMPARE_WITH_TIMEOUT(novel.chapterIndex(), 2, 5000);
    QVERIFY(novel.paragraphs().isEmpty());
    QVERIFY(novel.errorText().isEmpty());
    QVERIFY(novel.statusText().contains(QStringLiteral("未缓存")));

    // 翻回已缓存的章照常可读
    novel.goToChapter(0);
    QTRY_COMPARE_WITH_TIMEOUT(novel.chapterIndex(), 0, 5000);
    QCOMPARE(novel.paragraphs(), firstChapter);
}

void TestNovelBridge::refusesOfflineWithoutCache()
{
    NovelBridge &novel = *NovelBridge::instance();
    novel.open(m_connectionId, kTxtPath, QString());
    QTRY_VERIFY_WITH_TIMEOUT(novel.opened(), 8000);
    novel.close();

    // 索引还在，但一章正文都没缓存：进阅读器只会是空白屏，不如老实报错
    const QString filePath = m_root.filePath(QStringLiteral("书架/桥接测试.txt"));
    const auto restore = qScopeGuard([filePath] {
        QFile file(filePath);
        if (file.open(QIODevice::WriteOnly)) {
            file.write(sampleTxt());
        }
    });
    QVERIFY(QFile::remove(filePath));
    QVERIFY(NovelChapterCache::remove(m_connectionId, kTxtPath) > 0);

    novel.open(m_connectionId, kTxtPath, QString());
    QTRY_VERIFY_WITH_TIMEOUT(!novel.errorText().isEmpty(), 8000);
    QVERIFY(!novel.opened());
    QVERIFY(!novel.offline());
}

void TestNovelBridge::opensOfflineEpubFromSnapshot()
{
    NovelBridge &novel = *NovelBridge::instance();
    novel.open(m_connectionId, kBookPath, QString());
    QTRY_VERIFY_WITH_TIMEOUT(novel.opened(), 8000);
    QTRY_VERIFY_WITH_TIMEOUT(!novel.paragraphs().isEmpty(), 8000);
    const QStringList firstChapter = novel.paragraphs();
    novel.close();

    // 成功打开一次就该落下目录快照：章名、指纹都在里面
    EpubMeta meta;
    QVERIFY(EpubMetaStore::find(m_connectionId, kBookPath, &meta));
    QCOMPARE(meta.chapters.size(), 2);
    QCOMPARE(meta.chapters.at(1).title, QStringLiteral("第二章 雨停了"));
    QVERIFY(meta.fileSize > 0);

    // 让第 2 章「没缓存」：第 1 章上屏时预取会把第 2 章顺带缓存掉，
    // 删掉这一行才能验证离线缺章时的降级表现
    QVERIFY(AppDatabase::instance().execute(
        QStringLiteral("DELETE FROM novelChapter WHERE connectionID = ? AND filePath = ? "
                       "AND chapterIndex = 1"),
        {m_connectionId, kBookPath}));

    // 文件够不着：stat 失败 → 快照还原目录，正文只读缓存
    const QString filePath = m_root.filePath(QStringLiteral("书架/桥接测试.epub"));
    const auto restore = qScopeGuard([filePath] {
        QFile file(filePath);
        if (file.open(QIODevice::WriteOnly)) {
            file.write(sampleEpub());
        }
    });
    QVERIFY(QFile::remove(filePath));

    novel.open(m_connectionId, kBookPath, QString());
    QTRY_VERIFY_WITH_TIMEOUT(novel.opened() || !novel.errorText().isEmpty(), 8000);
    QVERIFY2(novel.errorText().isEmpty(), qPrintable(novel.errorText()));
    QVERIFY(novel.offline());

    // 目录与书名都来自快照：不是「没有目录的空壳」
    QCOMPARE(novel.chapterCount(), 2);
    QCOMPARE(novel.title(), QStringLiteral("桥接测试书"));
    QCOMPARE(novel.chapters().value(1).toMap().value(QStringLiteral("title")).toString(),
             QStringLiteral("第二章 雨停了"));
    QVERIFY(novel.statusText().contains(QStringLiteral("离线")));

    // 指纹也是从快照恢复的：续读记录仍按同一个文件算
    ProgressRecord record;
    QVERIFY(ProgressRepository::instance().find(m_connectionId, kBookPath, &record));
    QCOMPARE(record.progress.value(QStringLiteral("chapter")).toInt(), 0);

    // 缓存章正文与在线时一致
    QTRY_COMPARE_WITH_TIMEOUT(novel.chapterIndex(), 0, 8000);
    QCOMPARE(novel.paragraphs(), firstChapter);

    // 缺章：空章 + 提示，**不能**进错误页；翻回缓存章照常可读
    novel.goToChapter(1);
    QTRY_COMPARE_WITH_TIMEOUT(novel.chapterIndex(), 1, 8000);
    QVERIFY(novel.paragraphs().isEmpty());
    QVERIFY(novel.errorText().isEmpty());
    QVERIFY(novel.statusText().contains(QStringLiteral("未缓存")));

    novel.goToChapter(0);
    QTRY_COMPARE_WITH_TIMEOUT(novel.chapterIndex(), 0, 8000);
    QCOMPARE(novel.paragraphs(), firstChapter);
}

void TestNovelBridge::refusesOfflineEpubWithoutSnapshot()
{
    // 从没成功打开过 = 没有目录快照：连章数都不知道，
    // 宁可报错，也不要打开一个没有目录的空壳
    const QString path = QStringLiteral("/书架/离线测试.epub");
    QFile book(m_root.filePath(QStringLiteral("书架/离线测试.epub")));
    QVERIFY(book.open(QIODevice::WriteOnly));
    QVERIFY(book.write(sampleEpub()) > 0);
    book.close();
    QVERIFY(QFile::remove(m_root.filePath(QStringLiteral("书架/离线测试.epub"))));

    NovelBridge &novel = *NovelBridge::instance();
    novel.open(m_connectionId, path, QString());
    QTRY_VERIFY_WITH_TIMEOUT(!novel.errorText().isEmpty(), 8000);
    QVERIFY(!novel.opened());
    QVERIFY(!novel.offline());
}

void TestNovelBridge::handsImageCollectionToComic()
{
    NovelBridge &novel = *NovelBridge::instance();
    ComicBridge &comic = *ComicBridge::instance();
    comic.close();

    novel.open(m_connectionId, kImageBookPath, QString());

    // 图集整本转交漫画阅读器：页数来自压缩包里的图片条目（3 张）
    QTRY_VERIFY_WITH_TIMEOUT(comic.pageCount() > 0 || !comic.errorText().isEmpty(), 8000);
    QVERIFY2(comic.errorText().isEmpty(), qPrintable(comic.errorText()));
    QCOMPARE(comic.pageCount(), 3);
    QCOMPARE(comic.title(), QStringLiteral("图集测试书"));
    // 页序按 OPF 的 spine（002 打头），不是压缩包里的条目名排序
    QCOMPARE(comic.pageName(), QStringLiteral("OEBPS/pages/002.png"));

    // 小说侧既不算打开成功、也不该报错：这是换了个阅读器，不是打不开
    QVERIFY(!novel.opened());
    QVERIFY(novel.errorText().isEmpty());
    QVERIFY(!novel.loading());

    // 图集不是小说：不写目录快照，也不留空段落的章节缓存
    EpubMeta meta;
    QVERIFY(!EpubMetaStore::find(m_connectionId, kImageBookPath, &meta));
    QCOMPARE(NovelChapterCache::count(), 0);

    comic.close();
}

void TestNovelBridge::keepsIllustrationSnapshotOnDisk()
{
    NovelBridge &novel = *NovelBridge::instance();
    novel.open(m_connectionId, kIllustratedPath, QString());
    QTRY_VERIFY_WITH_TIMEOUT(novel.opened() || !novel.errorText().isEmpty(), 8000);
    QVERIFY2(novel.errorText().isEmpty(), qPrintable(novel.errorText()));
    QTRY_VERIFY_WITH_TIMEOUT(!novel.paragraphs().isEmpty(), 8000);

    // 段落流仍是「前一段 / 插图 / 后一段」：插图占一格、文本置空，
    // 下标空间不变（进度锚点与滚动上报都靠下标）
    QCOMPARE(novel.paragraphs().size(), 3);
    QCOMPARE(novel.paragraphs().at(0), QStringLiteral("前一段"));
    QCOMPARE(novel.paragraphs().at(2), QStringLiteral("后一段"));
    QVERIFY(!novel.isImageParagraph(0));
    QVERIFY(novel.isImageParagraph(1));

    // 抽出来的图落在缓存分区里：QML 只能吃本地文件
    QTRY_VERIFY_WITH_TIMEOUT(!novel.imageUrl(1).isEmpty(), 8000);
    const QString file = QUrl(novel.imageUrl(1)).toLocalFile();
    QVERIFY(QFileInfo::exists(file));
    QVERIFY(file.contains(QStringLiteral("novelImages")));
    QCOMPARE(novel.imageSize(1), QSize(90, 120));
    // 快照就是原图字节
    QFile snapshot(file);
    QVERIFY(snapshot.open(QIODevice::ReadOnly));
    QCOMPARE(snapshot.readAll(), coverPng());

    novel.close();
}

void TestNovelBridge::showsCachedIllustrationOffline()
{
    NovelBridge &novel = *NovelBridge::instance();
    novel.open(m_connectionId, kIllustratedPath, QString());
    QTRY_VERIFY_WITH_TIMEOUT(novel.opened(), 8000);
    QTRY_VERIFY_WITH_TIMEOUT(!novel.imageUrl(1).isEmpty(), 8000);
    const QString onlineUrl = novel.imageUrl(1);
    novel.close();

    // 文件够不着：正文走章节缓存、插图走快照，两者都该还在
    const QString filePath = m_root.filePath(QStringLiteral("书架/插图测试.epub"));
    const auto restore = qScopeGuard([filePath] {
        QFile file(filePath);
        if (file.open(QIODevice::WriteOnly)) {
            file.write(sampleIllustratedEpub());
        }
    });
    QVERIFY(QFile::remove(filePath));

    novel.open(m_connectionId, kIllustratedPath, QString());
    QTRY_VERIFY_WITH_TIMEOUT(novel.opened() || !novel.errorText().isEmpty(), 8000);
    QVERIFY2(novel.errorText().isEmpty(), qPrintable(novel.errorText()));
    QVERIFY(novel.offline());

    QTRY_COMPARE_WITH_TIMEOUT(novel.paragraphs().size(), 3, 8000);
    QVERIFY(novel.isImageParagraph(1));
    // 离线时取不到字节，但快照还在：同一份文件、同一个 URL
    QCOMPARE(novel.imageUrl(1), onlineUrl);

    novel.close();
}

void TestNovelBridge::paginatesChapterIntoPages()
{
    NovelBridge &novel = *NovelBridge::instance();
    const int originalFontSize = novel.fontSize();

    novel.open(m_connectionId, kIllustratedPath, QString());
    QTRY_VERIFY_WITH_TIMEOUT(novel.opened() || !novel.errorText().isEmpty(), 8000);
    QVERIFY2(novel.errorText().isEmpty(), qPrintable(novel.errorText()));
    QTRY_VERIFY_WITH_TIMEOUT(!novel.paragraphs().isEmpty(), 8000);
    QTRY_VERIFY_WITH_TIMEOUT(!novel.imageUrl(1).isEmpty(), 8000);

    novel.setPageMode(true);
    QVERIFY(novel.pageMode());
    // 视口小到一页装不下两段话：这样才能验证「切页」而不是「整章一页」
    novel.setPageViewport(320, 160);
    QVERIFY(novel.pageCount() >= 2);
    QVERIFY(novel.pageLineHeight() > 0);

    // 每个段落都能找回自己的页（翻页模式恢复进度的唯一依据）
    for (int p = 0; p < novel.paragraphs().size(); ++p)
        QVERIFY2(novel.pageForParagraph(p) >= 0,
                 qPrintable(QStringLiteral("段落 %1 没有页").arg(p)));

    // 插图独占一页，那一页没有文字行
    const int imagePage = novel.pageForParagraph(1);
    QCOMPARE(novel.pageImageParagraph(imagePage), 1);
    QVERIFY(novel.pageLines(imagePage).isEmpty());

    // 第 0 页是第一段的文字，且页码夹在合法区间里
    novel.setPageIndex(0);
    QCOMPARE(novel.pageIndex(), 0);
    QVERIFY(novel.pageLines(0).join(QString()).contains(QStringLiteral("前一段")));

    // 一路往后翻：不崩、不越界（跨章由 C++ 负责，末页/末章会停住）
    for (int i = 0; i < novel.pageCount() + 3; ++i)
        novel.nextPage();
    QVERIFY(novel.pageIndex() >= 0);
    QVERIFY(novel.pageIndex() < qMax(1, novel.pageCount()));

    // 改字号要重排：页数不会变少，当前页也不会越界
    const int pagesBefore = novel.pageCount();
    novel.setFontSize(originalFontSize + 11);
    QVERIFY(novel.pageCount() >= pagesBefore);
    QVERIFY(novel.pageIndex() < qMax(1, novel.pageCount()));
    // 页码不持久化：进度仍然记在段落下标上
    QVERIFY(novel.percent() > 0.0);

    novel.setFontSize(originalFontSize);
    novel.setPageMode(false);
    QVERIFY(!novel.pageMode());
    novel.close();
}

void TestNovelBridge::resumesInsideLongParagraph()
{
    NovelBridge &novel = *NovelBridge::instance();
    novel.setPageMode(true);

    novel.open(m_connectionId, kLongPath, QString());
    QTRY_VERIFY_WITH_TIMEOUT(novel.opened() || !novel.errorText().isEmpty(), 8000);
    QVERIFY2(novel.errorText().isEmpty(), qPrintable(novel.errorText()));
    QTRY_VERIFY_WITH_TIMEOUT(!novel.paragraphs().isEmpty(), 8000);

    novel.setPageViewport(320, 160);
    QVERIFY2(novel.pageCount() >= 4, "长段落没有跨页，这个用例就证明不了什么");

    // 翻到第 3 页：这一页的首行还在长段中间，锚点必须落在段内而不是段首
    novel.setPageIndex(2);
    QCOMPARE(novel.pageIndex(), 2);
    const int longParagraph = novel.anchorParagraph();
    QVERIFY(longParagraph >= 0);
    QVERIFY2(
        novel.paragraphs().at(longParagraph).size() > 500,
        qPrintable(QStringLiteral("第 3 页应落在长段里，实际落在第 %1 段").arg(longParagraph)));
    QVERIFY2(novel.anchorOffset() > 0, "长段中间那一页的首行不可能还在段首");
    const int savedOffset = novel.anchorOffset();

    // 落库的是 {章, 段, 段内偏移}：页码不进持久化
    ProgressRecord record;
    QVERIFY(ProgressRepository::instance().find(m_connectionId, kLongPath, &record));
    QCOMPARE(record.progress.value(QStringLiteral("charOffset")).toInt(), savedOffset);
    QCOMPARE(record.progress.value(QStringLiteral("paragraph")).toInt(), longParagraph);
    novel.close();

    // 重开：视口一推上来就该落回同一页（不是这一段的第一页）
    novel.open(m_connectionId, kLongPath, QString());
    QTRY_VERIFY_WITH_TIMEOUT(novel.opened() || !novel.errorText().isEmpty(), 8000);
    QTRY_VERIFY_WITH_TIMEOUT(!novel.paragraphs().isEmpty(), 8000);
    novel.setPageViewport(320, 160);

    QCOMPARE(novel.anchorOffset(), savedOffset);
    QCOMPARE(novel.pageIndex(), 2);
    QCOMPARE(novel.pageForPosition(longParagraph, savedOffset), 2);

    novel.setPageMode(false);
    novel.close();
}

void TestNovelBridge::remembersSerifPreference()
{
    NovelBridge &novel = *NovelBridge::instance();
    const int originalStyle = novel.fontStyle();
    const QString originalFamilies = novel.fontFamilies();

    novel.setFontStyle(1);
    QCOMPARE(novel.fontStyle(), 1);
    QVERIFY(novel.fontFamilies() != originalFamilies);
    QVERIFY2(novel.fontFamilies().contains(QStringLiteral("Serif")),
             qPrintable(novel.fontFamilies()));
    // 落 AppSettings：设置页与阅读器共用同一组 reader.* 键
    QCOMPARE(AppSettings::instance().value(QStringLiteral("reader.fontStyle"), -1).toInt(), 1);

    // 换字体等于换字宽：分页要用新字体重排，且页码不越界
    novel.open(m_connectionId, kLongPath, QString());
    QTRY_VERIFY_WITH_TIMEOUT(novel.opened() || !novel.errorText().isEmpty(), 8000);
    QTRY_VERIFY_WITH_TIMEOUT(!novel.paragraphs().isEmpty(), 8000);
    novel.setPageMode(true);
    novel.setPageViewport(320, 160);
    QVERIFY(novel.pageCount() >= 2);
    novel.setFontStyle(0);
    QVERIFY(novel.pageCount() >= 2);
    QVERIFY(novel.pageIndex() < novel.pageCount());
    QVERIFY(novel.pageLineHeight() > 0);

    novel.setFontStyle(originalStyle);
    novel.setPageMode(false);
    novel.close();
}

void TestNovelBridge::marksChapterHeadingForDisplay()
{
    NovelBridge &novel = *NovelBridge::instance();
    novel.setPageMode(true);

    novel.open(m_connectionId, kBookPath, QString());
    QTRY_VERIFY_WITH_TIMEOUT(novel.opened() || !novel.errorText().isEmpty(), 8000);
    QTRY_VERIFY_WITH_TIMEOUT(!novel.paragraphs().isEmpty(), 8000);

    // epub 的 <h1> 会落成第 0 段：认出来，界面上由标题带画（否则页眉 + 正文各一遍）
    QCOMPARE(novel.paragraphs().constFirst(), QStringLiteral("第一章 起风了"));
    QCOMPARE(novel.titleParagraph(), 0);

    novel.setPageViewport(320, 160);
    QVERIFY(novel.titleReserve() > 0);
    QCOMPARE(novel.titleReserve(), novel.pageLineHeight() * 2);
    QCOMPARE(novel.titlePage(), 0);

    // 章首（标题段）仍然落在第一页：翻到别处再回来能落回同一个位置
    QCOMPARE(novel.pageIndex(), 0);
    QCOMPARE(novel.pageForParagraph(0), 0);
    QCOMPARE(novel.pageForPosition(0, 0), 0);
    QVERIFY(novel.pageLines(0).size() > 0);
    for (const QString &line : novel.pageLines(0))
        QVERIFY2(!line.contains(QStringLiteral("起风了")), qPrintable(line));

    // 滚动模式靠 titleParagraph 跳过这一项，段落下标空间不变
    novel.setPageMode(false);
    QCOMPARE(novel.titleParagraph(), 0);
    QCOMPARE(novel.paragraphs().size() > 1, true);
    novel.close();
}

void TestNovelBridge::prefersBundledSerif()
{
    // qrc 里的思源宋体子集要真的能注册上：注册失败只记日志不报错，
    // 所以必须在这里卡一道 —— 否则「跨平台字形一致」会静悄悄退化成系统字体
    BundledFonts::initialize();
    const QStringList serif = BundledFonts::serifFamilies();
    QVERIFY2(!serif.isEmpty(), "内置宋体没注册上：字体文件或 fonts.qrc 有问题");
    QVERIFY(serif.contains(QStringLiteral("Source Han Serif CN")));

    NovelBridge &novel = *NovelBridge::instance();
    const int originalStyle = novel.fontStyle();
    novel.setFontStyle(0);
    novel.setFontStyle(1);

    const QStringList chain = novel.fontFamilies().split(QStringLiteral(", "));
    QCOMPARE(chain.constFirst(), QStringLiteral("Source Han Serif CN"));
    // 系统字体仍留在链上兜底；同一族名不重复出现
    QVERIFY(chain.size() > 1);
    QCOMPARE(chain.count(QStringLiteral("Source Han Serif CN")), 1);

    // 黑体链不该被宋体顶掉（两组独立注册）
    novel.setFontStyle(0);
    QCOMPARE(novel.fontFamilies().split(QStringLiteral(", ")).constFirst()
                 == QStringLiteral("Source Han Serif CN"),
             false);

    novel.setFontStyle(originalStyle);
}

void TestNovelBridge::suggestsNextBookWhenFinished()
{
    NovelBridge &novel = *NovelBridge::instance();
    novel.open(m_connectionId, kBookPath, QString());
    QTRY_VERIFY_WITH_TIMEOUT(novel.opened(), 5000);
    // 没读到底之前不该有候选：提示条不能提前冒出来
    QVERIFY(novel.nextSuggestion().isEmpty());

    novel.setAtBookEnd(true);
    QTRY_VERIFY_WITH_TIMEOUT(!novel.nextSuggestion().isEmpty(), 5000);
    // 同目录两本书，按名排序 epub 在前 → 下一本是 txt：跨格式仍算同一类
    QCOMPARE(novel.nextSuggestion().value(QStringLiteral("name")).toString(),
             QStringLiteral("桥接测试.txt"));
    QCOMPARE(novel.nextSuggestion().value(QStringLiteral("connectionId")).toString(),
             m_connectionId);

    // 读到底要落 finished：首页据此显示「已读完」，而不是停在上次翻阅的位置
    ProgressRecord record;
    QVERIFY(ProgressRepository::instance().find(m_connectionId, kBookPath, &record));
    QVERIFY(record.finished);
    QCOMPARE(novel.percent(), 1.0);

    // 往回翻：提示条撤销
    novel.setAtBookEnd(false);
    QVERIFY(novel.nextSuggestion().isEmpty());

    // 收起本次推荐；再读到底还能再推一次（dismissed 只在末尾状态下有效）
    novel.setAtBookEnd(true);
    QTRY_VERIFY_WITH_TIMEOUT(!novel.nextSuggestion().isEmpty(), 5000);
    novel.dismissNextSuggestion();
    QVERIFY(novel.nextSuggestion().isEmpty());
    novel.setAtBookEnd(false);
    novel.setAtBookEnd(true);
    QTRY_VERIFY_WITH_TIMEOUT(!novel.nextSuggestion().isEmpty(), 5000);

    // 点「开始读」真的换书：epub 2 章 → txt 3 章，章节数变了才说明换的是另一本
    novel.openNextSuggestion();
    QTRY_VERIFY_WITH_TIMEOUT(!novel.loading(), 8000);
    QVERIFY2(novel.errorText().isEmpty() && novel.opened(),
             qPrintable(QStringLiteral("opened=%1 error=%2 status=%3 offline=%4 chapters=%5")
                            .arg(novel.opened())
                            .arg(novel.errorText(), novel.statusText())
                            .arg(novel.offline())
                            .arg(novel.chapterCount())));
    QTRY_COMPARE_WITH_TIMEOUT(novel.chapterCount(), 3, 8000);
    QTRY_VERIFY_WITH_TIMEOUT(novel.opened(), 8000);
    QTRY_VERIFY_WITH_TIMEOUT(!novel.paragraphs().isEmpty(), 8000);
    QVERIFY2(novel.errorText().isEmpty(), qPrintable(novel.errorText()));
    QVERIFY(novel.nextSuggestion().isEmpty());
}

void TestNovelBridge::syncsPreferencesFromSettingsPage()
{
    // 设置页与阅读器写的是同一组 `reader.*` 键（§14.16 即时生效）：
    // 设置页改字号，桥接必须立刻反映，而不是等下次启动才重新 loadPreferences
    NovelBridge &novel = *NovelBridge::instance();
    const int oldFontSize = novel.fontSize();
    const double oldBrightness = novel.brightness();
    // 不假设默认值：取一个与当前值不同的目标，否则「没变化」会让信号计数扑空
    const int targetFontSize = oldFontSize == 26 ? 24 : 26;
    const double targetBrightness = oldBrightness < 0 ? 0.8 : -1.0;
    QSignalSpy fontSizeSpy(&novel, &NovelBridge::fontSizeChanged);
    QSignalSpy brightnessSpy(&novel, &NovelBridge::brightnessChanged);

    AppSettings::instance().setValue(QStringLiteral("reader.fontSize"), targetFontSize);
    QCOMPARE(novel.fontSize(), targetFontSize);
    QCOMPARE(fontSizeSpy.count(), 1);

    // 同一个值再写一次：AppSettings 自己会吞掉，桥接不能跟着重复发信号
    AppSettings::instance().setValue(QStringLiteral("reader.fontSize"), targetFontSize);
    QCOMPARE(fontSizeSpy.count(), 1);

    // -1 是「跟随系统 / 不压蒙层」的哨兵值，不能被当成 0 或 1
    AppSettings::instance().setValue(QStringLiteral("reader.brightness"), targetBrightness);
    QCOMPARE(novel.brightness(), targetBrightness);
    QCOMPARE(brightnessSpy.count(), 1);

    AppSettings::instance().setValue(QStringLiteral("reader.fontSize"), oldFontSize);
    AppSettings::instance().setValue(QStringLiteral("reader.brightness"), oldBrightness);
}

QTEST_MAIN(TestNovelBridge)
#include "tst_novelbridge.moc"
