// 漫画阅读方向自动判定（PC-208）：纯函数，不碰归档/数据库

#include "core/comic/ComicDirection.h"

#include <QtTest>

using namespace myhub;

class TestComicDirection : public QObject
{
    Q_OBJECT

private slots:
    void answersUnknownWhenNothingIsRecognizable();
    void readsExplicitDirectionWords();
    void treatsKanaAsJapanese();
    void readsJapaneseVolumeAndDoujinMarkers();
    void readsWebtoonMarkersAsLeftToRight();
    void looksAtPageNamesWhenTitleSaysNothing();
};

void TestComicDirection::answersUnknownWhenNothingIsRecognizable()
{
    // 判不出来必须返回 Unknown：宁可让用户的选择生效，也不能凭空把整本读反
    QCOMPARE(detectComicDirection(QStringLiteral("第一卷")), ComicDirection::Unknown);
    QCOMPARE(detectComicDirection(QStringLiteral("One Piece v01")), ComicDirection::Unknown);
    QCOMPARE(detectComicDirection(QString()), ComicDirection::Unknown);
    QCOMPARE(detectComicDirection(QStringLiteral("漫画/第一卷.cbz")), ComicDirection::Unknown);
}

void TestComicDirection::readsExplicitDirectionWords()
{
    // 发布者写明了方向，比任何推断都可信
    QCOMPARE(detectComicDirection(QStringLiteral("某作品 右→左")), ComicDirection::RightToLeft);
    QCOMPARE(detectComicDirection(QStringLiteral("某作品 从右向左")), ComicDirection::RightToLeft);
    QCOMPARE(detectComicDirection(QStringLiteral("Foo (RTL)")), ComicDirection::RightToLeft);

    QCOMPARE(detectComicDirection(QStringLiteral("某作品 左→右")), ComicDirection::LeftToRight);
    QCOMPARE(detectComicDirection(QStringLiteral("Foo LTR")), ComicDirection::LeftToRight);
    QCOMPARE(detectComicDirection(QStringLiteral("Foo right-to-left")),
             ComicDirection::RightToLeft);
}

void TestComicDirection::treatsKanaAsJapanese()
{
    QCOMPARE(detectComicDirection(QStringLiteral("進撃の巨人")), ComicDirection::RightToLeft);
    QCOMPARE(detectComicDirection(QStringLiteral("ワンピース")), ComicDirection::RightToLeft);
    // 半角片假名也算
    QCOMPARE(detectComicDirection(QStringLiteral("ｱｲﾄﾞﾙ")), ComicDirection::RightToLeft);
}

void TestComicDirection::readsJapaneseVolumeAndDoujinMarkers()
{
    QCOMPARE(detectComicDirection(QStringLiteral("作品 第3巻")), ComicDirection::RightToLeft);
    QCOMPARE(detectComicDirection(QStringLiteral("作品 第3話")), ComicDirection::RightToLeft);
    QCOMPARE(detectComicDirection(QStringLiteral("[サークル名] 作品 (C99)")),
             ComicDirection::RightToLeft);
    QCOMPARE(detectComicDirection(QStringLiteral("作品 [C102] 成年向")),
             ComicDirection::RightToLeft);
}

void TestComicDirection::readsWebtoonMarkersAsLeftToRight()
{
    // 现代条漫 / 国漫 / 韩漫一律左到右；简体「第 N 话」是中文写法
    QCOMPARE(detectComicDirection(QStringLiteral("某条漫 第12话")), ComicDirection::LeftToRight);
    QCOMPARE(detectComicDirection(QStringLiteral("webtoon 合集")), ComicDirection::LeftToRight);
    QCOMPARE(detectComicDirection(QStringLiteral("韩漫 全一话")), ComicDirection::LeftToRight);
}

void TestComicDirection::looksAtPageNamesWhenTitleSaysNothing()
{
    QCOMPARE(detectComicDirection(QStringLiteral("第一卷"),
                                  {QStringLiteral("001.jpg"), QStringLiteral("あとがき.jpg")}),
             ComicDirection::RightToLeft);
    QCOMPARE(
        detectComicDirection(QString(), {QStringLiteral("p/1.png"), QStringLiteral("p/2.png")}),
        ComicDirection::Unknown);
}

QTEST_APPLESS_MAIN(TestComicDirection)

#include "tst_comicdirection.moc"
