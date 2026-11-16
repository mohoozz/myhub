// txt 流式分章 + 按章加载 + 索引缓存（§5.1 PC-201 / PC-202）
//
// 用内存 RangeSource 喂字节，不碰真实文件：
//   - 分章：UTF-8 / GB18030 / UTF-16LE，小分块（13 字节）逼出跨块拼接
//   - 偏移：每章 startOffset 必须能直接切回原文（字节偏移，不是字符下标）
//   - 加载：只读该章区间，章名行不重复进正文
//   - 缓存：指纹命中复用、文件变了失效、改名/删目录同步

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QtTest>

#include "core/database/AppDatabase.h"
#include "core/novel/ChapterRules.h"
#include "core/novel/NovelIndex.h"
#include "core/novel/NovelIndexStore.h"
#include "core/novel/TxtChapterLoader.h"
#include "core/novel/TxtIndexer.h"
#include "core/utils/AppPaths.h"

using namespace myhub;

namespace {

/// 内存 RangeSource：按请求区间切片返回，记录请求次数与区间
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
        if (start < 0 || length <= 0 || start >= m_data.size()) {
            cb(QByteArray(), StorageError(StorageError::InvalidPath, QStringLiteral("区间非法")));
            return;
        }
        cb(m_data.mid(static_cast<int>(start), static_cast<int>(length)), StorageError());
    }

    const QByteArray &data() const { return m_data; }

    int requests = 0;

private:
    QByteArray m_data;
};

/// 生成一本「章节 + 正文」的 txt
QString novelText(int chapterCount, const QString &lineEnding = QStringLiteral("\n"))
{
    QString text;
    for (int i = 1; i <= chapterCount; ++i) {
        text += QStringLiteral("第%1章 标题%1").arg(i) + lineEnding;
        text += QStringLiteral("这是第%1章的正文第一行，用来撑长一点。").arg(i) + lineEnding;
        text += QStringLiteral("这是第%1章的正文第二行。").arg(i) + lineEnding;
    }
    return text;
}

/// 同步跑完索引（RangeSource 回调是同步的，事件循环都不用转）
TxtIndexer::Result indexOf(RangeSource *source, qint64 probeBytes = 256, qint64 chunkBytes = 13)
{
    TxtIndexer indexer(source);
    indexer.setProbeBytes(probeBytes);
    indexer.setChunkBytes(chunkBytes);

    TxtIndexer::Result captured;
    bool done = false;
    indexer.start(
        [&captured, &done](const TxtIndexer::Result &result) {
            captured = result;
            done = true;
        },
        {});
    if (!done) {
        captured.error =
            StorageError(StorageError::Underlying, QStringLiteral("索引未在同步回调里完成"));
    }
    return captured;
}

} // namespace

class TestTxtIndexer : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void init();

    // ---- 分章 ----
    void indexesUtf8Chapters();
    void chapterOffsetsSliceBackToTitle();
    void handlesCrlf();
    void detectsGb18030();
    void detectsUtf16Le();
    void fallsBackWhenNoChapterFound();
    void reportsProgress();

    // ---- 按章加载 ----
    void loadsOnlyRequestedChapter();
    void chapterTitleLineIsNotDuplicated();
    void paragraphAnchorRoundTrip();
    void loadRejectsBadRange();

    // ---- 索引本身 ----
    void chapterAtUsesBinarySearch();
    void fingerprintTolerance();

    // ---- 缓存 ----
    void storeRoundTrip();
    void storeRejectsChangedFile();
    void storeFollowsRenameAndDelete();
    void decodeChaptersRejectsBrokenJson();

private:
    QTemporaryDir m_dir;
};

void TestTxtIndexer::initTestCase()
{
    QStandardPaths::setTestModeEnabled(true);
    AppPaths::initializeAll();
    QVERIFY(m_dir.isValid());
    QVERIFY(AppDatabase::instance().open(m_dir.filePath(QStringLiteral("myhub.sqlite"))));
}

void TestTxtIndexer::init()
{
    QVERIFY(AppDatabase::instance().execute(QStringLiteral("DELETE FROM novelIndex")));
}

// ---------------------------------------------------------------- 分章

void TestTxtIndexer::indexesUtf8Chapters()
{
    const QString text = novelText(12);
    MemoryRangeSource source(text.toUtf8());

    const TxtIndexer::Result result = indexOf(&source);
    QVERIFY2(result.ok(), qPrintable(result.error.message()));
    QCOMPARE(result.index.encoding, TextCodec::Utf8);
    QCOMPARE(result.index.count(), 12);
    QCOMPARE(result.index.chapterTitle(0), QStringLiteral("第1章 标题1"));
    QCOMPARE(result.index.chapterTitle(11), QStringLiteral("第12章 标题12"));
    QCOMPARE(result.index.chapterStart(0), qint64(0));
    QCOMPARE(result.index.fileSize, qint64(source.data().size()));
    // 分块读了不止一次：否则「跨块不漂移」这条用例等于没测
    QVERIFY(source.requests > 5);
}

void TestTxtIndexer::chapterOffsetsSliceBackToTitle()
{
    const QString text = novelText(9);
    const QByteArray data = text.toUtf8();
    MemoryRangeSource source(data);

    const TxtIndexer::Result result = indexOf(&source);
    QVERIFY(result.ok());
    QCOMPARE(result.index.count(), 9);

    for (int i = 0; i < result.index.count(); ++i) {
        // 章偏移必须能直接拿去 Range 读取：切出来的字节以章名开头
        const QByteArray slice = data.mid(static_cast<int>(result.index.chapterStart(i)),
                                          result.index.chapterTitle(i).toUtf8().size());
        QCOMPARE(QString::fromUtf8(slice), result.index.chapterTitle(i));
        QVERIFY(result.index.chapterStart(i) < result.index.chapterEnd(i));
    }
}

void TestTxtIndexer::handlesCrlf()
{
    MemoryRangeSource source(novelText(6, QStringLiteral("\r\n")).toUtf8());
    const TxtIndexer::Result result = indexOf(&source);
    QVERIFY(result.ok());
    QCOMPARE(result.index.count(), 6);
    // \r 不能被算进标题，否则目录里每行末尾都带一个不可见字符
    QCOMPARE(result.index.chapterTitle(0), QStringLiteral("第1章 标题1"));
}

void TestTxtIndexer::detectsGb18030()
{
    const QString text = novelText(8);
    const TextCodec::Encoded encoded = TextCodec::encode(text, TextCodec::Gb18030);
    QVERIFY(!encoded.fellBackToUtf8);
    MemoryRangeSource source(encoded.data);

    const TxtIndexer::Result result = indexOf(&source);
    QVERIFY(result.ok());
    QCOMPARE(result.index.encoding, TextCodec::Gb18030);
    QCOMPARE(result.index.count(), 8);
    QCOMPARE(result.index.chapterTitle(0), QStringLiteral("第1章 标题1"));

    // 整本只探测一次编码：按章读取必须复用同一结论，不能逐块重探
    const QByteArray slice = source.data().mid(static_cast<int>(result.index.chapterStart(3)), 64);
    QCOMPARE(
        TextCodec::decodeAs(slice, result.index.encoding).text.section(QLatin1Char('\n'), 0, 0),
        QStringLiteral("第4章 标题4"));
}

void TestTxtIndexer::detectsUtf16Le()
{
    const QString text = novelText(8);
    // UTF-16 带 BOM（Windows 记事本的实际产物）：无 BOM 且几乎全是汉字时，
    // 「零字节集中在同一侧」的启发式本来就判不出来，不该用它当测试前提
    const QByteArray data = TextCodec::encode(text, TextCodec::Utf16LE, true).data;
    MemoryRangeSource source(data);

    // 头块 512 字节（够 BOM 判定）→ 后续 13 字节一块（奇数，逼出半个代码单元的跨块拼接）
    const TxtIndexer::Result result = indexOf(&source, 512, 13);
    QVERIFY2(result.ok(), qPrintable(result.error.message()));
    QCOMPARE(result.index.encoding, TextCodec::Utf16LE);
    QCOMPARE(result.index.count(), 8);

    for (int i = 0; i < result.index.count(); ++i) {
        // 章偏移按字节算：奇数块切在代码单元中间也不会把标题切坏
        const QByteArray slice = data.mid(static_cast<int>(result.index.chapterStart(i)), 200);
        QVERIFY(TextCodec::decodeAs(slice, TextCodec::Utf16LE)
                    .text.startsWith(result.index.chapterTitle(i)));
    }
}

void TestTxtIndexer::fallsBackWhenNoChapterFound()
{
    const QByteArray prose =
        QStringLiteral("这是一段没有任何章节标题的散文。\n第二行。\n").toUtf8();
    MemoryRangeSource source(prose);

    const TxtIndexer::Result result = indexOf(&source, 4096, 4096);
    QVERIFY2(result.ok(), qPrintable(result.error.message()));
    QCOMPARE(result.index.count(), 0);
    QCOMPARE(result.index.fileSize, qint64(prose.size()));
    QVERIFY(result.index.ruleId.isEmpty());

    // 上层用「整本单章」兜底，阅读器永远只处理「有目录」一种情况
    const NovelIndex fallback = NovelIndex::singleChapter(prose.size(), TextCodec::Utf8);
    QCOMPARE(fallback.count(), 1);
    QCOMPARE(fallback.chapterStart(0), qint64(0));
    QCOMPARE(fallback.chapterEnd(0), qint64(prose.size()));
}

void TestTxtIndexer::reportsProgress()
{
    MemoryRangeSource source(novelText(20).toUtf8());
    TxtIndexer indexer(&source);
    indexer.setProbeBytes(64);
    indexer.setChunkBytes(37);

    QVector<double> ratios;
    indexer.start([](const TxtIndexer::Result &) {},
                  [&ratios](double ratio) { ratios.append(ratio); });

    QVERIFY(ratios.size() >= 2);
    // 进度单调不减，且最后一帧落在 100%
    for (int i = 1; i < ratios.size(); ++i) {
        QVERIFY(ratios.at(i) >= ratios.at(i - 1));
    }
    QVERIFY(qAbs(ratios.last() - 1.0) < 1e-9);
}

// ---------------------------------------------------------------- 按章加载

void TestTxtIndexer::loadsOnlyRequestedChapter()
{
    MemoryRangeSource source(novelText(6).toUtf8());
    const TxtIndexer::Result result = indexOf(&source);
    QVERIFY(result.ok());

    source.requests = 0;
    TxtChapterText loaded;
    StorageError error;
    TxtChapterLoader::load(&source, result.index, 2,
                           [&loaded, &error](TxtChapterText text, StorageError err) {
                               loaded = text;
                               error = err;
                           });

    QVERIFY2(error.isNull(), qPrintable(error.message()));
    QCOMPARE(source.requests, 1); // 一次 Range，不是整本
    QCOMPARE(loaded.title, QStringLiteral("第3章 标题3"));
    QCOMPARE(loaded.encoding, TextCodec::Utf8);
    QVERIFY(!loaded.isEmpty());
    QVERIFY(!loaded.truncated);
    QCOMPARE(loaded.start, result.index.chapterStart(2));
    QCOMPARE(loaded.end, result.index.chapterEnd(2));
    QVERIFY(loaded.bodyText().contains(QStringLiteral("正文第二行")));

    // 行偏移是文件绝对字节偏移，可直接切回原文
    const TxtLine &first = loaded.lines.constFirst();
    QCOMPARE(first.start, loaded.start);
    QCOMPARE(QString::fromUtf8(source.data().mid(static_cast<int>(first.start),
                                                 static_cast<int>(first.end - first.start))),
             first.text);
}

void TestTxtIndexer::chapterTitleLineIsNotDuplicated()
{
    MemoryRangeSource source(novelText(3).toUtf8());
    const TxtIndexer::Result result = indexOf(&source);
    QVERIFY(result.ok());

    TxtChapterText loaded;
    TxtChapterLoader::load(&source, result.index, 0,
                           [&loaded](TxtChapterText text, StorageError) { loaded = text; });

    QCOMPARE(loaded.firstBodyLine, 1); // 首行就是章名
    QVERIFY(!loaded.bodyText().startsWith(QStringLiteral("第1章")));
    QVERIFY(loaded.bodyText().startsWith(QStringLiteral("这是第1章的正文第一行")));
}

void TestTxtIndexer::paragraphAnchorRoundTrip()
{
    MemoryRangeSource source(novelText(4).toUtf8());
    const TxtIndexer::Result result = indexOf(&source);
    QVERIFY(result.ok());

    TxtChapterText loaded;
    TxtChapterLoader::load(&source, result.index, 1,
                           [&loaded](TxtChapterText text, StorageError) { loaded = text; });

    // 段落表就是「去掉章名行之后的正文行」，阅读器一段一个 item
    QCOMPARE(loaded.paragraphCount(), loaded.lines.size() - loaded.firstBodyLine);
    const QStringList paragraphs = loaded.paragraphs();
    QCOMPARE(paragraphs.size(), loaded.paragraphCount());
    QVERIFY(paragraphs.constFirst().startsWith(QStringLiteral("这是第2章的正文第一行")));

    // 段落 ↔ 字节偏移必须一一还原：读写两侧都靠这张表，
    // 一旦有 1 段漂移，重开这本书就会停在相邻的句子上
    for (int i = 0; i < paragraphs.size(); ++i) {
        const qint64 byte = loaded.byteAtParagraph(i);
        QVERIFY(byte > 0);
        QCOMPARE(loaded.paragraphAtByte(byte), i);
        // 偏移必须落在段首，切出来的原文就是这一段
        const TxtLine &line = loaded.lines.at(loaded.firstBodyLine + i);
        QCOMPARE(byte, line.start);
        QCOMPARE(QString::fromUtf8(
                     source.data().mid(static_cast<int>(byte), static_cast<int>(line.end - byte))),
                 paragraphs.at(i));
    }

    // 越界与章名行：锚点落在章名上就当第一段，不能返回 -1 把读者晾在空白处
    QCOMPARE(loaded.paragraphAtByte(loaded.start), 0);
    QCOMPARE(loaded.byteAtParagraph(-1), qint64(-1));
    QCOMPARE(loaded.byteAtParagraph(paragraphs.size()), qint64(-1));
}

void TestTxtIndexer::loadRejectsBadRange()
{
    MemoryRangeSource source(novelText(3).toUtf8());
    const TxtIndexer::Result result = indexOf(&source);
    QVERIFY(result.ok());

    int calls = 0;
    StorageError error;
    TxtChapterLoader::load(&source, result.index, 99,
                           [&calls, &error](TxtChapterText, StorageError err) {
                               ++calls;
                               error = err;
                           });
    QCOMPARE(calls, 1);
    QVERIFY(!error.isNull());
    QCOMPARE(error.kind(), StorageError::InvalidPath);
}

// ---------------------------------------------------------------- 索引本身

void TestTxtIndexer::chapterAtUsesBinarySearch()
{
    NovelIndex index;
    index.fileSize = 400;
    QVERIFY(!index.isValid());
    QCOMPARE(index.chapterAt(0), -1);

    index.chapters = {NovelChapter{QStringLiteral("a"), 0, {}},
                      NovelChapter{QStringLiteral("b"), 100, {}},
                      NovelChapter{QStringLiteral("c"), 200, {}}};
    QVERIFY(index.isValid());
    QCOMPARE(index.chapterAt(0), 0);
    QCOMPARE(index.chapterAt(99), 0);
    QCOMPARE(index.chapterAt(100), 1);
    QCOMPARE(index.chapterAt(199), 1);
    QCOMPARE(index.chapterAt(200), 2);
    QCOMPARE(index.chapterAt(10000), 2);
    QCOMPARE(index.chapterEnd(2), qint64(400));
    QCOMPARE(index.chapterStart(-1), qint64(-1));
    QCOMPARE(index.chapterEnd(5), qint64(-1));
    QVERIFY(qAbs(index.percentAt(200) - 0.5) < 1e-9);
}

void TestTxtIndexer::fingerprintTolerance()
{
    NovelIndex index;
    index.fileSize = 1000;
    index.modTime = 10000;
    index.chapters = {NovelChapter{QStringLiteral("a"), 0, {}}};

    QVERIFY(index.matchesFile(1000, 10000));
    QVERIFY(index.matchesFile(1000, 11000)); // 2 秒内的精度差可接受（FAT/SMB）
    QVERIFY(!index.matchesFile(1000, 50000));
    QVERIFY(!index.matchesFile(999, 10000));
    QVERIFY(index.matchesFile(1000, 0)); // 拿不到 modTime 时只认大小
    // 空索引（没章节）永远不算命中，否则「整本单章」会被当成真目录缓存下来
    NovelIndex empty;
    empty.fileSize = 1000;
    QVERIFY(!empty.matchesFile(1000, 0));
}

// ---------------------------------------------------------------- 缓存

void TestTxtIndexer::storeRoundTrip()
{
    MemoryRangeSource source(novelText(4).toUtf8());
    const TxtIndexer::Result result = indexOf(&source);
    QVERIFY(result.ok());

    const QString connection = QStringLiteral("conn-1");
    const QString path = QStringLiteral("/novels/a.txt");
    QVERIFY(NovelIndexStore::save(connection, path, result.index));
    QCOMPARE(NovelIndexStore::count(), 1);

    NovelIndex cached;
    QVERIFY(NovelIndexStore::load(connection, path, result.index.fileSize, result.index.modTime,
                                  &cached));
    QCOMPARE(cached.count(), result.index.count());
    QCOMPARE(cached.encoding, result.index.encoding);
    QCOMPARE(cached.ruleId, result.index.ruleId);
    QCOMPARE(cached.chapterTitle(2), result.index.chapterTitle(2));
    QCOMPARE(cached.chapterStart(2), result.index.chapterStart(2));

    // 保存两次只更新同一行（唯一索引），不留重复记录
    QVERIFY(NovelIndexStore::save(connection, path, result.index));
    QCOMPARE(NovelIndexStore::count(), 1);
}

void TestTxtIndexer::storeRejectsChangedFile()
{
    MemoryRangeSource source(novelText(4).toUtf8());
    const TxtIndexer::Result result = indexOf(&source);
    const QString path = QStringLiteral("/novels/b.txt");
    QVERIFY(NovelIndexStore::save(QStringLiteral("conn-1"), path, result.index));

    NovelIndex cached;
    // 文件被追加过：指纹不符，旧偏移全部作废
    QVERIFY(!NovelIndexStore::load(QStringLiteral("conn-1"), path, result.index.fileSize + 100,
                                   result.index.modTime, &cached));
    // 但「先展示上次目录」这条路仍然给得出来
    QVERIFY(NovelIndexStore::find(QStringLiteral("conn-1"), path, &cached));
    QCOMPARE(cached.count(), 4);
}

void TestTxtIndexer::storeFollowsRenameAndDelete()
{
    MemoryRangeSource source(novelText(2).toUtf8());
    const TxtIndexer::Result result = indexOf(&source);
    const QString connection = QStringLiteral("conn-1");

    QVERIFY(NovelIndexStore::save(connection, QStringLiteral("/lib/a.txt"), result.index));
    QVERIFY(NovelIndexStore::save(connection, QStringLiteral("/lib/sub/b.txt"), result.index));
    QVERIFY(NovelIndexStore::save(connection, QStringLiteral("/other/c.txt"), result.index));
    QCOMPARE(NovelIndexStore::count(), 3);

    // 目录改名：子孙前缀一起改写
    QCOMPARE(
        NovelIndexStore::renamePath(connection, QStringLiteral("/lib"), QStringLiteral("/books")),
        2);
    NovelIndex moved;
    QVERIFY(NovelIndexStore::find(connection, QStringLiteral("/books/sub/b.txt"), &moved));
    QVERIFY(!NovelIndexStore::find(connection, QStringLiteral("/lib/sub/b.txt"), &moved));

    // 删目录：只清该子树的缓存，别的目录不受影响
    QCOMPARE(NovelIndexStore::removeSubtree(connection, QStringLiteral("/books")), 2);
    QCOMPARE(NovelIndexStore::count(), 1);
    QVERIFY(NovelIndexStore::find(connection, QStringLiteral("/other/c.txt"), &moved));
}

void TestTxtIndexer::decodeChaptersRejectsBrokenJson()
{
    QVector<NovelChapter> chapters;
    QVERIFY(!NovelIndexStore::decodeChapters(QStringLiteral("{}"), &chapters));
    QVERIFY(!NovelIndexStore::decodeChapters(QStringLiteral("[]"), &chapters));
    QVERIFY(!NovelIndexStore::decodeChapters(QStringLiteral("not json"), &chapters));

    // 偏移不递增的缓存是坏数据：宁可重扫，也不能让二分查出乱章
    const QByteArray broken = R"([{"title":"a","startOffset":100},{"title":"b","startOffset":50}])";
    QVERIFY(!NovelIndexStore::decodeChapters(QString::fromUtf8(broken), &chapters));

    // 合法缓存：首章的 ruleID 是整本的规则（与 iOS ChapterInfo 约定一致）
    NovelIndex index;
    index.ruleId = QStringLiteral("zh_di_zhang");
    index.chapters = {NovelChapter{QStringLiteral("a"), 0, {}},
                      NovelChapter{QStringLiteral("b"), 100, {}}};
    const QJsonArray array =
        QJsonDocument::fromJson(NovelIndexStore::encodeChapters(index).toUtf8()).array();
    QCOMPARE(array.size(), 2);
    QVERIFY(array.at(0).toObject().contains(QStringLiteral("ruleID")));
    QVERIFY(!array.at(1).toObject().contains(QStringLiteral("ruleID")));

    QVERIFY(NovelIndexStore::decodeChapters(NovelIndexStore::encodeChapters(index), &chapters));
    QCOMPARE(chapters.size(), 2);
    QCOMPARE(chapters.at(1).ruleId, QStringLiteral("zh_di_zhang"));
}

QTEST_MAIN(TestTxtIndexer)
#include "tst_txtindexer.moc"
