// 播放门面单测（《需求分析文档》§13 / §4.3）
//
// PlayerCore 位于 myhub_core、只依赖 QtCore，因此状态机可以完全脱离解码器验证：
// 这里注入 FakeEngine 上报「事实」，检查门面的策略是否与 PC-201~PC-209 一致。
//
// 注意：本测试使用独立的临时数据目录，不污染用户真实偏好。

#include <QSignalSpy>
#include <QStandardPaths>
#include <QtTest>

#include "core/player/PlayerCore.h"
#include "core/preferences/AppSettings.h"
#include "core/utils/AppPaths.h"

using namespace myhub;

namespace {

/// 记录所有下行调用，并把「事实」交给测试用 emit 触发
class FakeEngine : public PlaybackEngine
{
public:
    PlaybackRequest lastRequest;
    int loadCount = 0;
    int playCount = 0;
    int pauseCount = 0;
    int stopCount = 0;
    qint64 lastSeek = -1;
    double lastVolume = -1.0;
    double lastSpeed = -1.0;
    bool lastMuted = false;
    bool lastAudioOnly = false;
    bool lastAudioOnlySet = false;
    int lastAudioTrack = -999;
    int lastSubtitleTrack = -999;
    QUrl lastSubtitleFile;
    QString lastDecodePreference;

    void load(const PlaybackRequest &request) override
    {
        lastRequest = request;
        ++loadCount;
    }
    void play() override { ++playCount; }
    void pause() override { ++pauseCount; }
    void stop() override { ++stopCount; }
    void seek(qint64 positionMs) override { lastSeek = positionMs; }

    void setVolume(double volume) override { lastVolume = volume; }
    void setMuted(bool muted) override { lastMuted = muted; }
    void setSpeed(double speed) override { lastSpeed = speed; }

    void selectAudioTrack(int id) override { lastAudioTrack = id; }
    void selectSubtitleTrack(int id) override { lastSubtitleTrack = id; }
    void addSubtitleFile(const QUrl &url) override { lastSubtitleFile = url; }

    void setAudioOnly(bool audioOnly) override
    {
        lastAudioOnly = audioOnly;
        lastAudioOnlySet = true;
    }
    void setDecodePreference(const QString &mode) override { lastDecodePreference = mode; }
};

PlaybackRequest sampleRequest(qint64 startMs = 0)
{
    PlaybackRequest request;
    request.url = QUrl::fromLocalFile(QStringLiteral("C:/media/demo.mkv"));
    request.path = QStringLiteral("C:/media/demo.mkv");
    request.title = QStringLiteral("demo.mkv");
    request.startPositionMs = startMs;
    return request;
}

} // namespace

class TestPlayerCore : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void init();
    void cleanup();

    void openReportsLoadingAndPassesRequest();
    void openRestoresStartPosition();
    void openWithoutEngineFails();
    void openRejectsInvalidRequest();
    void fileLoadedMovesToPlaying();
    void fileLoadedHonoursPauseFact();
    void pausedFactDrivesState();
    void endedThenTogglePauseReplays();
    void seekIsClamped();
    void seekAfterEndedStaysPaused();
    void speedIsClamped();
    void volumeIsClampedAndPersisted();
    void audioOnlyHidesVideo();
    void tracksAreForwarded();
    void errorSurfacesMessage();
    void closeResetsToIdle();

private:
    PlayerCore *m_core = nullptr;
    FakeEngine *m_engine = nullptr;
};

void TestPlayerCore::initTestCase()
{
    // 隔离数据目录，避免污染真实用户数据
    QCoreApplication::setApplicationName(
        QStringLiteral("MyHubPlayerTest-%1").arg(QCoreApplication::applicationPid()));
    QStandardPaths::setTestModeEnabled(true);

    AppPaths::initializeAll();
    AppSettings::instance().initialize();
}

void TestPlayerCore::init()
{
    m_engine = new FakeEngine;
    m_core = new PlayerCore(this);
    m_core->setEngine(m_engine);
}

void TestPlayerCore::cleanup()
{
    m_core->setEngine(nullptr);
    delete m_core;
    m_core = nullptr;
    delete m_engine;
    m_engine = nullptr;
}

void TestPlayerCore::openReportsLoadingAndPassesRequest()
{
    QSignalSpy stateSpy(m_core, &PlayerCore::stateChanged);

    m_core->open(sampleRequest());

    QCOMPARE(m_core->state(), PlaybackState::Loading);
    QCOMPARE(m_engine->loadCount, 1);
    QCOMPARE(m_engine->lastRequest.title, QStringLiteral("demo.mkv"));
    QCOMPARE(m_engine->lastRequest.url, QUrl::fromLocalFile(QStringLiteral("C:/media/demo.mkv")));
    QCOMPARE(m_core->title(), QStringLiteral("demo.mkv"));
    QVERIFY(stateSpy.count() >= 1);
}

void TestPlayerCore::openRestoresStartPosition()
{
    // PC-209：续播点由请求携带，起播前就要体现在 UI 上
    m_core->open(sampleRequest(42000));

    QCOMPARE(m_core->positionMs(), qint64(42000));
    QCOMPARE(m_engine->loadCount, 1);
}

void TestPlayerCore::openWithoutEngineFails()
{
    PlayerCore core;
    core.open(sampleRequest());

    QCOMPARE(core.state(), PlaybackState::Error);
    QVERIFY(!core.errorText().isEmpty());
}

void TestPlayerCore::openRejectsInvalidRequest()
{
    m_core->open(PlaybackRequest());

    QCOMPARE(m_core->state(), PlaybackState::Error);
    QCOMPARE(m_engine->loadCount, 0);
}

void TestPlayerCore::fileLoadedMovesToPlaying()
{
    m_core->open(sampleRequest());
    m_engine->fileLoaded(90000, true, true);

    QCOMPARE(m_core->state(), PlaybackState::Playing);
    QCOMPARE(m_core->durationMs(), qint64(90000));
    QVERIFY(m_core->hasVideo());
}

void TestPlayerCore::fileLoadedHonoursPauseFact()
{
    // 起播瞬间 mpv 可能先报 pause=true（如自动播放被拦截），此时不能先 Playing 再 Paused
    m_core->open(sampleRequest());
    m_engine->pausedChanged(true);
    QCOMPARE(m_core->state(), PlaybackState::Loading);

    m_engine->fileLoaded(1000, true, true);
    QCOMPARE(m_core->state(), PlaybackState::Paused);
}

void TestPlayerCore::pausedFactDrivesState()
{
    m_core->open(sampleRequest());
    m_engine->fileLoaded(1000, true, true);

    m_engine->pausedChanged(true);
    QCOMPARE(m_core->state(), PlaybackState::Paused);

    m_engine->pausedChanged(false);
    QCOMPARE(m_core->state(), PlaybackState::Playing);
}

void TestPlayerCore::endedThenTogglePauseReplays()
{
    m_core->open(sampleRequest());
    m_engine->fileLoaded(5000, true, true);

    m_engine->endReached();
    QCOMPARE(m_core->state(), PlaybackState::Ended);
    QCOMPARE(m_core->positionMs(), qint64(5000));

    // PC-204：播完停在最后一帧，用户点击重播而不是自动连播
    m_core->togglePause();
    QCOMPARE(m_core->state(), PlaybackState::Playing);
    QCOMPARE(m_engine->lastSeek, qint64(0));
    QCOMPARE(m_core->positionMs(), qint64(0));
}

void TestPlayerCore::seekIsClamped()
{
    m_core->open(sampleRequest());
    m_engine->fileLoaded(90000, true, true);

    m_core->seekTo(-2000);
    QCOMPARE(m_core->positionMs(), qint64(0));

    m_core->seekTo(120000);
    QCOMPARE(m_core->positionMs(), qint64(90000));

    m_core->seekBy(-1000);
    QCOMPARE(m_core->positionMs(), qint64(89000));
    QCOMPARE(m_engine->lastSeek, qint64(89000));
}

void TestPlayerCore::seekAfterEndedStaysPaused()
{
    m_core->open(sampleRequest());
    m_engine->fileLoaded(10000, true, true);
    m_engine->endReached();

    m_core->seekTo(3000);

    QCOMPARE(m_core->state(), PlaybackState::Paused);
    QCOMPARE(m_engine->lastSeek, qint64(3000));
    QCOMPARE(m_core->positionMs(), qint64(3000));
}

void TestPlayerCore::speedIsClamped()
{
    m_core->setSpeed(0.1);
    QCOMPARE(m_core->speed(), 0.5);
    QCOMPARE(m_engine->lastSpeed, 0.5);

    m_core->setSpeed(10.0);
    QCOMPARE(m_core->speed(), 3.0);
    QCOMPARE(m_engine->lastSpeed, 3.0);
}

void TestPlayerCore::volumeIsClampedAndPersisted()
{
    m_core->setVolume(0.35);
    QCOMPARE(m_core->volume(), 0.35);
    QCOMPARE(m_engine->lastVolume, 0.35);

    m_core->setVolume(2.0);
    QCOMPARE(m_core->volume(), 1.0);

    m_core->setVolume(-1.0);
    QCOMPARE(m_core->volume(), 0.0);

    // §5.4：音量必须持久化，下次启动沿用
    QCOMPARE(AppSettings::instance().value(QStringLiteral("player.volume")).toDouble(), 0.0);

    m_core->adjustVolume(0.25);
    QCOMPARE(m_core->volume(), 0.25);
}

void TestPlayerCore::audioOnlyHidesVideo()
{
    m_core->open(sampleRequest());
    m_engine->fileLoaded(60000, true, true);
    QVERIFY(m_core->hasVideo());

    // PC-206：纯音频模式只关画面，不中断声音
    m_core->setAudioOnly(true);
    QVERIFY(m_core->audioOnly());
    QVERIFY(!m_core->hasVideo());
    QVERIFY(m_engine->lastAudioOnly);
    QCOMPARE(m_engine->pauseCount, 0);

    m_core->setAudioOnly(false);
    QVERIFY(m_core->hasVideo());
    QVERIFY(!m_engine->lastAudioOnly);
}

void TestPlayerCore::tracksAreForwarded()
{
    QList<PlaybackTrack> audio;
    audio.append(PlaybackTrack{1, QStringLiteral("国语"), QStringLiteral("chi"),
                               QStringLiteral("aac"), false, true});
    QList<PlaybackTrack> subtitle;
    subtitle.append(PlaybackTrack{2, QStringLiteral("简体"), QStringLiteral("zh"),
                                  QStringLiteral("ass"), false, false});

    m_engine->tracksChanged(audio, subtitle);

    QCOMPARE(m_core->audioTracks().size(), 1);
    QCOMPARE(m_core->audioTracks().at(0).title, QStringLiteral("国语"));
    QCOMPARE(m_core->subtitleTracks().size(), 1);

    m_core->selectAudioTrack(1);
    m_core->selectSubtitleTrack(2);
    QCOMPARE(m_engine->lastAudioTrack, 1);
    QCOMPARE(m_engine->lastSubtitleTrack, 2);

    const QUrl subtitleUrl = QUrl::fromLocalFile(QStringLiteral("C:/media/demo.ass"));
    m_core->addSubtitleFile(subtitleUrl);
    QCOMPARE(m_engine->lastSubtitleFile, subtitleUrl);

    // 关闭字幕用 -1
    m_core->selectSubtitleTrack(-1);
    QCOMPARE(m_engine->lastSubtitleTrack, -1);
}

void TestPlayerCore::errorSurfacesMessage()
{
    m_core->open(sampleRequest());
    m_engine->errorOccurred(QStringLiteral("解码失败"));

    QCOMPARE(m_core->state(), PlaybackState::Error);
    QCOMPARE(m_core->errorText(), QStringLiteral("解码失败"));
}

void TestPlayerCore::closeResetsToIdle()
{
    m_core->open(sampleRequest());
    m_engine->fileLoaded(8000, true, true);

    m_core->close();

    QCOMPARE(m_core->state(), PlaybackState::Idle);
    QCOMPARE(m_core->positionMs(), qint64(0));
    QCOMPARE(m_core->durationMs(), qint64(0));
    QVERIFY(m_core->title().isEmpty());
    QCOMPARE(m_engine->stopCount, 1);
}

QTEST_MAIN(TestPlayerCore)
#include "tst_playercore.moc"
