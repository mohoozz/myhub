#include <QtTest>

#include "core/storage/StoragePath.h"

using namespace myhub;

class TestStoragePath : public QObject
{
    Q_OBJECT
private slots:
    void normalize_data();
    void normalize();
    void join();
    void fileNameAndExt();
    void parentAndRoot();
    void descendant();
    void percentEncode();
};

void TestStoragePath::normalize_data()
{
    QTest::addColumn<QString>("input");
    QTest::addColumn<QString>("expected");

    QTest::newRow("empty") << "" << "/";
    QTest::newRow("root") << "/" << "/";
    QTest::newRow("double slash") << "//a//b" << "/a/b";
    QTest::newRow("backslash") << "\\a\\b" << "/a/b";
    QTest::newRow("trailing") << "/a/b/" << "/a/b";
    QTest::newRow("dot") << "/a/./b" << "/a/b";
    QTest::newRow("dotdot") << "/a/b/../c" << "/a/c";
    QTest::newRow("dotdot root") << "/../a" << "/a";
    QTest::newRow("no leading") << "a/b" << "/a/b";
    QTest::newRow("spaces") << "/a b/c d" << "/a b/c d";
    QTest::newRow("unicode") << "/测试/文件" << "/测试/文件";
}

void TestStoragePath::normalize()
{
    QFETCH(QString, input);
    QFETCH(QString, expected);
    QCOMPARE(StoragePath::normalize(input), expected);
}

void TestStoragePath::join()
{
    QCOMPARE(StoragePath::join("/a", "b"), QStringLiteral("/a/b"));
    QCOMPARE(StoragePath::join("/a/", "b"), QStringLiteral("/a/b"));
    QCOMPARE(StoragePath::join("/", "b"), QStringLiteral("/b"));
    // 绝对子路径应覆盖 base
    QCOMPARE(StoragePath::join("/a", "/c"), QStringLiteral("/c"));
}

void TestStoragePath::fileNameAndExt()
{
    QCOMPARE(StoragePath::fileName("/a/b/movie.mkv"), QStringLiteral("movie.mkv"));
    QCOMPARE(StoragePath::baseName("/a/b/movie.mkv"), QStringLiteral("movie"));
    QCOMPARE(StoragePath::extension("/a/b/movie.MKV"), QStringLiteral("mkv"));
    QCOMPARE(StoragePath::extension("/a/b/noext"), QString());
    // 隐藏文件的前导点不是扩展名分隔符
    QCOMPARE(StoragePath::baseName("/a/.hidden"), QStringLiteral(".hidden"));
    QCOMPARE(StoragePath::extension("/a/.hidden"), QString());
    // 末尾点
    QCOMPARE(StoragePath::extension("/a/name."), QString());
    QCOMPARE(StoragePath::fileName("/"), QString());
}

void TestStoragePath::parentAndRoot()
{
    QCOMPARE(StoragePath::parent("/a/b/c"), QStringLiteral("/a/b"));
    QCOMPARE(StoragePath::parent("/a"), QStringLiteral("/"));
    QCOMPARE(StoragePath::parent("/"), QStringLiteral("/"));
    QVERIFY(StoragePath::isRoot("/"));
    QVERIFY(StoragePath::isRoot(""));
    QVERIFY(!StoragePath::isRoot("/a"));
}

void TestStoragePath::descendant()
{
    QVERIFY(StoragePath::isDescendantOf("/a/b/c", "/a"));
    QVERIFY(StoragePath::isDescendantOf("/a", "/a"));
    QVERIFY(StoragePath::isDescendantOf("/a", "/"));
    QVERIFY(!StoragePath::isDescendantOf("/ab", "/a")); // 前缀不等于子路径
    QVERIFY(!StoragePath::isDescendantOf("/b", "/a"));
}

void TestStoragePath::percentEncode()
{
    QCOMPARE(StoragePath::percentEncoded("/a b"), QStringLiteral("/a%20b"));
    // 分隔符必须保留
    QVERIFY(StoragePath::percentEncoded("/a/b").contains(QLatin1Char('/')));
    QCOMPARE(StoragePath::percentEncoded("/"), QStringLiteral("/"));
}

QTEST_APPLESS_MAIN(TestStoragePath)
#include "tst_storagepath.moc"
