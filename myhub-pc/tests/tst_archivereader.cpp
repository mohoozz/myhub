// ArchiveReader：rar / cbr 的条目列举与按条目解包（§6 PC-207）
//
// 样本是 `RarTestBuilder.h` 手搓的 store 法归档（不依赖任何二进制夹具）。
//
// 重点验证：
//   - 条目名 / 尺寸 / 顺序如实给出；
//   - 页序与 zip 侧**同一套规则**（自然排序 + 过滤目录/隐藏/非图片）；
//   - 按条目取字节能原样往返，取不到时报错而不是给空数据；
//   - 不是 rar 的文件（扩展名撒谎）明确报错。

#include <QTemporaryDir>
#include <QtTest>

#include "RarTestBuilder.h"
#include "core/archive/ArchiveFetcher.h"
#include "core/archive/ArchiveReader.h"
#include "core/archive/PageOrder.h"
#include "core/storage/StorageAdapter.h"

using namespace myhub;

namespace {

/// 内存里的假适配器：只实现 readRange，用来盯 `ArchiveFetcher` 的分块与清理
class FakeAdapter : public StorageAdapter
{
public:
    explicit FakeAdapter(QByteArray payload, int failAtChunk = -1)
        : m_payload(std::move(payload))
        , m_failAtChunk(failAtChunk)
    {}

    QString typeName() const override { return QStringLiteral("fake"); }

    void stat(const QString &, StatCallback cb) override
    {
        StatResult result;
        result.value.size = m_payload.size();
        cb(result);
    }

    void list(const QString &, ListCallback cb) override
    {
        ListResult result;
        result.error = StorageError(StorageError::UnsupportedProtocol, QStringLiteral("不支持"));
        cb(result);
    }

    void readRange(const QString &, std::optional<qint64> start, std::optional<qint64> end,
                   DataCallback cb) override
    {
        ++m_requests;
        if (m_failAtChunk >= 0 && m_requests > m_failAtChunk) {
            DataResult result;
            result.error = StorageError(StorageError::Offline, QStringLiteral("断网了"));
            cb(result);
            return;
        }
        const int from = static_cast<int>(start.value_or(0));
        const int to = static_cast<int>(end.value_or(m_payload.size() - 1));
        DataResult result;
        result.value = m_payload.mid(from, to - from + 1);
        cb(result);
    }

    void testConnection(ErrorCallback cb) override { cb(StorageError()); }

    int requests() const { return m_requests; }

private:
    QByteArray m_payload;
    int m_failAtChunk = -1;
    int m_requests = 0;
};

} // namespace

class TestArchiveReader : public QObject
{
    Q_OBJECT

private slots:
    void listsEntries();
    void sortsPagesNaturally();
    void filtersNonPageEntries();
    void readsEntryBytes();
    void reportsMissingEntry();
    void rejectsNonArchive();
    void recognizesRarPaths();
    void fetchesWholeArchiveInChunks();
    void leavesNoHalfPackOnFailure();
};

void TestArchiveReader::listsEntries()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());

    rartest::RarBuilder rar;
    rar.add(QStringLiteral("c/1.png"), rartest::pageBytes(120));
    rar.add(QStringLiteral("c/2.png"), rartest::pageBytes(240));
    const QString path = rartest::writeArchive(dir.path(), rar.build());
    QVERIFY(!path.isEmpty());

    QVector<ArchiveEntry> entries;
    const StorageError error = ArchiveReader::listEntries(path, &entries);
    QVERIFY2(error.isNull(), qPrintable(error.userMessage()));
    QCOMPARE(entries.size(), 2);
    QCOMPARE(entries.at(0).name, QStringLiteral("c/1.png"));
    QCOMPARE(entries.at(0).size, qint64(120));
    QCOMPARE(entries.at(1).name, QStringLiteral("c/2.png"));
    QCOMPARE(entries.at(1).size, qint64(240));
}

void TestArchiveReader::sortsPagesNaturally()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());

    // 故意乱序写入：页序必须由页名自然排序决定
    rartest::RarBuilder rar;
    rar.add(QStringLiteral("c/10.png"), rartest::pageBytes(16));
    rar.add(QStringLiteral("c/2.png"), rartest::pageBytes(16));
    rar.add(QStringLiteral("c/1.png"), rartest::pageBytes(16));
    const QString path = rartest::writeArchive(dir.path(), rar.build());

    QVector<ArchiveEntry> entries;
    QVERIFY(ArchiveReader::listEntries(path, &entries).isNull());

    const QVector<int> indexes = ArchiveReader::pageIndexes(entries);
    QCOMPARE(indexes.size(), 3);
    QCOMPARE(entries.at(indexes.at(0)).name, QStringLiteral("c/1.png"));
    QCOMPARE(entries.at(indexes.at(1)).name, QStringLiteral("c/2.png"));
    QCOMPARE(entries.at(indexes.at(2)).name, QStringLiteral("c/10.png"));
}

void TestArchiveReader::filtersNonPageEntries()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());

    rartest::RarBuilder rar;
    rar.add(QStringLiteral("c/1.jpg"), rartest::pageBytes(32));
    rar.add(QStringLiteral("c/notes.txt"), QByteArrayLiteral("readme"));
    rar.add(QStringLiteral("__MACOSX/c/._1.jpg"), rartest::pageBytes(8));
    rar.add(QStringLiteral("c/.hidden.jpg"), rartest::pageBytes(8));
    rar.add(QStringLiteral("c/2.webp"), rartest::pageBytes(32));
    const QString path = rartest::writeArchive(dir.path(), rar.build());

    QVector<ArchiveEntry> entries;
    QVERIFY(ArchiveReader::listEntries(path, &entries).isNull());

    const QVector<int> indexes = ArchiveReader::pageIndexes(entries);
    QCOMPARE(indexes.size(), 2);
    QCOMPARE(entries.at(indexes.at(0)).name, QStringLiteral("c/1.jpg"));
    QCOMPARE(entries.at(indexes.at(1)).name, QStringLiteral("c/2.webp"));
}

void TestArchiveReader::readsEntryBytes()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());

    const QByteArray small = rartest::pageBytes(200);
    const QByteArray large = rartest::pageBytes(300 * 1024, 3);
    rartest::RarBuilder rar;
    rar.add(QStringLiteral("c/1.png"), small);
    rar.add(QStringLiteral("c/2.png"), large);
    const QString path = rartest::writeArchive(dir.path(), rar.build());

    QByteArray bytes;
    QVERIFY(ArchiveReader::readEntry(path, QStringLiteral("c/1.png"), &bytes).isNull());
    QCOMPARE(bytes, small);

    QVERIFY(ArchiveReader::readEntry(path, QStringLiteral("c/2.png"), &bytes).isNull());
    QCOMPARE(bytes, large);
}

void TestArchiveReader::reportsMissingEntry()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());

    rartest::RarBuilder rar;
    rar.add(QStringLiteral("c/1.png"), rartest::pageBytes(32));
    const QString path = rartest::writeArchive(dir.path(), rar.build());

    QByteArray bytes(QByteArrayLiteral("不该被覆盖"));
    const StorageError error = ArchiveReader::readEntry(path, QStringLiteral("c/9.png"), &bytes);
    QVERIFY(!error.isNull());
    QVERIFY2(bytes.isEmpty(), "失败时不能回一份脏数据");
}

void TestArchiveReader::rejectsNonArchive()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());

    const QString path =
        rartest::writeArchive(dir.path(), QByteArray(2048, 'x'), QStringLiteral("fake.cbr"));

    QVector<ArchiveEntry> entries;
    const StorageError error = ArchiveReader::listEntries(path, &entries);
    QVERIFY(!error.isNull());
    QVERIFY(entries.isEmpty());
}

void TestArchiveReader::recognizesRarPaths()
{
    QVERIFY(ArchiveReader::isRarPath(QStringLiteral("/书架/vol1.cbr")));
    QVERIFY(ArchiveReader::isRarPath(QStringLiteral("/书架/vol1.RAR")));
    QVERIFY(!ArchiveReader::isRarPath(QStringLiteral("/书架/vol1.cbz")));
    QVERIFY(!ArchiveReader::isRarPath(QStringLiteral("/书架/vol1.zip")));
}

void TestArchiveReader::fetchesWholeArchiveInChunks()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());

    // 比一块大一点，确保真的分了多次请求（弱网下要靠这个报进度）
    const QByteArray payload = rartest::pageBytes(ArchiveFetcher::kChunkBytes + 4096);
    FakeAdapter adapter(payload);
    const QString target = dir.filePath(QStringLiteral("pack.pack"));

    QVector<double> percents;
    QString localPath;
    bool done = false;
    StorageError error;
    ArchiveFetcher::fetch(
        &adapter, QStringLiteral("/漫画/vol1.cbr"), payload.size(), target,
        [&percents](qint64 got, qint64 total) {
            percents.append(static_cast<double>(got) / static_cast<double>(total));
        },
        [&localPath, &done, &error](QString path, StorageError fetchError) {
            localPath = std::move(path);
            done = true;
            error = fetchError;
        });

    QVERIFY(done); // 假适配器同步回调
    QVERIFY2(error.isNull(), qPrintable(error.userMessage()));
    QCOMPARE(localPath, target);
    QVERIFY(adapter.requests() >= 2);
    QVERIFY(!percents.isEmpty());
    QCOMPARE(percents.last(), 1.0);

    QFile file(target);
    QVERIFY(file.open(QIODevice::ReadOnly));
    QCOMPARE(file.readAll(), payload);
    QVERIFY2(!QFileInfo::exists(target + QStringLiteral(".part")), "落完了不能留半包");
}

void TestArchiveReader::leavesNoHalfPackOnFailure()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());

    const QByteArray payload = rartest::pageBytes(ArchiveFetcher::kChunkBytes + 1024);
    FakeAdapter adapter(payload, 1); // 第一块成功，第二块断网
    const QString target = dir.filePath(QStringLiteral("pack.pack"));

    bool done = false;
    StorageError error;
    QString localPath = QStringLiteral("不该有");
    ArchiveFetcher::fetch(&adapter, QStringLiteral("/漫画/vol1.cbr"), payload.size(), target, {},
                          [&localPath, &done, &error](QString path, StorageError fetchError) {
                              localPath = std::move(path);
                              done = true;
                              error = fetchError;
                          });

    QVERIFY(done);
    QVERIFY(!error.isNull());
    QVERIFY(localPath.isEmpty());
    QVERIFY2(!QFileInfo::exists(target), "失败不能留下「看起来能打开」的包");
    QVERIFY2(!QFileInfo::exists(target + QStringLiteral(".part")), "失败要清掉半包");
}

QTEST_GUILESS_MAIN(TestArchiveReader)
#include "tst_archivereader.moc"
