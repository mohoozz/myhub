#include <QtTest>

#include "core/files/DirectorySort.h"

using namespace myhub;

namespace {

FileEntry makeFile(const QString &name, qint64 size = 0, const QDateTime &time = {})
{
    FileEntry entry;
    entry.name = name;
    entry.path = QStringLiteral("/media/") + name;
    entry.size = size;
    entry.modTime = time;
    const int dot = name.lastIndexOf(QLatin1Char('.'));
    entry.ext = dot >= 0 ? name.mid(dot + 1).toLower() : QString();
    return entry;
}

FileEntry makeDir(const QString &name)
{
    FileEntry entry = makeFile(name);
    entry.isDir = true;
    return entry;
}

QStringList namesOf(const FileEntryList &list)
{
    QStringList names;
    names.reserve(list.size());
    for (const FileEntry &entry : list)
        names.append(entry.name);
    return names;
}

} // namespace

class TestDirectorySort : public QObject
{
    Q_OBJECT
private slots:
    void keepsDirectoriesFirst();
    void sortsByNameNaturally();
    void sortsBySizeAndTime();
    void honoursDescending();

    void picksSameKindSibling();
    void skipsDirectoriesAndOtherKinds();
    void returnsEmptyAtLastItem();
    void returnsEmptyWhenCurrentMissing();
    void followsDirectoryPreference();
    void singleItemHasNoSibling();

    void picksNextBookAcrossFormats();
    void nextBookSkipsNonBooks();
    void nextBookStopsAtLastBook();
    void nextBookRequiresCurrentToBeBook();
    void nextBookFollowsDirectoryPreference();
};

void TestDirectorySort::keepsDirectoriesFirst()
{
    FileEntryList list{makeFile(QStringLiteral("a.mp4")), makeDir(QStringLiteral("zdir")),
                       makeFile(QStringLiteral("b.mp4"))};

    DirectorySort::sort(list, QStringLiteral("name"), true);
    QCOMPARE(
        namesOf(list),
        QStringList({QStringLiteral("zdir"), QStringLiteral("a.mp4"), QStringLiteral("b.mp4")}));
}

void TestDirectorySort::sortsByNameNaturally()
{
    FileEntryList list{makeFile(QStringLiteral("第10集.mp4")),
                       makeFile(QStringLiteral("第2集.mp4")),
                       makeFile(QStringLiteral("第1集.mp4"))};

    DirectorySort::sort(list, QStringLiteral("name"), true);
    QCOMPARE(namesOf(list),
             QStringList({QStringLiteral("第1集.mp4"), QStringLiteral("第2集.mp4"),
                          QStringLiteral("第10集.mp4")}));
}

void TestDirectorySort::sortsBySizeAndTime()
{
    const QDateTime base = QDateTime::fromSecsSinceEpoch(1700000000);

    FileEntryList bySize{makeFile(QStringLiteral("大.mp4"), 300),
                         makeFile(QStringLiteral("小.mp4"), 100),
                         makeFile(QStringLiteral("中.mp4"), 200)};
    DirectorySort::sort(bySize, QStringLiteral("size"), true);
    QCOMPARE(namesOf(bySize),
             QStringList(
                 {QStringLiteral("小.mp4"), QStringLiteral("中.mp4"), QStringLiteral("大.mp4")}));

    FileEntryList byTime{makeFile(QStringLiteral("新.mp4"), 0, base.addSecs(200)),
                         makeFile(QStringLiteral("旧.mp4"), 0, base),
                         makeFile(QStringLiteral("中.mp4"), 0, base.addSecs(100))};
    DirectorySort::sort(byTime, QStringLiteral("time"), true);
    QCOMPARE(namesOf(byTime),
             QStringList(
                 {QStringLiteral("旧.mp4"), QStringLiteral("中.mp4"), QStringLiteral("新.mp4")}));
}

void TestDirectorySort::honoursDescending()
{
    FileEntryList list{makeFile(QStringLiteral("a.mp4")), makeFile(QStringLiteral("c.mp4")),
                       makeFile(QStringLiteral("b.mp4"))};

    DirectorySort::sort(list, QStringLiteral("name"), false);
    QCOMPARE(
        namesOf(list),
        QStringList({QStringLiteral("c.mp4"), QStringLiteral("b.mp4"), QStringLiteral("a.mp4")}));
}

void TestDirectorySort::picksSameKindSibling()
{
    FileEntryList list{makeFile(QStringLiteral("s01e01.mp4")),
                       makeFile(QStringLiteral("s01e02.mp4")),
                       makeFile(QStringLiteral("s01e03.mp4"))};

    const FileEntry next = DirectorySort::nextSibling(list, QStringLiteral("/media/s01e01.mp4"),
                                                      QStringLiteral("name"), true);
    QCOMPARE(next.name, QStringLiteral("s01e02.mp4"));
}

void TestDirectorySort::skipsDirectoriesAndOtherKinds()
{
    FileEntryList list{makeFile(QStringLiteral("ep1.mp4")), makeDir(QStringLiteral("子目录")),
                       makeFile(QStringLiteral("ep1.flac")), makeFile(QStringLiteral("ep2.mp4"))};

    const FileEntry next = DirectorySort::nextSibling(list, QStringLiteral("/media/ep1.mp4"),
                                                      QStringLiteral("name"), true);
    QCOMPARE(next.name, QStringLiteral("ep2.mp4"));

    // 音频播完接音频，不串到视频
    const FileEntry audio = DirectorySort::nextSibling(list, QStringLiteral("/media/ep1.flac"),
                                                       QStringLiteral("name"), true);
    QVERIFY(audio.name.isEmpty());
}

void TestDirectorySort::returnsEmptyAtLastItem()
{
    FileEntryList list{makeFile(QStringLiteral("a.mp4")), makeFile(QStringLiteral("b.mp4"))};

    const FileEntry next = DirectorySort::nextSibling(list, QStringLiteral("/media/b.mp4"),
                                                      QStringLiteral("name"), true);
    QVERIFY(!next.isValid());
}

void TestDirectorySort::returnsEmptyWhenCurrentMissing()
{
    FileEntryList list{makeFile(QStringLiteral("a.mp4")), makeFile(QStringLiteral("b.mp4"))};

    QVERIFY(!DirectorySort::nextSibling(list, QStringLiteral("/media/ghost.mp4"),
                                        QStringLiteral("name"), true)
                 .isValid());
    QVERIFY(!DirectorySort::nextSibling(list, QString(), QStringLiteral("name"), true).isValid());
}

void TestDirectorySort::followsDirectoryPreference()
{
    // 目录设为「按时间倒序」时，下一个是列表中更早的条目
    const QDateTime base = QDateTime::fromSecsSinceEpoch(1700000000);
    FileEntryList list{makeFile(QStringLiteral("old.mp4"), 0, base),
                       makeFile(QStringLiteral("mid.mp4"), 0, base.addSecs(100)),
                       makeFile(QStringLiteral("new.mp4"), 0, base.addSecs(200))};

    const FileEntry next = DirectorySort::nextSibling(list, QStringLiteral("/media/mid.mp4"),
                                                      QStringLiteral("time"), false);
    QCOMPARE(next.name, QStringLiteral("old.mp4"));
}

void TestDirectorySort::singleItemHasNoSibling()
{
    FileEntryList list{makeFile(QStringLiteral("only.mp4"))};
    QVERIFY(!DirectorySort::nextSibling(list, QStringLiteral("/media/only.mp4"),
                                        QStringLiteral("name"), true)
                 .isValid());
}

void TestDirectorySort::picksNextBookAcrossFormats()
{
    // 同一本书的 txt / epub 是同类：换了格式不该把「连续读」打断
    FileEntryList list{makeFile(QStringLiteral("第1卷.txt")),
                       makeFile(QStringLiteral("第2卷.epub"))};

    const FileEntry next = DirectorySort::nextBook(list, QStringLiteral("/media/第1卷.txt"),
                                                   QStringLiteral("name"), true);
    QCOMPARE(next.name, QStringLiteral("第2卷.epub"));
}

void TestDirectorySort::nextBookSkipsNonBooks()
{
    FileEntryList list{makeFile(QStringLiteral("上卷.txt")), makeDir(QStringLiteral("插图")),
                       makeFile(QStringLiteral("封面.jpg")),
                       makeFile(QStringLiteral("主题曲.flac")),
                       makeFile(QStringLiteral("外传.epub"))};

    const FileEntry next = DirectorySort::nextBook(list, QStringLiteral("/media/上卷.txt"),
                                                   QStringLiteral("name"), true);
    QCOMPARE(next.name, QStringLiteral("外传.epub"));
}

void TestDirectorySort::nextBookStopsAtLastBook()
{
    // 末本之后即使还有文件也不回绕，交回 UI 决定怎么收场
    FileEntryList list{makeFile(QStringLiteral("上卷.txt")), makeFile(QStringLiteral("下卷.txt")),
                       makeFile(QStringLiteral("封面.jpg"))};

    QVERIFY(!DirectorySort::nextBook(list, QStringLiteral("/media/下卷.txt"),
                                     QStringLiteral("name"), true)
                 .isValid());
}

void TestDirectorySort::nextBookRequiresCurrentToBeBook()
{
    // 在书目录里点开视频/图片：它不是「一本书」，读完了也不该推下一本
    FileEntryList list{makeFile(QStringLiteral("a.mp4")), makeFile(QStringLiteral("b.txt"))};

    QVERIFY(
        !DirectorySort::nextBook(list, QStringLiteral("/media/a.mp4"), QStringLiteral("name"), true)
             .isValid());
    QVERIFY(!DirectorySort::nextBook(list, QStringLiteral("/media/ghost.txt"),
                                     QStringLiteral("name"), true)
                 .isValid());
}

void TestDirectorySort::nextBookFollowsDirectoryPreference()
{
    // 目录设为「按时间倒序」时，下一本是列表中更早的那一本
    const QDateTime base = QDateTime::fromSecsSinceEpoch(1700000000);
    FileEntryList list{makeFile(QStringLiteral("旧.txt"), 0, base),
                       makeFile(QStringLiteral("中.epub"), 0, base.addSecs(100)),
                       makeFile(QStringLiteral("新.txt"), 0, base.addSecs(200))};

    const FileEntry next = DirectorySort::nextBook(list, QStringLiteral("/media/中.epub"),
                                                   QStringLiteral("time"), false);
    QCOMPARE(next.name, QStringLiteral("旧.txt"));
}

QTEST_APPLESS_MAIN(TestDirectorySort)
#include "tst_directorysort.moc"
