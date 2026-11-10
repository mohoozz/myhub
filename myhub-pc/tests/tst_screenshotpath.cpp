#include "core/utils/ScreenshotPath.h"

#include <QFile>
#include <QTemporaryDir>
#include <QTest>

using myhub::ScreenshotPath;

class TestScreenshotPath : public QObject
{
    Q_OBJECT

private slots:
    void sanitizeReplacesForbiddenChars();
    void sanitizeCollapsesRuns();
    void sanitizeTrimsTrailingDotsAndSpaces();
    void sanitizeFallsBackWhenEmpty();
    void sanitizeKeepsCjkAndInnerSpaces();
    void buildUsesTimestampedPngName();
    void buildAddsSuffixOnCollision();
    void buildDoesNotCreateDirectory();
    void defaultDirectoryIsUnderPictures();
};

void TestScreenshotPath::sanitizeReplacesForbiddenChars()
{
    // Windows 九个保留字符全都要换掉，否则 mpv 写文件直接失败
    QCOMPARE(ScreenshotPath::sanitizeTitle(QStringLiteral("a/b\\c:d*e?f\"g<h>i|j")),
             QStringLiteral("a_b_c_d_e_f_g_h_i_j"));
    // 首尾空白不参与命名
    QCOMPARE(ScreenshotPath::sanitizeTitle(QStringLiteral("  x  ")), QStringLiteral("x"));
}

void TestScreenshotPath::sanitizeCollapsesRuns()
{
    // 连续非法字符压成一个下划线：`a//b` 不该变成 `a__b`
    QCOMPARE(ScreenshotPath::sanitizeTitle(QStringLiteral("a//b")), QStringLiteral("a_b"));
    // 连续空白折叠成一个空格（标题里的空格要保留，便于阅读）
    QCOMPARE(ScreenshotPath::sanitizeTitle(QStringLiteral("A    B")), QStringLiteral("A B"));
}

void TestScreenshotPath::sanitizeTrimsTrailingDotsAndSpaces()
{
    // Windows 会静默丢弃尾随的点和空格，留着会让「预期文件名」与「实际文件名」对不上
    QCOMPARE(ScreenshotPath::sanitizeTitle(QStringLiteral("EP01.")), QStringLiteral("EP01"));
    QCOMPARE(ScreenshotPath::sanitizeTitle(QStringLiteral("EP01... ")), QStringLiteral("EP01"));
}

void TestScreenshotPath::sanitizeFallsBackWhenEmpty()
{
    // 空标题不能拼出 `.png` 这种隐藏文件
    QCOMPARE(ScreenshotPath::sanitizeTitle(QString()), QStringLiteral("screenshot"));
    QCOMPARE(ScreenshotPath::sanitizeTitle(QStringLiteral("   ")), QStringLiteral("screenshot"));
    QCOMPARE(ScreenshotPath::sanitizeTitle(QStringLiteral("...")), QStringLiteral("screenshot"));
}

void TestScreenshotPath::sanitizeKeepsCjkAndInnerSpaces()
{
    QCOMPARE(ScreenshotPath::sanitizeTitle(QStringLiteral("流浪地球 2")),
             QStringLiteral("流浪地球 2"));
}

void TestScreenshotPath::buildUsesTimestampedPngName()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QDateTime now(QDate(2026, 11, 10), QTime(18, 52, 30));

    const QString path = ScreenshotPath::build(dir.path(), QStringLiteral("流浪地球 2"), now);
    QCOMPARE(path, dir.filePath(QStringLiteral("流浪地球 2_2026-11-10_18-52-30.png")));
}

void TestScreenshotPath::buildAddsSuffixOnCollision()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QDateTime now(QDate(2026, 11, 10), QTime(18, 52, 30));
    const QString first = ScreenshotPath::build(dir.path(), QStringLiteral("EP01"), now);

    // 同一秒连按两次：第二张必须换名，不能覆盖第一张
    QFile created(first);
    QVERIFY(created.open(QIODevice::WriteOnly));
    created.close();

    const QString second = ScreenshotPath::build(dir.path(), QStringLiteral("EP01"), now);
    QCOMPARE(second, dir.filePath(QStringLiteral("EP01_2026-11-10_18-52-30-2.png")));

    QFile createdSecond(second);
    QVERIFY(createdSecond.open(QIODevice::WriteOnly));
    createdSecond.close();
    QCOMPARE(ScreenshotPath::build(dir.path(), QStringLiteral("EP01"), now),
             dir.filePath(QStringLiteral("EP01_2026-11-10_18-52-30-3.png")));
}

void TestScreenshotPath::buildDoesNotCreateDirectory()
{
    // 目录创建是调用方的责任（要能上报「无法创建截图目录」），这里只算路径
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString target = dir.filePath(QStringLiteral("not-yet"));
    const QString path =
        ScreenshotPath::build(target, QStringLiteral("x"), QDateTime::currentDateTime());
    QVERIFY(path.startsWith(target));
    QVERIFY(!QFileInfo::exists(target));
}

void TestScreenshotPath::defaultDirectoryIsUnderPictures()
{
    const QString dir = ScreenshotPath::defaultDirectory();
    QVERIFY(!dir.isEmpty());
    QVERIFY(dir.endsWith(QStringLiteral("MyHub")) || dir.endsWith(QStringLiteral("screenshots")));
}

QTEST_GUILESS_MAIN(TestScreenshotPath)
#include "tst_screenshotpath.moc"
