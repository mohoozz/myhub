#include "core/storage/StorageAdapter.h"
#include "core/stream/AdapterRangeSource.h"
#include "core/stream/CachedRangeReader.h"
#include "core/stream/RangeSource.h"
#include "core/stream/SegmentCache.h"

#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTest>
#include <QTimer>

using namespace myhub;

namespace {

/// 可控的假数据源：整段内存、可延迟、可失败
class FakeSource : public RangeSource
{
public:
    QByteArray payload;
    int calls = 0;
    int delayMs = 0;
    bool failNext = false;

    qint64 size() const override { return payload.size(); }

    void readRange(qint64 start, qint64 length, Callback cb) override
    {
        ++calls;
        if (canceled()) {
            cb({}, StorageError(StorageError::Cancelled, QStringLiteral("canceled")));
            return;
        }
        if (failNext) {
            failNext = false;
            cb({}, StorageError(StorageError::Offline, QStringLiteral("boom")));
            return;
        }
        QByteArray data;
        if (start < payload.size()) {
            const qint64 available = qMin<qint64>(length, payload.size() - start);
            data = payload.mid(static_cast<int>(start), static_cast<int>(available));
        }
        if (delayMs <= 0) {
            cb(data, StorageError());
            return;
        }
        QTimer::singleShot(delayMs, this, [cb, data]() { cb(data, StorageError()); });
    }
};

/// 假适配器：只实现读取相关虚函数
class FakeAdapter : public StorageAdapter
{
public:
    QByteArray payload;
    int calls = 0;
    int failuresBeforeSuccess = 0;
    bool shortReads = false;
    bool silent = false;
    QList<qint64> starts;

    QString typeName() const override { return QStringLiteral("fake"); }
    void list(const QString &, ListCallback cb) override { cb(ListResult::success({})); }
    void stat(const QString &, StatCallback cb) override
    {
        cb(StatResult::failure(StorageError(StorageError::InvalidPath, QString())));
    }
    void testConnection(ErrorCallback cb) override { cb(StorageError()); }

    void readRange(const QString &, std::optional<qint64> start, std::optional<qint64> end,
                   DataCallback cb) override
    {
        ++calls;
        const qint64 s = start.value_or(0);
        starts.append(s);
        if (silent)
            return;
        if (calls <= failuresBeforeSuccess) {
            QTimer::singleShot(0, this, [cb]() {
                cb(DataResult::failure(
                    StorageError(StorageError::Offline, QStringLiteral("down"))));
            });
            return;
        }
        const qint64 e = end.value_or(payload.size() - 1);
        QByteArray data;
        if (s < payload.size()) {
            const qint64 available = qMin<qint64>(e, payload.size() - 1) - s + 1;
            if (available > 0)
                data = payload.mid(static_cast<int>(s), static_cast<int>(available));
        }
        if (shortReads && data.size() > 2)
            data.truncate(data.size() / 2);
        QTimer::singleShot(0, this, [cb, data]() { cb(DataResult::success(data)); });
    }
};

QByteArray makePayload(int size)
{
    QByteArray data(size, Qt::Uninitialized);
    for (int i = 0; i < size; ++i)
        data[i] = static_cast<char>((i * 31 + 7) % 251);
    return data;
}

} // namespace

class TestStreamCache : public QObject
{
    Q_OBJECT

private slots:
    void cacheKeyIsStable();
    void cacheWriteRead();
    void cacheEvictsFarthestFromPlayhead();
    void cacheIdentityLookup();

    void readerAssemblesAcrossSegments();
    void readerDeduplicatesInFlightRequests();
    void readerPrefetches();
    void readerOfflineMissFailsWithoutSourceCall();
    void readerOfflineServesCompleteCacheWithoutSource();
    void readerCancelFailsPending();

    void adapterFillsWholeRequestAcrossBlocks();
    void adapterRetriesTransientFailure();
    void adapterKeepsPartialProgress();
    void adapterTimesOutSilently();

private:
    QTemporaryDir m_dir;
    SegmentCache::Config config() const;
};

SegmentCache::Config TestStreamCache::config() const
{
    SegmentCache::Config cfg;
    cfg.rootDir = m_dir.filePath(QStringLiteral("cache"));
    cfg.segmentBytes = 1024 * 1024;
    cfg.totalLimitBytes = qint64(32) * 1024 * 1024;
    return cfg;
}

void TestStreamCache::cacheKeyIsStable()
{
    QVERIFY(m_dir.isValid());
    const QString a = SegmentCache::keyFor(QStringLiteral("c1"), QStringLiteral("/a.mkv"),
                                           QStringLiteral("100:200"));
    QCOMPARE(a.size(), 16);
    QCOMPARE(a,
             SegmentCache::keyFor(QStringLiteral("c1"), QStringLiteral("/a.mkv"),
                                  QStringLiteral("100:200")));
    QVERIFY(a
            != SegmentCache::keyFor(QStringLiteral("c2"), QStringLiteral("/a.mkv"),
                                    QStringLiteral("100:200")));
}

void TestStreamCache::cacheWriteRead()
{
    SegmentCache cache(config());
    const QString key = SegmentCache::keyFor(QStringLiteral("c1"), QStringLiteral("/a.mkv"),
                                             QStringLiteral("100:200"));

    QVERIFY(!cache.contains(key, 0));
    QVERIFY(cache.writeSegment(key, 0, QByteArrayLiteral("hello")));
    QVERIFY(cache.contains(key, 0));
    QCOMPARE(cache.readSegment(key, 0), QByteArrayLiteral("hello"));
    QCOMPARE(cache.totalBytes(), qint64(5));

    // 指纹不同 → 不同的键（同名文件被替换后旧分片不得复用）
    const QString other = SegmentCache::keyFor(QStringLiteral("c1"), QStringLiteral("/a.mkv"),
                                               QStringLiteral("100:300"));
    QVERIFY(other != key);
    QVERIFY(!cache.contains(other, 0));

    cache.removeFile(key);
    QVERIFY(!cache.contains(key, 0));
    QCOMPARE(cache.totalBytes(), qint64(0));
}

void TestStreamCache::cacheEvictsFarthestFromPlayhead()
{
    SegmentCache::Config cfg = config();
    cfg.totalLimitBytes = 8LL * 1024 * 1024; // 单文件上限 = 2MB = 2 个分片
    SegmentCache cache(cfg);

    const QString key =
        SegmentCache::keyFor(QStringLiteral("c1"), QStringLiteral("/b.mkv"), QStringLiteral("1:2"));
    const QByteArray segment(1 << 20, 'x');

    cache.setPlayhead(key, 0); // 播放点在第 0 片
    for (int i = 0; i < 5; ++i)
        QVERIFY(cache.writeSegment(key, i, segment));

    QVERIFY(cache.contains(key, 0)); // 播放点所在分片必须保住
    QVERIFY(cache.fileBytes(key) <= cache.fileLimitBytes());
    QVERIFY(!cache.contains(key, 4));
}

void TestStreamCache::cacheIdentityLookup()
{
    SegmentCache cache(config());

    const QString first = SegmentCache::keyFor(QStringLiteral("c1"), QStringLiteral("/x.mkv"),
                                               QStringLiteral("10:1"));
    QVariantMap meta;
    meta.insert(QStringLiteral("connectionId"), QStringLiteral("c1"));
    meta.insert(QStringLiteral("path"), QStringLiteral("/x.mkv"));
    meta.insert(QStringLiteral("name"), QStringLiteral("x.mkv"));
    meta.insert(QStringLiteral("size"), qint64(10));
    cache.writeMeta(first, meta);

    QVariantMap found;
    QVERIFY(cache.findCachedIdentity(QStringLiteral("c1"), QStringLiteral("/x.mkv"), &found));
    QCOMPARE(found.value(QStringLiteral("size")).toLongLong(), qint64(10));
    QCOMPARE(found.value(QStringLiteral("key")).toString(), first);

    QVERIFY(!cache.findCachedIdentity(QStringLiteral("c1"), QStringLiteral("/y.mkv"), &found));
    QVERIFY(!cache.findCachedIdentity(QStringLiteral("c2"), QStringLiteral("/x.mkv"), &found));
}

void TestStreamCache::readerAssemblesAcrossSegments()
{
    SegmentCache cache(config());
    FakeSource source;
    source.payload = makePayload(3 * 1024 * 1024 + 512);

    const QString key =
        SegmentCache::keyFor(QStringLiteral("c1"), QStringLiteral("/m.mkv"), QStringLiteral("1:1"));
    CachedRangeReader reader(&source, &cache, key);

    QByteArray got;
    bool done = false;
    reader.read(0, 2 * 1024 * 1024 + 1024, [&](QByteArray data, StorageError error) {
        QVERIFY(error.isNull());
        got = data;
        done = true;
    });

    QTRY_VERIFY(done);
    QCOMPARE(got, source.payload.left(2 * 1024 * 1024 + 1024));
    QCOMPARE(source.calls, 3); // 跨 3 个分片
    QVERIFY(cache.contains(key, 0));
    QVERIFY(cache.contains(key, 1));
    QVERIFY(cache.contains(key, 2));
}

void TestStreamCache::readerDeduplicatesInFlightRequests()
{
    SegmentCache cache(config());
    FakeSource source;
    source.payload = makePayload(4 * 1024 * 1024);
    source.delayMs = 30;

    const QString key =
        SegmentCache::keyFor(QStringLiteral("c1"), QStringLiteral("/d.mkv"), QStringLiteral("1:1"));
    CachedRangeReader reader(&source, &cache, key);

    int completed = 0;
    reader.read(0, 100, [&](QByteArray, StorageError error) {
        QVERIFY(error.isNull());
        ++completed;
    });
    reader.read(100, 100, [&](QByteArray, StorageError error) {
        QVERIFY(error.isNull());
        ++completed;
    });

    QTRY_COMPARE_WITH_TIMEOUT(completed, 2, 5000);
    QCOMPARE(source.calls, 1); // 同一分片只发一次源请求
    QCOMPARE(reader.stats().value(QStringLiteral("deduped")).toInt(), 1);
}

void TestStreamCache::readerPrefetches()
{
    SegmentCache cache(config());
    FakeSource source;
    source.payload = makePayload(4 * 1024 * 1024);

    const QString key =
        SegmentCache::keyFor(QStringLiteral("c1"), QStringLiteral("/p.mkv"), QStringLiteral("1:1"));
    CachedRangeReader reader(&source, &cache, key);
    reader.setPrefetchSegments(2);
    reader.setMaxConcurrent(1);

    bool done = false;
    reader.read(0, 1024, [&](QByteArray, StorageError error) {
        QVERIFY(error.isNull());
        done = true;
    });

    QTRY_VERIFY(done);
    // 分片 0 完成后预读 1、2
    QTRY_VERIFY_WITH_TIMEOUT(cache.contains(key, 2), 5000);
    QCOMPARE(source.calls, 3);
}

void TestStreamCache::readerOfflineMissFailsWithoutSourceCall()
{
    SegmentCache cache(config());
    FakeSource source;
    source.payload = makePayload(2 * 1024 * 1024);

    const QString key =
        SegmentCache::keyFor(QStringLiteral("c1"), QStringLiteral("/o.mkv"), QStringLiteral("1:1"));
    CachedRangeReader reader(&source, &cache, key);
    reader.setOfflineMode(true);

    StorageError error;
    reader.read(0, 1024, [&](QByteArray, StorageError e) { error = e; });

    QVERIFY(!error.isNull());
    QCOMPARE(error.kind(), StorageError::Offline);
    QCOMPARE(source.calls, 0);
}

void TestStreamCache::readerOfflineServesCompleteCacheWithoutSource()
{
    SegmentCache cache(config());
    const QString key = SegmentCache::keyFor(QStringLiteral("c1"), QStringLiteral("/full.mkv"),
                                             QStringLiteral("100:200"));
    const QByteArray payload = makePayload(2 * 1024 * 1024);
    const int bytes = cache.segmentBytes();

    // 模拟「在线时整部片都缓存过」：两片齐全
    QVERIFY(cache.writeSegment(key, 0, payload.mid(0, bytes)));
    QVERIFY(cache.writeSegment(key, 1, payload.mid(bytes)));
    QCOMPARE(cache.segmentCount(key), 2);

    // 无源（断网）+ 声明的总长度：只吃缓存也能把区间拼出来
    CachedRangeReader reader(nullptr, &cache, key);
    reader.setDeclaredSize(payload.size());
    reader.setOfflineMode(true);
    QCOMPARE(reader.size(), qint64(payload.size()));

    constexpr int kOffset = 1024;
    constexpr int kLength = 512 * 1024;
    QByteArray got;
    StorageError error;
    reader.read(kOffset, kLength, [&](QByteArray data, StorageError e) {
        got = data;
        error = e;
    });

    QVERIFY(error.isNull());
    QCOMPARE(got, payload.mid(kOffset, kLength));
}

void TestStreamCache::readerCancelFailsPending()
{
    SegmentCache cache(config());
    FakeSource source;
    source.payload = makePayload(2 * 1024 * 1024);
    source.delayMs = 50;

    const QString key =
        SegmentCache::keyFor(QStringLiteral("c1"), QStringLiteral("/c.mkv"), QStringLiteral("1:1"));
    CachedRangeReader reader(&source, &cache, key);

    StorageError error;
    bool called = false;
    reader.read(0, 1024, [&](QByteArray, StorageError e) {
        error = e;
        called = true;
    });
    reader.cancelAll();

    QVERIFY(called);
    QCOMPARE(error.kind(), StorageError::Cancelled);

    // 注销后新请求直接失败，不发源请求
    const int before = source.calls;
    StorageError after;
    reader.read(0, 1024, [&](QByteArray, StorageError e) { after = e; });
    QCOMPARE(after.kind(), StorageError::Cancelled);
    QCOMPARE(source.calls, before);
}

void TestStreamCache::adapterFillsWholeRequestAcrossBlocks()
{
    FakeAdapter adapter;
    adapter.payload = makePayload(512 * 1024);
    AdapterRangeSource source(&adapter, QStringLiteral("/f.mkv"), adapter.payload.size());
    AdapterRangeSource::Policy policy;
    policy.blockBytes = 64 * 1024;
    source.setPolicy(policy);

    constexpr int kRequestBytes = 256 * 1024;
    QByteArray got;
    source.readRange(1000, kRequestBytes, [&](QByteArray data, StorageError error) {
        QVERIFY(error.isNull());
        got = data;
    });

    QTRY_COMPARE(got.size(), qsizetype(kRequestBytes));
    QCOMPARE(got, adapter.payload.mid(1000, kRequestBytes));
    QCOMPARE(adapter.calls, 4); // 256KB / 64KB
}

void TestStreamCache::adapterRetriesTransientFailure()
{
    FakeAdapter adapter;
    adapter.payload = makePayload(128 * 1024);
    adapter.failuresBeforeSuccess = 1;
    AdapterRangeSource source(&adapter, QStringLiteral("/r.mkv"), adapter.payload.size());
    AdapterRangeSource::Policy policy;
    policy.backoffMs = 5;
    policy.maxAttempts = 3;
    source.setPolicy(policy);

    QByteArray got;
    StorageError error;
    constexpr int kRequestBytes = 32 * 1024;
    source.readRange(0, kRequestBytes, [&](QByteArray data, StorageError e) {
        got = data;
        error = e;
    });

    QTRY_VERIFY(!got.isEmpty());
    QVERIFY(error.isNull());
    QCOMPARE(got, adapter.payload.left(kRequestBytes));
    QCOMPARE(source.retryCount(), 1);
}

void TestStreamCache::adapterKeepsPartialProgress()
{
    FakeAdapter adapter;
    adapter.payload = makePayload(256 * 1024);
    adapter.shortReads = true; // 每次只给一半，模拟短读
    AdapterRangeSource source(&adapter, QStringLiteral("/s.mkv"), adapter.payload.size());
    AdapterRangeSource::Policy policy;
    policy.blockBytes = 64 * 1024;
    source.setPolicy(policy);

    constexpr int kRequestBytes = 64 * 1024;
    QByteArray got;
    source.readRange(0, kRequestBytes, [&](QByteArray data, StorageError) { got = data; });

    QTRY_COMPARE(got.size(), qsizetype(kRequestBytes));
    QCOMPARE(got, adapter.payload.left(kRequestBytes));
    // 第二次请求必须从已下载字节处继续（断点续传），而不是回到 0
    QVERIFY(adapter.starts.size() >= 2);
    QCOMPARE(adapter.starts.at(1), qint64(32 * 1024));
}

void TestStreamCache::adapterTimesOutSilently()
{
    FakeAdapter adapter;
    adapter.payload = makePayload(64 * 1024);
    adapter.silent = true; // 永不回调
    AdapterRangeSource source(&adapter, QStringLiteral("/t.mkv"), adapter.payload.size());
    AdapterRangeSource::Policy policy;
    policy.stallTimeoutMs = 30;
    policy.maxAttempts = 2;
    policy.backoffMs = 5;
    source.setPolicy(policy);

    StorageError error;
    bool called = false;
    source.readRange(0, 1024, [&](QByteArray, StorageError e) {
        error = e;
        called = true;
    });

    QTRY_VERIFY_WITH_TIMEOUT(called, 5000);
    QVERIFY(!error.isNull());
    QCOMPARE(error.kind(), StorageError::Offline);
}

QTEST_GUILESS_MAIN(TestStreamCache)
#include "tst_streamcache.moc"
