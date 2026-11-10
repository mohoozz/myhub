#include "core/player/SubtitleMatcher.h"

#include <QTest>

using myhub::SubtitleMatcher;

class TestSubtitleMatcher : public QObject
{
    Q_OBJECT

private slots:
    void isSubtitleFile_data();
    void isSubtitleFile();
    void exactMatchWins();
    void language_suffix_data();
    void language_suffix();
    void chinesePreferredOverOtherLanguage();
    void rejectsLookalikes();
    void picksDeterministicallyWhenTied();
    void noMatchReturnsEmpty();
    void pathInputHandled();
};

void TestSubtitleMatcher::isSubtitleFile_data()
{
    QTest::addColumn<QString>("name");
    QTest::addColumn<bool>("expected");

    QTest::newRow("srt") << QStringLiteral("a.srt") << true;
    QTest::newRow("ass") << QStringLiteral("a.ASS") << true;
    QTest::newRow("ssa") << QStringLiteral("a.ssa") << true;
    QTest::newRow("vtt") << QStringLiteral("a.vtt") << true;
    QTest::newRow("sub") << QStringLiteral("a.sub") << true;
    QTest::newRow("mkv") << QStringLiteral("a.mkv") << false;
    QTest::newRow("no-ext") << QStringLiteral("a") << false;
    QTest::newRow("empty") << QString() << false;
}

void TestSubtitleMatcher::isSubtitleFile()
{
    QFETCH(QString, name);
    QFETCH(bool, expected);
    QCOMPARE(SubtitleMatcher::isSubtitleFile(name), expected);
}

void TestSubtitleMatcher::exactMatchWins()
{
    QCOMPARE(SubtitleMatcher::score(QStringLiteral("影片"), QStringLiteral("影片.srt")), 100);
    // 大小写不敏感
    QCOMPARE(SubtitleMatcher::score(QStringLiteral("Movie"), QStringLiteral("movie.srt")), 100);
}

void TestSubtitleMatcher::language_suffix_data()
{
    QTest::addColumn<QString>("subtitle");
    QTest::addColumn<int>("expected");

    // 带语言后缀：基础分 80，中文标记 +10
    QTest::newRow("en") << QStringLiteral("影片.en.srt") << 80;
    QTest::newRow("zh") << QStringLiteral("影片.zh.srt") << 90;
    QTest::newRow("zh-CN") << QStringLiteral("影片.zh-CN.srt") << 90;
    QTest::newRow("chs") << QStringLiteral("影片.chs.ass") << 90;
    QTest::newRow("cht") << QStringLiteral("影片.cht.srt") << 90;
    QTest::newRow("multi-tag") << QStringLiteral("影片.chs.forced.ass") << 90;
}

void TestSubtitleMatcher::language_suffix()
{
    QFETCH(QString, subtitle);
    QFETCH(int, expected);
    QCOMPARE(SubtitleMatcher::score(QStringLiteral("影片"), subtitle), expected);
}

void TestSubtitleMatcher::chinesePreferredOverOtherLanguage()
{
    const QStringList files{QStringLiteral("影片.en.srt"), QStringLiteral("影片.zh.srt")};
    QCOMPARE(SubtitleMatcher::pick(QStringLiteral("影片"), files), QStringLiteral("影片.zh.srt"));
}

void TestSubtitleMatcher::rejectsLookalikes()
{
    // 这些都不是「同名后缀」，给错字幕比不给更糟
    QCOMPARE(SubtitleMatcher::score(QStringLiteral("影片"), QStringLiteral("影片2.srt")), 0);
    QCOMPARE(SubtitleMatcher::score(QStringLiteral("影片"), QStringLiteral("影片-加长版.srt")), 0);
    QCOMPARE(SubtitleMatcher::score(QStringLiteral("影片"), QStringLiteral("另一部.srt")), 0);
    // 扩展名不在白名单
    QCOMPARE(SubtitleMatcher::score(QStringLiteral("影片"), QStringLiteral("影片.txt")), 0);
}

void TestSubtitleMatcher::picksDeterministicallyWhenTied()
{
    // 同分取文件名升序第一个，不依赖目录枚举顺序
    const QStringList forward{QStringLiteral("影片.en.srt"), QStringLiteral("影片.en.ass")};
    const QStringList backward{QStringLiteral("影片.en.ass"), QStringLiteral("影片.en.srt")};
    QCOMPARE(SubtitleMatcher::pick(QStringLiteral("影片"), forward), QStringLiteral("影片.en.ass"));
    QCOMPARE(SubtitleMatcher::pick(QStringLiteral("影片"), backward),
             QStringLiteral("影片.en.ass"));
}

void TestSubtitleMatcher::noMatchReturnsEmpty()
{
    const QStringList files{QStringLiteral("影片.mkv"), QStringLiteral("封面.jpg")};
    QVERIFY(SubtitleMatcher::pick(QStringLiteral("影片"), files).isEmpty());
    QVERIFY(SubtitleMatcher::pick(QString(), files).isEmpty());
}

void TestSubtitleMatcher::pathInputHandled()
{
    // 调用方可能直接给完整路径（远程条目 name 不带路径，本地 entryList 也不带）
    QCOMPARE(SubtitleMatcher::score(QStringLiteral("影片"), QStringLiteral("/movies/影片.srt")),
             100);
}

QTEST_APPLESS_MAIN(TestSubtitleMatcher)
#include "tst_subtitlematcher.moc"
