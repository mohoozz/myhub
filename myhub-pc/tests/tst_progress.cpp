// 阅读进度与续播单测（PC-209）
//
// 覆盖两层：
//   ProgressRepository          —— 落库/查回/唯一性/删除/续播起点规则
//   PlaybackProgressTracker     —— 节流上报、暂停/seek/播完/切换/退出强制落盘
//
// 用 FakeEngine 上报「播放事实」，因此不依赖任何真实解码器。
// 数据库用临时目录里的真实 sqlite 文件（走与生产相同的迁移路径）。

#include <QFileInfo>
#include <QSignalSpy>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QtTest>

#include "core/database/AppDatabase.h"
#include "core/history/ProgressRepository.h"
#include "core/player/PlaybackEngine.h"
#include "core/player/PlaybackProgressTracker.h"
#include "core/player/PlayerCore.h"
#include "core/preferences/AppSettings.h"
#include "core/utils/AppPaths.h"

using namespace myhub;

namespace {

class FakeEngine : public PlaybackEngine
{
public:
    int loadCount = 0;
    PlaybackRequest lastRequest;

    void load(const PlaybackRequest &request) override
    {
        lastRequest = request;
        ++loadCount;
    }
    void play() override {}
    void pause() override {}
    void stop() override {}
    void seek(qint64) override {}
    void setVolume(double) override {}
    void setMuted(bool) override {}
    void setSpeed(double) override {}
    void selectAudioTrack(int) override {}
    void selectSubtitleTrack(int) override {}
    void addSubtitleFile(const QUrl &) override {}
    void setAudioOnly(bool) override {}
    void setDecodePreference(const QString &) override {}
};

PlaybackRequest requestFor(const QString &path,
                           const QString &connectionId = QStringLiteral("conn-1"))
{
    PlaybackRequest request;
    request.path = path;
    request.url = QUrl::fromLocalFile(path);
    request.title = QFileInfo(path).fileName();
    request.connectionId = connectionId;
    return request;
}

ProgressRecord recordFor(const QString &path, qint64 positionMs, qint64 durationMs)
{
    ProgressRecord record;
    record.connectionId = QStringLiteral("conn-1");
    record.path = path;
    record.mediaType = QStringLiteral("video");
    record.title = QStringLiteral("demo");
    record.progress.insert(QStringLiteral("positionMs"), positionMs);
    record.progress.insert(QStringLiteral("durationMs"), durationMs);
    record.percent = durationMs > 0 ? double(positionMs) / double(durationMs) : 0.0;
    return record;
}

} // namespace

class TestProgress : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void init();
    void cleanup();

    // ---- 仓库 ----
    void upsertThenFindRoundTrip();
    void upsertOverwritesSameFile();
    void upsertKeepsExistingCover();
    void recentReturnsNewestFirst();
    void briefsCoversWholeConnection();
    void removeDeletesOnlyThatFile();

    // ---- 续播规则 ----
    void resumeRule_data();
    void resumeRule();

    // ---- 上报器 ----
    void pauseFlushesProgress();
    void playingIsThrottled();
    void seekFlushesImmediately();
    void endMarksFinished();
    void closeKeepsLastProgress();
    void switchingFileFlushesPrevious();

private:
    /// 起播并推进到 positionMs（模拟引擎上报的事实）
    void playTo(qint64 positionMs, qint64 durationMs = 100000);

    QTemporaryDir m_dir;
    PlayerCore *m_core = nullptr;
    FakeEngine *m_engine = nullptr;
    PlayerCore *m_spareCore = nullptr; // 供跨会话用例复用
};

void TestProgress::initTestCase()
{
    QCoreApplication::setApplicationName(
        QStringLiteral("MyHubProgressTest-%1").arg(QCoreApplication::applicationPid()));
    QStandardPaths::setTestModeEnabled(true);
    AppPaths::initializeAll();
    AppSettings::instance().initialize();

    QVERIFY(m_dir.isValid());
    QVERIFY(AppDatabase::instance().open(m_dir.filePath(QStringLiteral("myhub.sqlite"))));
}

void TestProgress::init()
{
    QVERIFY(AppDatabase::instance().execute(QStringLiteral("DELETE FROM readingProgress")));

    m_engine = new FakeEngine;
    m_core = new PlayerCore(this);
    m_core->setEngine(m_engine);
}

void TestProgress::cleanup()
{
    m_core->setEngine(nullptr);
    delete m_core;
    m_core = nullptr;
    delete m_engine;
    m_engine = nullptr;
    delete m_spareCore;
    m_spareCore = nullptr;
}

void TestProgress::playTo(qint64 positionMs, qint64 durationMs)
{
    emit m_engine->fileLoaded(durationMs, true, true);
    emit m_engine->positionChanged(positionMs);
    QCOMPARE(m_core->positionMs(), positionMs);
}

// ---------------------------------------------------------------- 仓库

void TestProgress::upsertThenFindRoundTrip()
{
    auto &repo = ProgressRepository::instance();
    QSignalSpy spy(&repo, &ProgressRepository::progressChanged);

    QVERIFY(repo.upsert(recordFor(QStringLiteral("C:/media/a.mkv"), 30000, 100000)));
    QCOMPARE(spy.count(), 1);

    ProgressRecord found;
    QVERIFY(repo.find(QStringLiteral("conn-1"), QStringLiteral("C:/media/a.mkv"), &found));
    QCOMPARE(found.positionMs(), qint64(30000));
    QCOMPARE(found.durationMs(), qint64(100000));
    QCOMPARE(found.mediaType, QStringLiteral("video"));
    QVERIFY(!found.finished);
    QVERIFY(found.updatedAt > 0);
    QVERIFY(qAbs(found.percent - 0.3) < 1e-6);

    // 未记录过的路径必须明确返回「没有」，不得给出一条空记录
    ProgressRecord missing;
    QVERIFY(!repo.find(QStringLiteral("conn-1"), QStringLiteral("C:/media/none.mkv"), &missing));
    QCOMPARE(repo.count(), 1);
}

void TestProgress::upsertOverwritesSameFile()
{
    auto &repo = ProgressRepository::instance();
    const QString path = QStringLiteral("C:/media/b.mkv");

    QVERIFY(repo.upsert(recordFor(path, 10000, 100000)));
    QVERIFY(repo.upsert(recordFor(path, 60000, 100000)));

    QCOMPARE(repo.count(), 1); // 唯一索引生效，不产生第二条
    ProgressRecord found;
    QVERIFY(repo.find(QStringLiteral("conn-1"), path, &found));
    QCOMPARE(found.positionMs(), qint64(60000));
    QVERIFY(qAbs(found.percent - 0.6) < 1e-6);
}

void TestProgress::upsertKeepsExistingCover()
{
    auto &repo = ProgressRepository::instance();
    const QString path = QStringLiteral("C:/media/c.mp4");

    ProgressRecord withCover = recordFor(path, 5000, 100000);
    withCover.cover = QStringLiteral("C:/cache/cover.jpg");
    QVERIFY(repo.upsert(withCover));

    // 播放侧上报不带封面：不得把已有封面清空
    QVERIFY(repo.upsert(recordFor(path, 20000, 100000)));

    ProgressRecord found;
    QVERIFY(repo.find(QStringLiteral("conn-1"), path, &found));
    QCOMPARE(found.cover, QStringLiteral("C:/cache/cover.jpg"));
    QCOMPARE(found.positionMs(), qint64(20000));
}

void TestProgress::recentReturnsNewestFirst()
{
    auto &repo = ProgressRepository::instance();
    QVERIFY(repo.upsert(recordFor(QStringLiteral("C:/media/old.mkv"), 1000, 100000)));
    QTest::qSleep(5); // updatedAt 精度是毫秒，避免同一毫秒内并列
    QVERIFY(repo.upsert(recordFor(QStringLiteral("C:/media/new.mkv"), 2000, 100000)));

    const auto recent = repo.recent(10);
    QCOMPARE(recent.size(), 2);
    QCOMPARE(recent.first().path, QStringLiteral("C:/media/new.mkv"));
    QCOMPARE(repo.recent(1).size(), 1);
}

void TestProgress::briefsCoversWholeConnection()
{
    auto &repo = ProgressRepository::instance();
    QVERIFY(repo.upsert(recordFor(QStringLiteral("C:/media/b1.mkv"), 30000, 100000)));
    ProgressRecord watched = recordFor(QStringLiteral("C:/media/b2.mkv"), 100000, 100000);
    watched.finished = true;
    QVERIFY(repo.upsert(watched));

    // 其它连接源的记录不得混进来（浏览页按连接源查表）
    ProgressRecord other = recordFor(QStringLiteral("C:/media/b3.mkv"), 5000, 100000);
    other.connectionId = QStringLiteral("conn-2");
    QVERIFY(repo.upsert(other));

    const auto briefs = repo.briefs(QStringLiteral("conn-1"));
    QCOMPARE(briefs.size(), 2);
    QVERIFY(qAbs(briefs.value(QStringLiteral("C:/media/b1.mkv")).percent - 0.3) < 1e-6);
    QVERIFY(!briefs.value(QStringLiteral("C:/media/b1.mkv")).finished);
    QVERIFY(briefs.value(QStringLiteral("C:/media/b2.mkv")).finished);
    QVERIFY(qAbs(briefs.value(QStringLiteral("C:/media/b2.mkv")).percent - 1.0) < 1e-6);
    // 未知连接源：空表（浏览页据此认为「这个源没有任何进度」）
    QVERIFY(repo.briefs(QStringLiteral("conn-none")).isEmpty());
    QVERIFY(repo.briefs(QString()).isEmpty());
}

void TestProgress::removeDeletesOnlyThatFile()
{
    auto &repo = ProgressRepository::instance();
    const QString keep = QStringLiteral("C:/media/keep.mkv");
    const QString drop = QStringLiteral("C:/media/drop.mkv");
    QVERIFY(repo.upsert(recordFor(keep, 1000, 100000)));
    QVERIFY(repo.upsert(recordFor(drop, 2000, 100000)));

    QSignalSpy spy(&repo, &ProgressRepository::progressRemoved);
    QVERIFY(repo.remove(QStringLiteral("conn-1"), drop));
    QCOMPARE(spy.count(), 1);

    ProgressRecord found;
    QVERIFY(!repo.find(QStringLiteral("conn-1"), drop, &found));
    QVERIFY(repo.find(QStringLiteral("conn-1"), keep, &found)); // 不影响源文件与其它记录
}

// ---------------------------------------------------------------- 续播规则

void TestProgress::resumeRule_data()
{
    QTest::addColumn<qint64>("position");
    QTest::addColumn<qint64>("duration");
    QTest::addColumn<bool>("finished");
    QTest::addColumn<qint64>("expected");

    QTest::newRow("middle resumes at position")
        << qint64(42000) << qint64(100000) << false << qint64(42000);
    QTest::newRow("flagged finished restarts")
        << qint64(42000) << qint64(100000) << true << qint64(0);
    QTest::newRow("near end restarts") << qint64(99000) << qint64(100000) << false << qint64(0);
    QTest::newRow("zero position restarts") << qint64(0) << qint64(100000) << false << qint64(0);
    QTest::newRow("unknown duration keeps position")
        << qint64(7000) << qint64(0) << false << qint64(7000);
}

void TestProgress::resumeRule()
{
    QFETCH(qint64, position);
    QFETCH(qint64, duration);
    QFETCH(bool, finished);
    QFETCH(qint64, expected);

    ProgressRecord record = recordFor(QStringLiteral("C:/media/r.mkv"), position, duration);
    record.finished = finished;
    QCOMPARE(ProgressRepository::resumePositionMs(record), expected);
}

// ---------------------------------------------------------------- 上报器

void TestProgress::pauseFlushesProgress()
{
    PlaybackProgressTracker tracker(m_core, &ProgressRepository::instance());
    m_core->open(requestFor(QStringLiteral("C:/media/pause.mkv")));
    playTo(30000);

    // 节流间隔内不该落盘
    ProgressRecord found;
    QVERIFY(!ProgressRepository::instance().find(QStringLiteral("conn-1"),
                                                 QStringLiteral("C:/media/pause.mkv"), &found));

    emit m_engine->pausedChanged(true); // 暂停 → 强制落盘
    QVERIFY(ProgressRepository::instance().find(QStringLiteral("conn-1"),
                                                QStringLiteral("C:/media/pause.mkv"), &found));
    QCOMPARE(found.positionMs(), qint64(30000));
    QCOMPARE(found.durationMs(), qint64(100000));
    QCOMPARE(found.mediaType, QStringLiteral("video"));
    QCOMPARE(found.title, QStringLiteral("pause.mkv"));
}

void TestProgress::playingIsThrottled()
{
    PlaybackProgressTracker tracker(m_core, &ProgressRepository::instance());
    tracker.setIntervalMs(30);

    m_core->open(requestFor(QStringLiteral("C:/media/throttle.mkv")));
    playTo(10000);

    ProgressRecord found;
    const QString path = QStringLiteral("C:/media/throttle.mkv");
    QVERIFY(!ProgressRepository::instance().find(QStringLiteral("conn-1"), path, &found));

    QTRY_VERIFY_WITH_TIMEOUT(
        ProgressRepository::instance().find(QStringLiteral("conn-1"), path, &found), 2000);
    QCOMPARE(found.positionMs(), qint64(10000));
}

void TestProgress::seekFlushesImmediately()
{
    PlaybackProgressTracker tracker(m_core, &ProgressRepository::instance());
    m_core->open(requestFor(QStringLiteral("C:/media/seek.mkv")));
    playTo(5000);

    m_core->seekTo(70000); // 定位必须立即落盘，不等节流

    ProgressRecord found;
    QVERIFY(ProgressRepository::instance().find(QStringLiteral("conn-1"),
                                                QStringLiteral("C:/media/seek.mkv"), &found));
    QCOMPARE(found.positionMs(), qint64(70000));
}

void TestProgress::endMarksFinished()
{
    PlaybackProgressTracker tracker(m_core, &ProgressRepository::instance());
    m_core->open(requestFor(QStringLiteral("C:/media/end.mkv")));
    playTo(90000);

    emit m_engine->endReached();

    ProgressRecord found;
    QVERIFY(ProgressRepository::instance().find(QStringLiteral("conn-1"),
                                                QStringLiteral("C:/media/end.mkv"), &found));
    QVERIFY(found.finished);
    QCOMPARE(found.positionMs(), qint64(100000));
    QVERIFY(qAbs(found.percent - 1.0) < 1e-6);
    // 看完后再打开必须从头播，而不是停在片尾
    QCOMPARE(ProgressRepository::resumePositionMs(found), qint64(0));
}

void TestProgress::closeKeepsLastProgress()
{
    PlaybackProgressTracker tracker(m_core, &ProgressRepository::instance());
    m_core->open(requestFor(QStringLiteral("C:/media/close.mkv")));
    playTo(45000);

    m_core->close(); // 退出播放器

    ProgressRecord found;
    QVERIFY(ProgressRepository::instance().find(QStringLiteral("conn-1"),
                                                QStringLiteral("C:/media/close.mkv"), &found));
    // 回归守卫：close() 内部会把 position 归零，落盘必须发生在归零之前
    QCOMPARE(found.positionMs(), qint64(45000));
    QCOMPARE(found.durationMs(), qint64(100000));
}

void TestProgress::switchingFileFlushesPrevious()
{
    PlaybackProgressTracker tracker(m_core, &ProgressRepository::instance());
    const QString first = QStringLiteral("C:/media/first.mkv");
    const QString second = QStringLiteral("C:/media/second.mkv");

    m_core->open(requestFor(first));
    playTo(25000);

    m_core->open(requestFor(second)); // 直接切到下一个文件

    ProgressRecord found;
    QVERIFY(ProgressRepository::instance().find(QStringLiteral("conn-1"), first, &found));
    QCOMPARE(found.positionMs(), qint64(25000));
    QVERIFY(!ProgressRepository::instance().find(QStringLiteral("conn-1"), second, &found));
}

QTEST_MAIN(TestProgress)
#include "tst_progress.moc"
