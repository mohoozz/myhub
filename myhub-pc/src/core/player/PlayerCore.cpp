#include "PlayerCore.h"

#include "core/preferences/AppSettings.h"
#include "core/utils/AppPaths.h"
#include "core/utils/ScreenshotPath.h"

#include <QDateTime>

namespace myhub {
namespace {

// 播放相关偏好键（§5.4，与 iOS UserDefaults 对齐）
constexpr auto kVolumeKey = "player.volume";
constexpr auto kAudioOnlyKey = "player.audioOnlyByDefault";

constexpr double kMinSpeed = 0.5;
constexpr double kMaxSpeed = 3.0;

} // namespace

PlayerCore &PlayerCore::instance()
{
    static PlayerCore core;
    return core;
}

PlayerCore::PlayerCore(QObject *parent)
    : QObject(parent)
{
    const auto &settings = AppSettings::instance();
    m_volume = qBound(0.0, settings.value(QString::fromLatin1(kVolumeKey), 1.0).toDouble(), 1.0);
    m_audioOnly = settings.value(QString::fromLatin1(kAudioOnlyKey), false).toBool();
}

PlayerCore::~PlayerCore() = default;

void PlayerCore::setEngine(PlaybackEngine *engine)
{
    if (m_engine == engine) {
        return;
    }
    if (m_engine) {
        disconnect(m_engine, nullptr, this, nullptr);
    }
    m_engine = engine;
    if (m_engine) {
        attachEngineSignals();
        m_engine->setVolume(m_volume);
        m_engine->setMuted(m_muted);
        m_engine->setSpeed(m_speed);
        m_engine->setAudioOnly(m_audioOnly);
    }
}

void PlayerCore::attachEngineSignals()
{
    connect(m_engine, &PlaybackEngine::fileLoaded, this, &PlayerCore::onFileLoaded);
    connect(m_engine, &PlaybackEngine::pausedChanged, this, &PlayerCore::onPausedChanged);
    connect(m_engine, &PlaybackEngine::endReached, this, &PlayerCore::onEndReached);
    connect(m_engine, &PlaybackEngine::errorOccurred, this, &PlayerCore::onError);
    connect(m_engine, &PlaybackEngine::mediaChanged, this, &PlayerCore::onMediaChanged);
    connect(m_engine, &PlaybackEngine::tracksChanged, this, &PlayerCore::onTracksChanged);
    connect(m_engine, &PlaybackEngine::bufferingChanged, this, &PlayerCore::setBuffering);
    connect(m_engine, &PlaybackEngine::positionChanged, this, &PlayerCore::setPosition);
    connect(m_engine, &PlaybackEngine::durationChanged, this, &PlayerCore::setDuration);
    connect(m_engine, &PlaybackEngine::screenshotSaved, this, &PlayerCore::screenshotSaved);
    connect(m_engine, &PlaybackEngine::screenshotFailed, this, &PlayerCore::screenshotFailed);
}

// ---------------------------------------------------------------- 控制

void PlayerCore::open(const PlaybackRequest &request)
{
    if (!request.isValid()) {
        setErrorText(tr("无效的播放地址"));
        setState(PlaybackState::Error);
        return;
    }

    // 切换文件时先把上一段会话的进度落盘（此时位置还没被覆盖）
    if (m_state != PlaybackState::Idle && !m_request.path.isEmpty()) {
        emit sessionEnding();
    }

    m_request = request;
    m_errorText.clear();
    m_buffering = false;
    m_positionMs = qMax<qint64>(0, request.startPositionMs);
    m_durationMs = 0;
    m_hasVideo = false;
    m_hasAudio = false;
    m_audioTracks.clear();
    m_subtitleTracks.clear();
    m_audioOnly = request.audioOnly;

    setTitle(request.title);
    emit positionChanged(m_positionMs);
    emit durationChanged(m_durationMs);
    emit audioTracksChanged(m_audioTracks);
    emit subtitleTracksChanged(m_subtitleTracks);
    emit audioOnlyChanged(m_audioOnly);
    emit errorTextChanged(m_errorText);
    emit mediaChanged(hasVideo());
    setState(PlaybackState::Loading);

    if (!m_engine) {
        setErrorText(tr("播放引擎未就绪"));
        setState(PlaybackState::Error);
        return;
    }

    // 每次起播都完整下发会话参数，避免上一个文件的状态泄漏
    m_engine->setVolume(m_volume);
    m_engine->setMuted(m_muted);
    m_engine->setSpeed(m_speed);
    m_engine->setAudioOnly(m_audioOnly);
    m_engine->load(m_request);
}

void PlayerCore::close()
{
    // 归零之前落盘，否则进度会被下面的 setPosition(0) 覆盖成 0
    if (m_state != PlaybackState::Idle && !m_request.path.isEmpty()) {
        emit sessionEnding();
    }
    if (m_engine) {
        m_engine->stop();
    }
    m_request = PlaybackRequest();
    m_buffering = false;
    m_durationMs = 0;
    m_hasVideo = false;
    m_hasAudio = false;
    m_audioTracks.clear();
    m_subtitleTracks.clear();

    setTitle(QString());
    setErrorText(QString());
    setPosition(0);
    setDuration(0);
    emit audioTracksChanged(m_audioTracks);
    emit subtitleTracksChanged(m_subtitleTracks);
    emit mediaChanged(false);
    setState(PlaybackState::Idle);
}

void PlayerCore::togglePause()
{
    if (m_state == PlaybackState::Ended) {
        replay();
        return;
    }
    if (!m_engine) {
        return;
    }
    if (m_state == PlaybackState::Playing) {
        m_engine->pause();
    } else if (m_state == PlaybackState::Paused || m_state == PlaybackState::Loading) {
        m_engine->play();
    }
}

void PlayerCore::replay()
{
    if (!m_engine || !m_request.isValid()) {
        return;
    }
    m_engine->seek(0);
    m_engine->play();
    setPosition(0);
    setState(PlaybackState::Playing);
}

void PlayerCore::seekTo(qint64 positionMs)
{
    if (!m_engine || m_state == PlaybackState::Idle || m_state == PlaybackState::Error) {
        return;
    }
    const qint64 target = m_durationMs > 0 ? qBound<qint64>(0, positionMs, m_durationMs)
                                           : qMax<qint64>(0, positionMs);
    m_engine->seek(target);
    setPosition(target);
    emit seeked(target);
    if (m_state == PlaybackState::Ended) {
        // 播完后回拖：停在目标帧（PC-201「播完可回拖重看」）
        m_engine->pause();
        setState(PlaybackState::Paused);
    }
}

void PlayerCore::seekBy(qint64 deltaMs)
{
    seekTo(m_positionMs + deltaMs);
}

void PlayerCore::setVolume(double volume)
{
    setVolumeInternal(volume, true);
}

void PlayerCore::adjustVolume(double delta)
{
    setVolumeInternal(m_volume + delta, true);
}

void PlayerCore::setVolumeInternal(double volume, bool persist)
{
    const double clamped = qBound(0.0, volume, 1.0);
    if (qFuzzyCompare(clamped, m_volume)) {
        return;
    }
    m_volume = clamped;
    if (m_engine) {
        m_engine->setVolume(m_volume);
    }
    if (persist) {
        AppSettings::instance().setValue(QString::fromLatin1(kVolumeKey), m_volume);
    }
    emit volumeChanged(m_volume);
}

void PlayerCore::setMuted(bool muted)
{
    if (m_muted == muted) {
        return;
    }
    m_muted = muted;
    if (m_engine) {
        m_engine->setMuted(muted);
    }
    emit mutedChanged(muted);
}

void PlayerCore::toggleMute()
{
    setMuted(!m_muted);
}

void PlayerCore::setSpeed(double speed)
{
    setSpeedInternal(speed);
}

void PlayerCore::setSpeedInternal(double speed)
{
    const double clamped = qBound(kMinSpeed, speed, kMaxSpeed);
    if (qFuzzyCompare(clamped, m_speed)) {
        return;
    }
    m_speed = clamped;
    if (m_engine) {
        m_engine->setSpeed(m_speed);
    }
    emit speedChanged(m_speed);
}

void PlayerCore::selectAudioTrack(int id)
{
    if (m_engine) {
        m_engine->selectAudioTrack(id);
    }
}

void PlayerCore::selectSubtitleTrack(int id)
{
    if (m_engine) {
        m_engine->selectSubtitleTrack(id);
    }
}

void PlayerCore::addSubtitleFile(const QUrl &url)
{
    if (m_engine && url.isValid()) {
        m_engine->addSubtitleFile(url);
    }
}

void PlayerCore::setSubtitleStyle(int fontSize, double delaySeconds)
{
    if (m_engine) {
        m_engine->setSubtitleStyle(fontSize, delaySeconds);
    }
}

void PlayerCore::setAudioOnly(bool audioOnly)
{
    if (m_audioOnly == audioOnly) {
        return;
    }
    m_audioOnly = audioOnly;
    applyAudioOnly();
    emit audioOnlyChanged(m_audioOnly);
    emit mediaChanged(hasVideo());
}

void PlayerCore::toggleAudioOnly()
{
    setAudioOnly(!m_audioOnly);
}

void PlayerCore::applyAudioOnly()
{
    if (m_engine) {
        m_engine->setAudioOnly(m_audioOnly);
    }
}

void PlayerCore::saveScreenshot()
{
    // 没有画面就没有「当前帧」：纯音频、未加载、加载中（还没有一帧解出来）都直接拒绝，
    // 不必让引擎去试错——mpv 那边要么报错要么截到纯黑，提示反而不清楚
    if (m_state == PlaybackState::Idle || !hasVideo()) {
        emit screenshotFailed(tr("当前没有可截取的画面"));
        return;
    }
    if (!m_engine) {
        emit screenshotFailed(tr("播放引擎未就绪"));
        return;
    }

    const QString directory = ScreenshotPath::defaultDirectory();
    if (!AppPaths::ensureDir(directory)) {
        emit screenshotFailed(tr("无法创建截图目录"));
        return;
    }

    m_engine->saveScreenshot(
        ScreenshotPath::build(directory, m_title, QDateTime::currentDateTime()));
}

// ---------------------------------------------------------------- 引擎上行

void PlayerCore::onFileLoaded(qint64 durationMs, bool hasVideoTrack, bool hasAudioTrack)
{
    m_buffering = false;
    emit bufferingChanged(false);
    setDuration(durationMs);
    setHasVideo(hasVideoTrack);
    m_hasAudio = hasAudioTrack;
    if (m_state == PlaybackState::Loading) {
        setState(m_pausedFact ? PlaybackState::Paused : PlaybackState::Playing);
    }
}

void PlayerCore::onPausedChanged(bool paused)
{
    m_pausedFact = paused;
    if (m_state == PlaybackState::Idle || m_state == PlaybackState::Error) {
        return;
    }
    if (m_state == PlaybackState::Loading) {
        return; // 起播瞬间的 pause 只记录事实，状态等 fileLoaded 再定
    }
    setState(paused ? PlaybackState::Paused : PlaybackState::Playing);
}

void PlayerCore::onEndReached()
{
    if (m_state == PlaybackState::Idle) {
        return;
    }
    if (m_durationMs > 0) {
        setPosition(m_durationMs);
    }
    setState(PlaybackState::Ended);
}

void PlayerCore::onError(const QString &message)
{
    setErrorText(message.isEmpty() ? tr("播放失败") : message);
    setState(PlaybackState::Error);
}

void PlayerCore::onMediaChanged(bool hasVideoTrack, bool hasAudioTrack)
{
    setHasVideo(hasVideoTrack);
    m_hasAudio = hasAudioTrack;
}

void PlayerCore::onTracksChanged(const QList<PlaybackTrack> &audio,
                                 const QList<PlaybackTrack> &subtitle)
{
    m_audioTracks = audio;
    m_subtitleTracks = subtitle;
    emit audioTracksChanged(m_audioTracks);
    emit subtitleTracksChanged(m_subtitleTracks);
}

// ---------------------------------------------------------------- 内部状态

void PlayerCore::setState(PlaybackState state)
{
    if (m_state == state) {
        return;
    }
    m_state = state;
    emit stateChanged(m_state);
}

void PlayerCore::setPosition(qint64 positionMs)
{
    const qint64 clamped = qMax<qint64>(0, positionMs);
    if (m_positionMs == clamped) {
        return;
    }
    m_positionMs = clamped;
    emit positionChanged(m_positionMs);
}

void PlayerCore::setDuration(qint64 durationMs)
{
    const qint64 clamped = qMax<qint64>(0, durationMs);
    if (m_durationMs == clamped) {
        return;
    }
    m_durationMs = clamped;
    emit durationChanged(m_durationMs);
}

void PlayerCore::setTitle(const QString &title)
{
    if (m_title == title) {
        return;
    }
    m_title = title;
    emit titleChanged(m_title);
}

void PlayerCore::setErrorText(const QString &errorText)
{
    if (m_errorText == errorText) {
        return;
    }
    m_errorText = errorText;
    emit errorTextChanged(m_errorText);
}

void PlayerCore::setBuffering(bool buffering)
{
    if (m_buffering == buffering) {
        return;
    }
    m_buffering = buffering;
    emit bufferingChanged(m_buffering);
}

void PlayerCore::setHasVideo(bool hasVideoTrack)
{
    if (m_hasVideo == hasVideoTrack) {
        return;
    }
    m_hasVideo = hasVideoTrack;
    emit mediaChanged(hasVideo());
}

} // namespace myhub
