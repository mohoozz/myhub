#include "core/utils/TrackName.h"

#include <QTest>

using myhub::TrackName;

class TestTrackName : public QObject
{
    Q_OBJECT

private slots:
    void plainTitle();
    void artistTitle();
    void dashes_data();
    void dashes();
    void trackNumberPrefix();
    void trackNumberWithDash();
    void keepsHyphenInsideArtist();
    void pathIsReducedToFileName();
    void blankInputFallsBackToEmpty();
};

void TestTrackName::plainTitle()
{
    const auto parts = TrackName::parse(QStringLiteral("晴天.mp3"));
    QCOMPARE(parts.artist, QString());
    QCOMPARE(parts.title, QStringLiteral("晴天"));
}

void TestTrackName::artistTitle()
{
    const auto parts = TrackName::parse(QStringLiteral("周杰伦 - 晴天.flac"));
    QCOMPARE(parts.artist, QStringLiteral("周杰伦"));
    QCOMPARE(parts.title, QStringLiteral("晴天"));
}

void TestTrackName::dashes_data()
{
    QTest::addColumn<QString>("input");
    QTest::addColumn<QString>("artist");
    QTest::addColumn<QString>("title");

    // 半角 / en dash / em dash 都带空格；全角连字符允许无空格
    QTest::newRow("ascii") << QStringLiteral("Artist - Title.mp3") << QStringLiteral("Artist")
                           << QStringLiteral("Title");
    QTest::newRow("en-dash") << QStringLiteral("Artist – Title.mp3") << QStringLiteral("Artist")
                             << QStringLiteral("Title");
    QTest::newRow("em-dash") << QStringLiteral("Artist — Title.mp3") << QStringLiteral("Artist")
                             << QStringLiteral("Title");
    QTest::newRow("full-width") << QStringLiteral("Artist－Title.mp3") << QStringLiteral("Artist")
                                << QStringLiteral("Title");
    QTest::newRow("double-space") << QStringLiteral("Artist  -  Title.mp3")
                                  << QStringLiteral("Artist") << QStringLiteral("Title");
    // 多次出现只按第一处切分
    QTest::newRow("two-dashes") << QStringLiteral("Artist - Title - Live.mp3")
                                << QStringLiteral("Artist") << QStringLiteral("Title - Live");
}

void TestTrackName::dashes()
{
    QFETCH(QString, input);
    QFETCH(QString, artist);
    QFETCH(QString, title);

    const auto parts = TrackName::parse(input);
    QCOMPARE(parts.artist, artist);
    QCOMPARE(parts.title, title);
}

void TestTrackName::trackNumberPrefix()
{
    const auto parts = TrackName::parse(QStringLiteral("01. 晴天.mp3"));
    QCOMPARE(parts.artist, QString());
    QCOMPARE(parts.title, QStringLiteral("晴天"));

    const auto bracketed = TrackName::parse(QStringLiteral("[03] 晴天.mp3"));
    QCOMPARE(bracketed.title, QStringLiteral("晴天"));
}

void TestTrackName::trackNumberWithDash()
{
    // 音轨号被吃掉之后，剩下的「作者 - 标题」照常切
    const auto parts = TrackName::parse(QStringLiteral("01. 周杰伦 - 晴天.mp3"));
    QCOMPARE(parts.artist, QStringLiteral("周杰伦"));
    QCOMPARE(parts.title, QStringLiteral("晴天"));

    // 左侧纯数字视为音轨号，不算作者
    const auto bare = TrackName::parse(QStringLiteral("12 - 晴天.mp3"));
    QCOMPARE(bare.artist, QString());
    QCOMPARE(bare.title, QStringLiteral("晴天"));
}

void TestTrackName::keepsHyphenInsideArtist()
{
    // 不带空格的连字符不切分：乐队名不会被吃掉
    const auto parts = TrackName::parse(QStringLiteral("AC-DC - Back In Black.mp3"));
    QCOMPARE(parts.artist, QStringLiteral("AC-DC"));
    QCOMPARE(parts.title, QStringLiteral("Back In Black"));
}

void TestTrackName::pathIsReducedToFileName()
{
    const auto parts = TrackName::parse(QStringLiteral("/music/周杰伦 - 晴天.mp3"));
    QCOMPARE(parts.artist, QStringLiteral("周杰伦"));
    QCOMPARE(parts.title, QStringLiteral("晴天"));

    // 远程路径也是 '/' 分隔
    const auto remote = TrackName::parse(QStringLiteral("Albums/x/Artist - Title.m4a"));
    QCOMPARE(remote.artist, QStringLiteral("Artist"));
    QCOMPARE(remote.title, QStringLiteral("Title"));
}

void TestTrackName::blankInputFallsBackToEmpty()
{
    const auto parts = TrackName::parse(QString());
    QCOMPARE(parts.artist, QString());
    QCOMPARE(parts.title, QString());
}

QTEST_APPLESS_MAIN(TestTrackName)
#include "tst_trackname.moc"
