// 章节解码产物落盘单测（§5 `NovelChapterCache`、§13「小说章节缓存本地化」）
//
// 覆盖三层：
//   1. 往返：txt 行表（含字节偏移）与 epub 段落存进去能原样取回来；
//   2. 指纹：文件变了（size 或 modTime 任一不符）即未命中，绝不给旧正文；
//      但「不知道指纹」（离线）时必须放行 —— 那是这条缓存存在的意义；
//   3. 自愈：payload 被写坏 / 版本不认识 / 偏移不递增，一律当未命中，不抛不崩。
//
// 数据库用临时目录里的真实 sqlite 文件，走与生产完全相同的迁移路径。

#include <QStandardPaths>
#include <QTemporaryDir>
#include <QtTest>

#include "core/database/AppDatabase.h"
#include "core/novel/NovelChapterCache.h"
#include "core/preferences/AppSettings.h"
#include "core/utils/AppPaths.h"

using namespace myhub;

namespace {

const QString kConnectionId = QStringLiteral("conn-local");
const QString kPath = QStringLiteral("/书架/缓存测试.txt");

const NovelChapterCache::Fingerprint kFingerprint{1024LL * 1024, 1700000000000LL};

TxtChapterText sampleChapter()
{
    TxtChapterText text;
    text.title = QStringLiteral("第一章 起点");
    text.encoding = TextCodec::Utf8;
    text.start = 0;
    text.end = 4096;
    text.firstBodyLine = 1;
    text.truncated = false;

    TxtLine title;
    title.text = QStringLiteral("第一章 起点");
    title.start = 0;
    title.end = 18;
    text.lines.append(title);

    TxtLine body;
    body.text = QStringLiteral("雨停了，他把伞收起来。");
    body.start = 20;
    body.end = 56;
    text.lines.append(body);

    TxtLine tail;
    tail.text = QStringLiteral("街上没有人。");
    tail.start = 58;
    tail.end = 80;
    text.lines.append(tail);
    return text;
}

} // namespace

class TestNovelChapterCache : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void cleanupTestCase();
    void init();

    // ---- txt ----
    void txtRoundTripKeepsLineOffsets();
    void txtRejectsChangedFileSize();
    void txtRejectsChangedModTime();
    void txtAcceptsUnknownFingerprint();
    void txtRejectsCorruptPayload();
    void txtRejectsBrokenOffsets();

    // ---- epub ----
    void epubRoundTrip();
    void epubKeepsEmptyChapter();

    // ---- 维护 ----
    void cachedChaptersListsSortedIndices();
    void dropStaleOnlyTouchesThatBook();
    void trimKeepsMostRecentRows();
    void removeClearsWholeBook();

private:
    /// 直接往表里塞一个坏 payload（模拟磁盘损坏 / 旧版本残留）
    void writeRawPayload(int chapter, const QByteArray &payload);

    QTemporaryDir m_dir;
};

void TestNovelChapterCache::initTestCase()
{
    QCoreApplication::setApplicationName(
        QStringLiteral("MyHubNovelChapterCacheTest-%1").arg(QCoreApplication::applicationPid()));
    QStandardPaths::setTestModeEnabled(true);
    AppPaths::initializeAll();
    AppSettings::instance().initialize();

    QVERIFY(m_dir.isValid());
    QVERIFY(AppDatabase::instance().open(m_dir.filePath(QStringLiteral("myhub.sqlite"))));
    // 迁移到最新版本时 novelChapter 表必须已经建好，否则后面的读写全无意义
    QCOMPARE(AppDatabase::instance().schemaVersion(), 3);
}

void TestNovelChapterCache::cleanupTestCase()
{
    AppDatabase::instance().close();
}

void TestNovelChapterCache::init()
{
    QVERIFY(AppDatabase::instance().execute(QStringLiteral("DELETE FROM novelChapter")));
}

void TestNovelChapterCache::writeRawPayload(int chapter, const QByteArray &payload)
{
    QVERIFY(AppDatabase::instance().execute(
        QStringLiteral("INSERT INTO novelChapter (id, connectionID, filePath, fileSize, modTime, "
                       "chapterIndex, title, payload, updatedAt) "
                       "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) "
                       "ON CONFLICT(connectionID, filePath, chapterIndex) DO UPDATE SET "
                       " payload = excluded.payload"),
        {QStringLiteral("raw-%1").arg(chapter), kConnectionId, kPath, kFingerprint.fileSize,
         kFingerprint.modTime, chapter, QStringLiteral("坏章"), payload, 1LL}));
}

void TestNovelChapterCache::txtRoundTripKeepsLineOffsets()
{
    const TxtChapterText source = sampleChapter();
    QVERIFY(NovelChapterCache::saveTxt(kConnectionId, kPath, kFingerprint, 3, source));
    QCOMPARE(NovelChapterCache::count(), 1);

    TxtChapterText restored;
    QVERIFY(NovelChapterCache::loadTxt(kConnectionId, kPath, kFingerprint, 3, &restored));

    // 行表就是锚点的全部依据：文本、章界、首行偏移必须一字不差
    QCOMPARE(restored.title, source.title);
    QCOMPARE(restored.encoding, source.encoding);
    QCOMPARE(restored.start, source.start);
    QCOMPARE(restored.end, source.end);
    QCOMPARE(restored.firstBodyLine, source.firstBodyLine);
    QCOMPARE(restored.truncated, source.truncated);
    QCOMPARE(restored.lines.size(), source.lines.size());
    for (int i = 0; i < source.lines.size(); ++i) {
        QCOMPARE(restored.lines.at(i).text, source.lines.at(i).text);
        QCOMPARE(restored.lines.at(i).start, source.lines.at(i).start);
        QCOMPARE(restored.lines.at(i).end, source.lines.at(i).end);
    }

    // 段落视图与字节换算必须照常工作，否则命中缓存也定不了位
    QCOMPARE(restored.paragraphs(), source.paragraphs());
    QCOMPARE(restored.paragraphAtByte(58), 1);
    QCOMPARE(restored.byteAtParagraph(1), 58);
}

void TestNovelChapterCache::txtRejectsChangedFileSize()
{
    QVERIFY(NovelChapterCache::saveTxt(kConnectionId, kPath, kFingerprint, 0, sampleChapter()));

    TxtChapterText restored;
    const NovelChapterCache::Fingerprint grown{kFingerprint.fileSize + 1, kFingerprint.modTime};
    QVERIFY(!NovelChapterCache::loadTxt(kConnectionId, kPath, grown, 0, &restored));

    // 未命中就是未命中，不能悄悄把旧正文递出去
    QVERIFY(restored.isEmpty());
}

void TestNovelChapterCache::txtRejectsChangedModTime()
{
    QVERIFY(NovelChapterCache::saveTxt(kConnectionId, kPath, kFingerprint, 0, sampleChapter()));

    TxtChapterText restored;
    const NovelChapterCache::Fingerprint touched{kFingerprint.fileSize,
                                                 kFingerprint.modTime + 2000};
    QVERIFY(!NovelChapterCache::loadTxt(kConnectionId, kPath, touched, 0, &restored));
}

void TestNovelChapterCache::txtAcceptsUnknownFingerprint()
{
    QVERIFY(NovelChapterCache::saveTxt(kConnectionId, kPath, kFingerprint, 0, sampleChapter()));

    // 离线 / stat 失败：指纹未知，只能信缓存 —— 这也正是这条缓存的头号用途
    TxtChapterText restored;
    QVERIFY(NovelChapterCache::loadTxt(kConnectionId, kPath, {}, 0, &restored));
    QCOMPARE(restored.paragraphs().size(), 2);
}

void TestNovelChapterCache::txtRejectsCorruptPayload()
{
    // 不是 zlib 流：qUncompress 返回空
    writeRawPayload(9, QByteArrayLiteral("not-a-zlib-stream"));

    TxtChapterText restored;
    QVERIFY(!NovelChapterCache::loadTxt(kConnectionId, kPath, kFingerprint, 9, &restored));

    // 是 zlib 流但 JSON 不是对象
    writeRawPayload(9, qCompress(QByteArrayLiteral("[1,2,3]"), 6));
    QVERIFY(!NovelChapterCache::loadTxt(kConnectionId, kPath, kFingerprint, 9, &restored));
}

void TestNovelChapterCache::txtRejectsBrokenOffsets()
{
    // 偏移不递增的行表：拿来算锚点会指出一句完全不相干的话，宁可重读
    const QByteArray broken =
        qCompress(QByteArrayLiteral(
                      "{\"v\":1,\"title\":\"x\",\"encoding\":\"UTF-8\",\"start\":0,"
                      "\"end\":10,\"firstBodyLine\":0,\"truncated\":false,"
                      "\"lines\":[{\"t\":\"a\",\"s\":5,\"e\":9},{\"t\":\"b\",\"s\":5,\"e\":8}]}"),
                  6);
    writeRawPayload(4, broken);

    TxtChapterText restored;
    QVERIFY(!NovelChapterCache::loadTxt(kConnectionId, kPath, kFingerprint, 4, &restored));
}

void TestNovelChapterCache::epubRoundTrip()
{
    const QStringList paragraphs{QStringLiteral("第一段"), QStringLiteral("第二段"),
                                 QStringLiteral("含「引号」与 emoji 🙂")};
    QVERIFY(NovelChapterCache::saveEpub(kConnectionId, kPath, kFingerprint, 2, paragraphs));

    QStringList restored;
    QVERIFY(NovelChapterCache::loadEpub(kConnectionId, kPath, kFingerprint, 2, &restored));
    QCOMPARE(restored, paragraphs);

    // 章号是键的一部分：别的章不能串味
    QStringList other;
    QVERIFY(!NovelChapterCache::loadEpub(kConnectionId, kPath, kFingerprint, 1, &other));
}

void TestNovelChapterCache::epubKeepsEmptyChapter()
{
    // 封面页 / 纯图片页解出空段落：**合法**的空章，命中后应当还原成空而不是报未命中
    QVERIFY(!NovelChapterCache::saveEpub(kConnectionId, kPath, kFingerprint, 0, {}));
    QCOMPARE(NovelChapterCache::count(), 0);

    // 已有内容的章照常可写，空章不写不覆盖别的行
    QVERIFY(NovelChapterCache::saveEpub(kConnectionId, kPath, kFingerprint, 1,
                                        {QStringLiteral("正文")}));
    QCOMPARE(NovelChapterCache::count(), 1);
}

void TestNovelChapterCache::cachedChaptersListsSortedIndices()
{
    QVERIFY(NovelChapterCache::cachedChapters(kConnectionId, kPath).isEmpty());

    QVERIFY(NovelChapterCache::saveTxt(kConnectionId, kPath, kFingerprint, 5, sampleChapter()));
    QVERIFY(NovelChapterCache::saveTxt(kConnectionId, kPath, kFingerprint, 0, sampleChapter()));
    QVERIFY(NovelChapterCache::saveEpub(kConnectionId, kPath, kFingerprint, 2,
                                        {QStringLiteral("第二段")}));

    // 升序 + 只列本书：离线打开时靠它判断「至少有一章能读」并挑最近的缓存章
    QCOMPARE(NovelChapterCache::cachedChapters(kConnectionId, kPath), (QList<int>{0, 2, 5}));
    QVERIFY(
        NovelChapterCache::cachedChapters(kConnectionId, QStringLiteral("/别的书.txt")).isEmpty());
}

void TestNovelChapterCache::dropStaleOnlyTouchesThatBook()
{
    const QString otherPath = QStringLiteral("/书架/另一本.txt");
    QVERIFY(NovelChapterCache::saveTxt(kConnectionId, kPath, kFingerprint, 0, sampleChapter()));
    QVERIFY(NovelChapterCache::saveTxt(kConnectionId, kPath, kFingerprint, 1, sampleChapter()));
    QVERIFY(NovelChapterCache::saveTxt(kConnectionId, otherPath, kFingerprint, 0, sampleChapter()));
    QCOMPARE(NovelChapterCache::count(), 3);

    const NovelChapterCache::Fingerprint grown{kFingerprint.fileSize + 4096, kFingerprint.modTime};
    QCOMPARE(NovelChapterCache::dropStale(kConnectionId, kPath, grown), 2);

    TxtChapterText restored;
    // 别的书不受影响
    QVERIFY(NovelChapterCache::loadTxt(kConnectionId, otherPath, kFingerprint, 0, &restored));
    // 指纹未知时不允许清缓存（离线场景要靠它）
    QCOMPARE(NovelChapterCache::dropStale(kConnectionId, otherPath, {}), 0);
    QVERIFY(NovelChapterCache::loadTxt(kConnectionId, otherPath, kFingerprint, 0, &restored));
}

void TestNovelChapterCache::trimKeepsMostRecentRows()
{
    const QString otherPath = QStringLiteral("/书架/修剪.txt");
    // 每个 (书, 章) 是一行；updatedAt 单调递增，最后写的几行必须留下。
    // 写入之间必须真的隔开时间戳 —— 同一毫秒内的行淘汰顺序是任意的，断言毫无意义
    for (int chapter = 0; chapter < 5; ++chapter) {
        QVERIFY(NovelChapterCache::saveTxt(kConnectionId, otherPath, kFingerprint, chapter,
                                           sampleChapter()));
        QTest::qSleep(3);
    }
    QCOMPARE(NovelChapterCache::count(), 5);
    QCOMPARE(NovelChapterCache::trim(2), 3);
    QCOMPARE(NovelChapterCache::count(), 2);

    TxtChapterText restored;
    QVERIFY(NovelChapterCache::loadTxt(kConnectionId, otherPath, kFingerprint, 4, &restored));
    QVERIFY(!NovelChapterCache::loadTxt(kConnectionId, otherPath, kFingerprint, 0, &restored));
}

void TestNovelChapterCache::removeClearsWholeBook()
{
    const QString otherPath = QStringLiteral("/书架/留下.txt");
    QVERIFY(
        NovelChapterCache::saveEpub(kConnectionId, kPath, kFingerprint, 0, {QStringLiteral("a")}));
    QVERIFY(NovelChapterCache::saveEpub(kConnectionId, otherPath, kFingerprint, 0,
                                        {QStringLiteral("b")}));

    QCOMPARE(NovelChapterCache::remove(kConnectionId, kPath), 1);
    QCOMPARE(NovelChapterCache::count(), 1);

    QStringList restored;
    QVERIFY(NovelChapterCache::loadEpub(kConnectionId, otherPath, kFingerprint, 0, &restored));
}

QTEST_GUILESS_MAIN(TestNovelChapterCache)
#include "tst_novelchaptercache.moc"
