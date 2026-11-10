// 「正在阅读」首页展示口径单测（PC-209 / PC-705）
//
// 覆盖 ReadingEntry：百分比文案、类型/完成态文案、相对时间分支、
// 以及从 ProgressRecord 转换时的续播点与标题兜底。
// 相对时间用固定「现在」计算，不依赖机器时间。

#include <QDateTime>
#include <QtTest>

#include "core/history/ReadingEntry.h"

using namespace myhub;

namespace {

/// 固定「现在」：2026-11-04 12:00 本地时间
qint64 nowMs()
{
    return QDateTime(QDate(2026, 11, 4), QTime(12, 0)).toMSecsSinceEpoch();
}

qint64 atLocal(int year, int month, int day, int hour)
{
    return QDateTime(QDate(year, month, day), QTime(hour, 0)).toMSecsSinceEpoch();
}

qint64 minutesAgo(int minutes)
{
    return nowMs() - qint64(minutes) * 60 * 1000;
}

ProgressRecord recordFor(const QString &path, const QString &mediaType, double percent)
{
    ProgressRecord record;
    record.connectionId = QStringLiteral("conn-1");
    record.path = path;
    record.mediaType = mediaType;
    record.title = QStringLiteral("demo");
    record.percent = percent;
    record.updatedAt = nowMs();
    return record;
}

} // namespace

class TestReadingEntry : public QObject
{
    Q_OBJECT

private slots:
    // ---- 百分比 ----
    void percentText_data();
    void percentText();

    // ---- 文案 ----
    void kindText();
    void finishedText();

    // ---- 相对时间 ----
    void relativeTime_data();
    void relativeTime();

    // ---- 记录转换 ----
    void fromRecordFillsDisplayFields();
    void fromRecordFallsBackToFileName();
    void finishedRecordShowsCompleteTextAndRestarts();
    void fromRecordsKeepsOrder();
};

void TestReadingEntry::percentText_data()
{
    QTest::addColumn<double>("percent");
    QTest::addColumn<QString>("expected");

    QTest::newRow("zero") << 0.0 << QStringLiteral("0%");
    QTest::newRow("round down") << 0.654 << QStringLiteral("65%");
    QTest::newRow("round up") << 0.655 << QStringLiteral("66%");
    QTest::newRow("full") << 1.0 << QStringLiteral("100%");
    QTest::newRow("over 1 clamped") << 1.8 << QStringLiteral("100%");
    QTest::newRow("negative clamped") << -0.3 << QStringLiteral("0%");
}

void TestReadingEntry::percentText()
{
    QFETCH(double, percent);
    QFETCH(QString, expected);

    QCOMPARE(ReadingEntry::percentTextFor(percent), expected);
}

void TestReadingEntry::kindText()
{
    QCOMPARE(ReadingEntry::kindTextFor(QStringLiteral("video")), QStringLiteral("视频"));
    QCOMPARE(ReadingEntry::kindTextFor(QStringLiteral("audio")), QStringLiteral("音频"));
    QCOMPARE(ReadingEntry::kindTextFor(QStringLiteral("novel")), QStringLiteral("小说"));
    QCOMPARE(ReadingEntry::kindTextFor(QStringLiteral("comic")), QStringLiteral("漫画"));
    QCOMPARE(ReadingEntry::kindTextFor(QStringLiteral("text")), QStringLiteral("文本"));
    QCOMPARE(ReadingEntry::kindTextFor(QStringLiteral("")), QStringLiteral("文件"));
}

void TestReadingEntry::finishedText()
{
    QCOMPARE(ReadingEntry::finishedTextFor(QStringLiteral("video")), QStringLiteral("已看完"));
    QCOMPARE(ReadingEntry::finishedTextFor(QStringLiteral("audio")), QStringLiteral("已听完"));
    QCOMPARE(ReadingEntry::finishedTextFor(QStringLiteral("novel")), QStringLiteral("已读完"));
    QCOMPARE(ReadingEntry::finishedTextFor(QStringLiteral("comic")), QStringLiteral("已读完"));
    QCOMPARE(ReadingEntry::finishedTextFor(QStringLiteral("text")), QStringLiteral("已读完"));
    QCOMPARE(ReadingEntry::finishedTextFor(QStringLiteral("image")), QStringLiteral("已完成"));
}

void TestReadingEntry::relativeTime_data()
{
    QTest::addColumn<qint64>("updatedAt");
    QTest::addColumn<QString>("expected");

    QTest::newRow("no record") << qint64(0) << QStringLiteral("未知");
    QTest::newRow("future") << nowMs() + 60000 << QStringLiteral("刚刚");
    QTest::newRow("30s") << nowMs() - 30000 << QStringLiteral("刚刚");
    QTest::newRow("59s boundary") << nowMs() - 59000 << QStringLiteral("刚刚");
    QTest::newRow("1min") << minutesAgo(1) << QStringLiteral("1 分钟前");
    QTest::newRow("59min") << minutesAgo(59) << QStringLiteral("59 分钟前");
    QTest::newRow("2h") << minutesAgo(120) << QStringLiteral("2 小时前");
    QTest::newRow("yesterday") << atLocal(2026, 11, 3, 20) << QStringLiteral("昨天");
    QTest::newRow("3 days") << atLocal(2026, 11, 1, 9) << QStringLiteral("3 天前");
    QTest::newRow("last week") << atLocal(2026, 10, 26, 9) << QStringLiteral("上周");
    QTest::newRow("3 weeks") << atLocal(2026, 10, 14, 9) << QStringLiteral("3 周前");
    QTest::newRow("old record") << atLocal(2026, 8, 1, 9) << QStringLiteral("2026/8/1");
}

void TestReadingEntry::relativeTime()
{
    QFETCH(qint64, updatedAt);
    QFETCH(QString, expected);

    QCOMPARE(ReadingEntry::relativeTimeFor(updatedAt, nowMs()), expected);
}

void TestReadingEntry::fromRecordFillsDisplayFields()
{
    ProgressRecord record =
        recordFor(QStringLiteral("C:/media/a.mkv"), QStringLiteral("video"), 0.42);
    record.progress.insert(QStringLiteral("positionMs"), qint64(42000));
    record.progress.insert(QStringLiteral("durationMs"), qint64(100000));

    const ReadingEntry entry = ReadingEntry::fromRecord(record, nowMs());
    QCOMPARE(entry.connectionId, QStringLiteral("conn-1"));
    QCOMPARE(entry.path, QStringLiteral("C:/media/a.mkv"));
    QCOMPARE(entry.title, QStringLiteral("demo"));
    QCOMPARE(entry.mediaKind, QStringLiteral("video"));
    QCOMPARE(entry.kindText, QStringLiteral("视频"));
    QCOMPARE(entry.percentText, QStringLiteral("42%"));
    QCOMPARE(entry.relativeTime, QStringLiteral("刚刚"));
    QCOMPARE(entry.resumeMs, qint64(42000));
    QVERIFY(!entry.finished);
}

void TestReadingEntry::fromRecordFallsBackToFileName()
{
    ProgressRecord record = recordFor(QStringLiteral("/books/三体.epub"), QString(), 0.1);
    record.title.clear();

    const ReadingEntry entry = ReadingEntry::fromRecord(record, nowMs());
    QCOMPARE(entry.title, QStringLiteral("三体.epub"));
    // mediaType 缺失时按扩展名兜底
    QCOMPARE(entry.mediaKind, QStringLiteral("novel"));
    QCOMPARE(entry.kindText, QStringLiteral("小说"));
}

void TestReadingEntry::finishedRecordShowsCompleteTextAndRestarts()
{
    ProgressRecord record =
        recordFor(QStringLiteral("C:/media/done.mkv"), QStringLiteral("video"), 0.99);
    record.finished = true;
    record.progress.insert(QStringLiteral("positionMs"), qint64(99000));
    record.progress.insert(QStringLiteral("durationMs"), qint64(100000));

    const ReadingEntry entry = ReadingEntry::fromRecord(record, nowMs());
    QVERIFY(entry.finished);
    QCOMPARE(entry.percent, 1.0);
    QCOMPARE(entry.percentText, QStringLiteral("100%"));
    QCOMPARE(entry.finishedText, QStringLiteral("已看完"));
    QCOMPARE(entry.resumeMs, qint64(0)); // 已看完 → 再打开从头播
}

void TestReadingEntry::fromRecordsKeepsOrder()
{
    QList<ProgressRecord> records;
    records.append(recordFor(QStringLiteral("C:/media/new.mkv"), QStringLiteral("video"), 0.2));
    records.append(recordFor(QStringLiteral("C:/media/old.mkv"), QStringLiteral("audio"), 0.8));

    const auto entries = ReadingEntry::fromRecords(records, nowMs());
    QCOMPARE(entries.size(), 2);
    QCOMPARE(entries.at(0).path, QStringLiteral("C:/media/new.mkv"));
    QCOMPARE(entries.at(1).path, QStringLiteral("C:/media/old.mkv"));
    QCOMPARE(entries.at(1).kindText, QStringLiteral("音频"));
}

QTEST_MAIN(TestReadingEntry)
#include "tst_readingentry.moc"
