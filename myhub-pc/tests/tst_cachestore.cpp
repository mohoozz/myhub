// 缓存容量治理单测（需求文档 §5.5：分区配额 + 跨分区全局兜底 + 文件粒度 LRU）
//
// 覆盖五层：
//   1. 配额换算：`max(下限, T / 分母)` 两个分支都要生效，分母为 0 不许除零；
//   2. 分区配额：单分区超限时按 mtime 从旧到新删到 90%，最新的留下；
//   3. 全局兜底：各分区都在自己配额内、总和却超上限时，跨分区删最旧的；
//   4. 例外：`selfManaged` 分区（音视频分片）只统计不删；未登记目录仍进全局兜底；
//   5. 保护与优先级：受保护路径不删；`.part` 半截文件最先走；`touch` 能把文件救回来；
//   6. 设置页动作：单项 / 全部清空（保护集生效、空子目录收掉）、改上限即时生效。
//
// 全部在临时目录跑真实文件，不碰 `AppPaths`（配额以显式分区表注入，避免造 256MB 数据）。

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QTemporaryDir>
#include <QtTest>

#include "core/cache/CachePartition.h"
#include "core/cache/CacheStore.h"

using namespace myhub;

namespace {

constexpr qint64 kKB = 1024;
constexpr qint64 kMB = 1024LL * 1024;

CachePartition part(const QString &dir, int baseMB, int divisor, bool selfManaged = false)
{
    return CachePartition{dir, dir, baseMB, divisor, selfManaged};
}

} // namespace

class TestCacheStore : public QObject
{
    Q_OBJECT

private slots:
    void init();
    void cleanup();

    void computesQuotaFromTotalLimit();
    void scansPartitionUsage();
    void evictsOldestWithinPartition();
    void fallsBackToGlobalLimit();
    void leavesSelfManagedPartitionAlone();
    void includesUnregisteredDirectories();
    void respectsProtectedPrefixes();
    void removesPartialFilesFirst();
    void touchMovesFileToNewest();
    void purgesOnePartitionOnly();
    void purgeAllHonoursProtectionAndPrunesDirs();
    void appliesUpdatedTotalLimit();
    void toleratesMissingRoot();

private:
    /// 造一个指定大小、指定「多久以前改过」的文件；失败返回空
    QString makeFile(const QString &partition, const QString &name, qint64 bytes, int ageSeconds);

    std::unique_ptr<QTemporaryDir> m_temp;
};

void TestCacheStore::init()
{
    m_temp = std::make_unique<QTemporaryDir>();
    QVERIFY(m_temp->isValid());
}

void TestCacheStore::cleanup()
{
    m_temp.reset();
}

QString TestCacheStore::makeFile(const QString &partition, const QString &name, qint64 bytes,
                                 int ageSeconds)
{
    const QString path = m_temp->filePath(partition) + QLatin1Char('/') + name;
    if (!QDir().mkpath(QFileInfo(path).absolutePath())) {
        return QString();
    }

    QFile file(path);
    if (!file.open(QIODevice::WriteOnly) || file.write(QByteArray(int(bytes), '\0')) != bytes) {
        return QString();
    }
    file.close();

    // mtime 就是 LRU 时钟：造数据时必须能把「新旧」摆开
    QFile stamp(path);
    if (!stamp.open(QIODevice::ReadWrite)) {
        return QString();
    }
    const bool ok = stamp.setFileTime(QDateTime::currentDateTime().addSecs(-ageSeconds),
                                      QFileDevice::FileModificationTime);
    stamp.close();
    return ok ? path : QString();
}

void TestCacheStore::computesQuotaFromTotalLimit()
{
    const CachePartition comic{QStringLiteral("comicPages"), QString(), 256, 4, false};
    // T/4 高于下限：跟总上限一起长
    QCOMPARE(CachePartitions::quotaBytes(comic, 2048 * kMB), 512 * kMB);
    // 恰好相等
    QCOMPARE(CachePartitions::quotaBytes(comic, 1024 * kMB), 256 * kMB);
    // 总上限很小时下限兜底，不能让分区缩到不可用
    QCOMPARE(CachePartitions::quotaBytes(comic, 64 * kMB), 256 * kMB);

    const CachePartition listings{QStringLiteral("directoryListings"), QString(), 16, 64, false};
    QCOMPARE(CachePartitions::quotaBytes(listings, 2048 * kMB), 32 * kMB);
    QCOMPARE(CachePartitions::quotaBytes(listings, 256 * kMB), 16 * kMB);

    // 分母为 0 不除零，按「整块给这一家」处理
    const CachePartition unbounded{QStringLiteral("x"), QString(), 8, 0, false};
    QCOMPARE(CachePartitions::quotaBytes(unbounded, 100 * kMB), 100 * kMB);
}

void TestCacheStore::scansPartitionUsage()
{
    QVERIFY(!makeFile(QStringLiteral("a"), QStringLiteral("x.bin"), 100 * kKB, 10).isEmpty());
    // 子目录也要算进去：漫画整包就在 `comicPages/packs` 下
    QVERIFY(!makeFile(QStringLiteral("a"), QStringLiteral("sub/y.bin"), 50 * kKB, 20).isEmpty());
    QVERIFY(!makeFile(QStringLiteral("b"), QStringLiteral("z.bin"), 25 * kKB, 30).isEmpty());

    CacheStore store(m_temp->path(), 100 * kMB,
                     {part(QStringLiteral("a"), 8, 4), part(QStringLiteral("b"), 16, 64)});
    const CacheStore::Scan scan = store.scan();

    QCOMPARE(scan.totalFiles, 3);
    QCOMPARE(scan.totalBytes, 175 * kKB);

    QCOMPARE(scan.partitions.size(), 2);
    const CacheStore::PartitionUsage &a = scan.partitions.at(0);
    QCOMPARE(a.dir, QStringLiteral("a"));
    QCOMPARE(a.files, 2);
    QCOMPARE(a.bytes, 150 * kKB);
    QCOMPARE(a.limitBytes, 25 * kMB); // max(8MB, 100MB/4)
    QVERIFY(!a.selfManaged);

    const CacheStore::PartitionUsage &b = scan.partitions.at(1);
    QCOMPARE(b.bytes, 25 * kKB);
    QCOMPARE(b.limitBytes, 16 * kMB); // max(16MB, 100MB/64)
}

void TestCacheStore::evictsOldestWithinPartition()
{
    // 配额 = max(1MB, T=1MB) = 1MB；6 × 300KB = 1.75MB，超 1.7 倍
    CacheStore store(m_temp->path(), kMB, {part(QStringLiteral("small"), 1, 1)});

    QStringList paths;
    for (int i = 0; i < 6; ++i) {
        const QString path = makeFile(QStringLiteral("small"), QStringLiteral("f%1.bin").arg(i),
                                      300 * kKB, 600 - i * 60);
        QVERIFY2(!path.isEmpty(), qPrintable(QStringLiteral("造文件失败：%1").arg(i)));
        paths.append(path);
    }

    const CacheStore::Result result = store.enforce();

    QVERIFY(result.removedFiles >= 3);
    QVERIFY(result.removedBytes >= 900 * kKB);
    // 从最旧的开始删，最新的必须留下
    QVERIFY2(!QFile::exists(paths.at(0)), "最旧的没被淘汰");
    QVERIFY2(QFile::exists(paths.at(5)), "最新的被误删");
    // 压到配额以内，且不该贴着上限（留了 10% 余量）
    QVERIFY(store.scan().totalBytes <= 920 * kKB);
}

void TestCacheStore::fallsBackToGlobalLimit()
{
    // 两个分区各自的配额都远大于总量：唯一能触发淘汰的是全局兜底
    CacheStore store(m_temp->path(), kMB,
                     {part(QStringLiteral("a"), 32, 1), part(QStringLiteral("b"), 32, 1)});

    const QString aOld = makeFile(QStringLiteral("a"), QStringLiteral("old.bin"), 400 * kKB, 600);
    const QString aNew = makeFile(QStringLiteral("a"), QStringLiteral("new.bin"), 400 * kKB, 60);
    const QString bOld =
        makeFile(QStringLiteral("b"), QStringLiteral("oldest.bin"), 400 * kKB, 900);
    const QString bNew = makeFile(QStringLiteral("b"), QStringLiteral("newest.bin"), 400 * kKB, 30);
    QVERIFY(!aOld.isEmpty() && !aNew.isEmpty() && !bOld.isEmpty() && !bNew.isEmpty());

    const CacheStore::Result result = store.enforce();

    QCOMPARE(result.removedFiles, 2);
    // 跨分区统一按 mtime 排：900s 和 600s 的先走，30s / 60s 的留下
    QVERIFY2(!QFile::exists(bOld), "全局最旧的没被淘汰");
    QVERIFY2(!QFile::exists(aOld), "第二个最旧的没被淘汰");
    QVERIFY(QFile::exists(aNew));
    QVERIFY(QFile::exists(bNew));
    QVERIFY(store.scan().totalBytes <= 920 * kKB);
}

void TestCacheStore::leavesSelfManagedPartitionAlone()
{
    // 音视频分片按播放点淘汰（SegmentCache 自己管），本类只统计
    CacheStore store(
        m_temp->path(), kMB,
        {part(QStringLiteral("mediaSegments"), 32, 1, true), part(QStringLiteral("other"), 32, 1)});

    const QString playing =
        makeFile(QStringLiteral("mediaSegments"), QStringLiteral("live.bin"), 600 * kKB, 1200);
    const QString idle = makeFile(QStringLiteral("other"), QStringLiteral("f.bin"), 600 * kKB, 60);
    QVERIFY(!playing.isEmpty() && !idle.isEmpty());

    const CacheStore::Result result = store.enforce();

    QCOMPARE(result.removedFiles, 1);
    QVERIFY2(QFile::exists(playing), "自管分区的文件被代删了");
    QVERIFY(!QFile::exists(idle));

    // 只剩自管分区超限时：删无可删，必须正常返回而不是死循环
    const CacheStore::Result again = store.enforce();
    QCOMPARE(again.removedFiles, 0);
    QVERIFY(QFile::exists(playing));
}

void TestCacheStore::includesUnregisteredDirectories()
{
    // 历史版本留下的目录（`stream` / `comic` / `comic-packs`）：没有分区配额，
    // 但必须参与全局兜底，否则旧缓存永远清不掉
    CacheStore store(m_temp->path(), kMB, {part(QStringLiteral("a"), 32, 1)});

    const QString legacy =
        makeFile(QStringLiteral("legacy"), QStringLiteral("old.bin"), 700 * kKB, 900);
    const QString fresh = makeFile(QStringLiteral("a"), QStringLiteral("new.bin"), 700 * kKB, 30);
    QVERIFY(!legacy.isEmpty() && !fresh.isEmpty());

    const CacheStore::Result result = store.enforce();

    QCOMPARE(result.removedFiles, 1);
    QVERIFY2(!QFile::exists(legacy), "未登记目录被漏掉了");
    QVERIFY(QFile::exists(fresh));
}

void TestCacheStore::respectsProtectedPrefixes()
{
    CacheStore store(m_temp->path(), kMB, {part(QStringLiteral("a"), 32, 1)});

    // 最旧的恰好是正在用的那个：宁可多占也不能删
    const QString keep = makeFile(QStringLiteral("a"), QStringLiteral("keep.bin"), 700 * kKB, 900);
    const QString drop = makeFile(QStringLiteral("a"), QStringLiteral("drop.bin"), 700 * kKB, 60);
    QVERIFY(!keep.isEmpty() && !drop.isEmpty());

    const CacheStore::Result result = store.enforce({keep});

    QCOMPARE(result.removedFiles, 1);
    QVERIFY2(QFile::exists(keep), "受保护文件被删了");
    QVERIFY(!QFile::exists(drop));
}

void TestCacheStore::removesPartialFilesFirst()
{
    CacheStore store(m_temp->path(), kMB, {part(QStringLiteral("a"), 32, 1)});

    const QString old = makeFile(QStringLiteral("a"), QStringLiteral("old.bin"), 600 * kKB, 900);
    // 半截文件通常最新（刚下了一半就断了），但它是残骸，优先级压过 mtime
    const QString partial =
        makeFile(QStringLiteral("a"), QStringLiteral("fresh.bin.part"), 600 * kKB, 5);
    QVERIFY(!old.isEmpty() && !partial.isEmpty());

    const CacheStore::Result result = store.enforce();

    QCOMPARE(result.removedFiles, 1);
    QVERIFY2(!QFile::exists(partial), "半截文件没有优先淘汰");
    QVERIFY2(QFile::exists(old), "为了删半截文件误删了完整文件");
}

void TestCacheStore::touchMovesFileToNewest()
{
    CacheStore store(m_temp->path(), kMB, {part(QStringLiteral("a"), 32, 1)});

    const QString seen = makeFile(QStringLiteral("a"), QStringLiteral("seen.bin"), 600 * kKB, 900);
    const QString stale =
        makeFile(QStringLiteral("a"), QStringLiteral("stale.bin"), 600 * kKB, 600);
    QVERIFY(!seen.isEmpty() && !stale.isEmpty());

    // 刚读过它：mtime 刷新到现在，淘汰顺序里就排到最后了
    QVERIFY(CacheStore::touch(seen));

    const CacheStore::Result result = store.enforce();

    QCOMPARE(result.removedFiles, 1);
    QVERIFY2(QFile::exists(seen), "刚读过的被当成旧数据删了");
    QVERIFY(!QFile::exists(stale));
}

void TestCacheStore::purgesOnePartitionOnly()
{
    // 设置页「单项清理」：只动点名的那一个分区，别碰别的
    CacheStore store(m_temp->path(), 100 * kMB,
                     {part(QStringLiteral("a"), 32, 1), part(QStringLiteral("b"), 32, 1)});

    const QString a1 = makeFile(QStringLiteral("a"), QStringLiteral("x.bin"), 10 * kKB, 10);
    const QString a2 = makeFile(QStringLiteral("a"), QStringLiteral("y.bin"), 20 * kKB, 20);
    const QString b1 = makeFile(QStringLiteral("b"), QStringLiteral("z.bin"), 30 * kKB, 30);
    QVERIFY(!a1.isEmpty() && !a2.isEmpty() && !b1.isEmpty());

    const CacheStore::Result result = store.purge(QStringLiteral("a"));

    QCOMPARE(result.removedFiles, 2);
    QCOMPARE(result.removedBytes, 30 * kKB);
    QVERIFY(!QFile::exists(a1));
    QVERIFY(!QFile::exists(a2));
    QVERIFY2(QFile::exists(b1), "清空 a 时把 b 也删了");

    // 分区根目录保留（下次写入直接用，不必重建）
    QVERIFY(QDir(m_temp->filePath(QStringLiteral("a"))).exists());
    // 清完之后统计要跟着变（设置页读的就是这份）
    const CacheStore::Scan after = store.scan();
    QCOMPARE(after.partitions.size(), 2); // b 还在，a 目录还在
    QCOMPARE(after.partitions.at(0).files, 0);
    QCOMPARE(after.totalBytes, 30 * kKB);
}

void TestCacheStore::purgeAllHonoursProtectionAndPrunesDirs()
{
    // 全部清理：正在播放 / 正在下载的前缀要留下，空子目录要收掉
    CacheStore store(m_temp->path(), 100 * kMB);

    const QString keep =
        makeFile(QStringLiteral("a"), QStringLiteral("sub/keep.bin"), 10 * kKB, 900);
    const QString drop = makeFile(QStringLiteral("b"), QStringLiteral("deep/x.bin"), 20 * kKB, 900);
    QVERIFY(!keep.isEmpty() && !drop.isEmpty());

    const CacheStore::Result result = store.purge(QString(), {keep});

    QCOMPARE(result.removedFiles, 1);
    QCOMPARE(result.removedBytes, 20 * kKB);
    QVERIFY2(QFile::exists(keep), "受保护的缓存文件被清掉了");
    QVERIFY(!QFile::exists(drop));
    // 一文件一子目录的分片 / 整包：空壳要删，否则设置页看着像没清干净
    QVERIFY2(!QDir(m_temp->filePath(QStringLiteral("b/deep"))).exists(), "空子目录没清掉");
    QVERIFY(QDir(m_temp->filePath(QStringLiteral("b"))).exists());
}

void TestCacheStore::appliesUpdatedTotalLimit()
{
    // 设置页把上限从 100MB 调到 1MB：不用重建 CacheStore，下一次 enforce 就按新值收口
    CacheStore store(m_temp->path(), 100 * kMB, {part(QStringLiteral("a"), 32, 1)});

    const QString old = makeFile(QStringLiteral("a"), QStringLiteral("old.bin"), 600 * kKB, 900);
    const QString fresh = makeFile(QStringLiteral("a"), QStringLiteral("new.bin"), 600 * kKB, 30);
    QVERIFY(!old.isEmpty() && !fresh.isEmpty());

    // 100MB 上限下什么都不该删
    QCOMPARE(store.enforce().removedFiles, 0);

    store.setTotalLimitBytes(kMB);
    QCOMPARE(store.totalLimitBytes(), kMB);

    const CacheStore::Result result = store.enforce();
    QCOMPARE(result.removedFiles, 1);
    QVERIFY2(!QFile::exists(old), "新上限下最旧的没被淘汰");
    QVERIFY(QFile::exists(fresh));
}

void TestCacheStore::toleratesMissingRoot()
{
    CacheStore store(m_temp->filePath(QStringLiteral("nope")), kMB);

    const CacheStore::Scan scan = store.scan();
    QVERIFY(scan.partitions.isEmpty());
    QCOMPARE(scan.totalBytes, qint64(0));
    QCOMPARE(scan.totalFiles, 0);

    const CacheStore::Result result = store.enforce();
    QCOMPARE(result.removedFiles, 0);
    QCOMPARE(result.removedBytes, qint64(0));

    // 空路径 / 不存在的文件：静默失败，不崩
    QVERIFY(!CacheStore::touch(QString()));
    QVERIFY(!CacheStore::touch(m_temp->filePath(QStringLiteral("missing.bin"))));
}

QTEST_MAIN(TestCacheStore)
#include "tst_cachestore.moc"
