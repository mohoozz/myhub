#include <QtTest>

#include "core/utils/NaturalSort.h"

#include <QStringList>

using namespace myhub;

class TestNaturalSort : public QObject
{
    Q_OBJECT
private slots:
    void ordersNumbersNaturally();
    void handlesLeadingZeros();
    void handlesLargeNumbers();
    void caseInsensitiveByDefault();
    void sortsComicPages();
};

void TestNaturalSort::ordersNumbersNaturally()
{
    QVERIFY(NaturalSort::compare("page2", "page10") < 0);
    QVERIFY(NaturalSort::compare("page10", "page2") > 0);
    QVERIFY(NaturalSort::compare("page2", "page2") == 0);
    QVERIFY(NaturalSort::compare("a", "b") < 0);
}

void TestNaturalSort::handlesLeadingZeros()
{
    // 002 与 2 数值相同
    QCOMPARE(NaturalSort::compare("p002", "p2"), 0);
    QVERIFY(NaturalSort::compare("p002", "p3") < 0);
}

void TestNaturalSort::handlesLargeNumbers()
{
    // 超出 64 位的数字串不得溢出误判
    QVERIFY(NaturalSort::compare("x99999999999999999999", "x100000000000000000000") < 0);
}

void TestNaturalSort::caseInsensitiveByDefault()
{
    QCOMPARE(NaturalSort::compare("ABC", "abc"), 0);
    QVERIFY(NaturalSort::compare("ABC", "abd") < 0);
}

void TestNaturalSort::sortsComicPages()
{
    QStringList pages = {"p10.jpg", "p1.jpg", "p2.jpg", "p20.jpg", "p3.jpg"};
    std::sort(pages.begin(), pages.end(), NaturalSort::lessThan);

    const QStringList expected = {"p1.jpg", "p2.jpg", "p3.jpg", "p10.jpg", "p20.jpg"};
    QCOMPARE(pages, expected);
}

QTEST_APPLESS_MAIN(TestNaturalSort)
#include "tst_naturalsort.moc"
