// `ComicDetector`：漫画判定结论的缓存（§6 ③ epub 图集目录层预判）。
//
// 这里只测「结论怎么存、怎么取、什么时候作废」，不测 epub 本身怎么判 ——
// 那是 `EpubBook::imageOnly()` 的事，已由 `tst_epubbook` 覆盖。

#include <QtTest>

#include <QCoreApplication>
#include <QDateTime>
#include <QStandardPaths>

#include "core/comic/ComicDetector.h"
#include "core/database/AppDatabase.h"
#include "core/preferences/AppSettings.h"
#include "core/storage/StoragePath.h"
#include "core/utils/AppPaths.h"

using namespace myhub;

namespace {

const QString kConnection = QStringLiteral("conn-a");

/// 目录项：size 与秒级 mtime 就是它的指纹
FileEntry makeEntry(const QString &path, qint64 size, qint64 modSecs)
{
    FileEntry entry;
    entry.name = StoragePath::fileName(path);
    entry.path = path;
    entry.size = size;
    entry.modTime = QDateTime::fromSecsSinceEpoch(modSecs);
    entry.ext = StoragePath::extension(path);
    return entry;
}

} // namespace

class TestComicDetector : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void init();
    void cleanupTestCase();

    void archiveExtensionsAreAlwaysComic();
    void directoryNamedLikeArchiveIsNotComic();
    void epubIsUnknownUntilAVerdictArrives();
    void textBookFilesAreNeverCandidates();
    void rememberSurvivesRestartAndPrime();
    void staleFingerprintIsIgnored();
    void negativeVerdictIsAlsoRemembered();
    void forgetDropsRowAndMemory();
};

void TestComicDetector::initTestCase()
{
    QCoreApplication::setApplicationName(
        QStringLiteral("MyHubTest-%1").arg(QCoreApplication::applicationPid()));
    QStandardPaths::setTestModeEnabled(true);

    AppPaths::initializeAll();
    AppSettings::instance().initialize();

    auto &db = AppDatabase::instance();
    QVERIFY2(db.open(), qPrintable(db.lastError()));
}

void TestComicDetector::init()
{
    ComicDetector::resetMemory();
    auto &db = AppDatabase::instance();
    QVERIFY(db.execute(QStringLiteral("DELETE FROM comicVerdict")));
}

void TestComicDetector::cleanupTestCase()
{
    AppDatabase::instance().close();
}

void TestComicDetector::archiveExtensionsAreAlwaysComic()
{
    // cbz/cbr 只是 zip/rar 的别名：扩展名就够，不必查缓存
    for (const QString &name : {QStringLiteral("/m/a.cbz"), QStringLiteral("/m/a.zip"),
                                QStringLiteral("/m/a.cbr"), QStringLiteral("/m/a.rar")}) {
        const FileEntry entry = makeEntry(name, 10, 100);
        bool comic = false;
        QVERIFY2(ComicDetector::known(kConnection, entry, &comic), qPrintable(name));
        QVERIFY2(comic, qPrintable(name));
    }

    // 大写扩展名同样算（列表里的 ext 已小写化，这里防的是调用方直接传路径）
    QVERIFY(ComicDetector::isComicArchivePath(QStringLiteral("/m/A.CBZ")));
    QVERIFY(!ComicDetector::isComicArchivePath(QStringLiteral("/m/a.txt")));
}

void TestComicDetector::directoryNamedLikeArchiveIsNotComic()
{
    // 名叫「第5卷.cbz」的文件夹不是漫画包
    FileEntry dir;
    dir.name = QStringLiteral("第5卷.cbz");
    dir.path = QStringLiteral("/m/第5卷.cbz");
    dir.isDir = true;
    dir.ext = QStringLiteral("cbz");

    bool comic = true;
    QVERIFY(!ComicDetector::known(kConnection, dir, &comic));
}

void TestComicDetector::epubIsUnknownUntilAVerdictArrives()
{
    const FileEntry entry = makeEntry(QStringLiteral("/m/第1卷.epub"), 100, 1000);

    // 没有任何人读过这本的 OPF → 老实回答「不知道」，绝不猜
    QVERIFY(ComicDetector::couldBeComic(entry.path));
    bool comic = true;
    QVERIFY(!ComicDetector::known(kConnection, entry, &comic));

    // 记下结论后立刻可用（内存生效，不等落库轮询）
    QVERIFY(ComicDetector::remember(kConnection, entry.path, true, entry.size,
                                    entry.modTime.toSecsSinceEpoch()));
    comic = false;
    QVERIFY(ComicDetector::known(kConnection, entry, &comic));
    QVERIFY(comic);
}

void TestComicDetector::textBookFilesAreNeverCandidates()
{
    // txt 与图集无关：连缓存都不该给它建行（`prime` 不许被无关条目拖慢）
    QVERIFY(!ComicDetector::couldBeComic(QStringLiteral("/m/第1卷.txt")));

    const FileEntryList entries{makeEntry(QStringLiteral("/m/第1卷.txt"), 100, 1000),
                                makeEntry(QStringLiteral("/m/第2卷.cbz"), 100, 1000)};
    ComicDetector::prime(kConnection, entries);
    QCOMPARE(ComicDetector::count(), 0);

    bool comic = true;
    QVERIFY(!ComicDetector::known(kConnection, entries.first(), &comic));
}

void TestComicDetector::rememberSurvivesRestartAndPrime()
{
    const FileEntry entry = makeEntry(QStringLiteral("/m/第2卷.epub"), 2048, 1700000000);
    QVERIFY(ComicDetector::remember(kConnection, entry.path, true, entry.size,
                                    entry.modTime.toSecsSinceEpoch()));

    // 模拟重启：内存清空，只剩库
    ComicDetector::resetMemory();
    bool comic = false;
    QVERIFY(!ComicDetector::known(kConnection, entry, &comic));

    ComicDetector::prime(kConnection, FileEntryList{entry});
    QVERIFY(ComicDetector::known(kConnection, entry, &comic));
    QVERIFY(comic);
}

void TestComicDetector::staleFingerprintIsIgnored()
{
    const FileEntry original = makeEntry(QStringLiteral("/m/第3卷.epub"), 2048, 1700000000);
    QVERIFY(ComicDetector::remember(kConnection, original.path, true, original.size,
                                    original.modTime.toSecsSinceEpoch()));

    // 同名文件被换过：大小变了，旧结论不再成立
    const FileEntry replaced = makeEntry(QStringLiteral("/m/第3卷.epub"), 4096, 1700000000);
    ComicDetector::resetMemory();
    ComicDetector::prime(kConnection, FileEntryList{replaced});

    bool comic = true;
    QVERIFY(!ComicDetector::known(kConnection, replaced, &comic));

    // 只改 mtime 也一样
    const FileEntry touched = makeEntry(QStringLiteral("/m/第3卷.epub"), 2048, 1700009999);
    QVERIFY(!ComicDetector::known(kConnection, touched, &comic));
}

void TestComicDetector::negativeVerdictIsAlsoRemembered()
{
    // 「查过了，是文字书」同样值得记：省掉重复的 OPF 探测
    const FileEntry entry = makeEntry(QStringLiteral("/m/随笔.epub"), 512, 1600000000);
    QVERIFY(ComicDetector::remember(kConnection, entry.path, false, entry.size,
                                    entry.modTime.toSecsSinceEpoch()));

    ComicDetector::resetMemory();
    ComicDetector::prime(kConnection, FileEntryList{entry});

    bool comic = true;
    QVERIFY(ComicDetector::known(kConnection, entry, &comic));
    QVERIFY(!comic);
}

void TestComicDetector::forgetDropsRowAndMemory()
{
    const FileEntry entry = makeEntry(QStringLiteral("/m/第4卷.epub"), 1024, 1650000000);
    QVERIFY(ComicDetector::remember(kConnection, entry.path, true, entry.size,
                                    entry.modTime.toSecsSinceEpoch()));
    QCOMPARE(ComicDetector::count(), 1);

    ComicDetector::forget(kConnection, entry.path);
    QCOMPARE(ComicDetector::count(), 0);

    ComicDetector::resetMemory();
    ComicDetector::prime(kConnection, FileEntryList{entry});
    bool comic = true;
    QVERIFY(!ComicDetector::known(kConnection, entry, &comic));
}

QTEST_MAIN(TestComicDetector)
#include "tst_comicdetector.moc"
