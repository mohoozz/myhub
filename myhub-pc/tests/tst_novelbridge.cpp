// NovelBridge 的 epub / txt 接入（§5.1 PC-206、§13 离线阅读）
//
// 覆盖五件事，全部走真实链路（本地适配器 + 真实 sqlite + 磁盘上的书）：
//   · 打开 epub：目录来自 OPF/NAV，书名取 OPF 而不是文件名
//   · 按章加载：段落流直接进 `paragraphs`，上一章下一章可用
//   · 锚点：epub 用「章号 + 段落下标」落库（不写字节偏移），再次打开能回到同一段
//   · 封面：CoverService 从 epub 里取出封面并落盘，第二次同步命中
//   · 离线：文件够不着时，靠分章索引 + 章节落盘缓存继续读读过的章

#include "core/database/AppDatabase.h"
#include "core/history/ProgressRepository.h"
#include "core/novel/NovelChapterCache.h"
#include "core/preferences/AppSettings.h"
#include "core/storage/StorageAdapterFactory.h"
#include "core/utils/AppPaths.h"
#include "features/connections/ConnectionStore.h"
#include "features/cover/CoverService.h"
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
const QString kBookPath = QStringLiteral("/书架/桥接测试.epub");
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
    void refusesOfflineForEpub();
    void suggestsNextBookWhenFinished();

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
    QVERIFY(AppDatabase::instance().execute(QStringLiteral("DELETE FROM readingProgress")));
    QVERIFY(AppDatabase::instance().execute(QStringLiteral("DELETE FROM novelChapter")));
}

void TestNovelBridge::cleanupTestCase()
{
    NovelBridge::instance()->close();
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

void TestNovelBridge::refusesOfflineForEpub()
{
    // epub 的目录藏在 OPF 里，stat 都失败时连「有几章」都不知道：
    // 宁可报错，也不要打开一个没有目录的空壳（等元数据快照落地再改）
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

QTEST_MAIN(TestNovelBridge)
#include "tst_novelbridge.moc"
