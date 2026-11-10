#include "MediaSession.h"

#include "core/player/PlayerCore.h"
#include "core/preferences/AppSettings.h"
#include "core/utils/AppLogger.h"
#include "core/utils/TrackName.h"
#include "features/cover/CoverService.h"

#include <QtGlobal>

#include <utility>

namespace myhub {
namespace {

/// 时间轴上报间隔：系统面板每次更新时间轴都会重绘，1s 一次足够
constexpr qint64 kTimelineIntervalMs = 1000;
/// 快进/快退步长的安全范围（与设置页滑杆一致）
constexpr int kMinSeekStepSeconds = 5;
constexpr int kMaxSeekStepSeconds = 120;

} // namespace

MediaSession &MediaSession::instance()
{
    static MediaSession session;
    return session;
}

MediaSession::MediaSession(QObject *parent)
    : QObject(parent)
{
    auto &core = PlayerCore::instance();
    connect(&core, &PlayerCore::stateChanged, this, [this](PlaybackState) { push(false); });
    connect(&core, &PlayerCore::titleChanged, this, [this](const QString &) { push(false); });
    connect(&core, &PlayerCore::mediaChanged, this, [this](bool) { push(false); });
    connect(&core, &PlayerCore::speedChanged, this, [this](double) { push(false); });
    connect(&core, &PlayerCore::seeked, this, [this](qint64) { push(false); });
    connect(&core, &PlayerCore::durationChanged, this, [this](qint64) { push(true); });
    connect(&core, &PlayerCore::positionChanged, this, [this](qint64) { push(true); });

    // 封面是异步产物：到达后补推一次，面板才不会一直空着
    connect(&CoverService::instance(), &CoverService::coverReady, this,
            [this](const QString &key, const QString &) {
                if (key.isEmpty() || key != m_coverRequestedFor) {
                    return;
                }
                push(false);
            });
}

MediaSession::~MediaSession()
{
    detach();
}

void MediaSession::attachWindow(QWindow *window)
{
    if (m_controls || !window) {
        return;
    }

    m_controls = createMediaControls();
    if (!m_controls) {
        MH_INFO(Player, QStringLiteral("当前平台没有系统媒体控制后端，媒体面板不可用"));
        return;
    }

    wireCallbacks();
    if (!m_controls->attach(window)) {
        m_controls.reset();
        return;
    }

    push(false);
}

void MediaSession::detach()
{
    if (!m_controls) {
        return;
    }

    m_controls->detach();
    m_controls.reset();
    m_pushed = false;
    m_timelineClock.invalidate();
}

void MediaSession::wireCallbacks()
{
    MediaControlsCallbacks callbacks;

    callbacks.play = [] {
        auto &core = PlayerCore::instance();
        if (core.state() == PlaybackState::Paused) {
            core.togglePause();
        } else if (core.state() == PlaybackState::Ended) {
            core.replay();
        }
    };
    callbacks.pause = [] {
        auto &core = PlayerCore::instance();
        if (core.state() == PlaybackState::Playing) {
            core.togglePause();
        }
    };
    callbacks.togglePlayPause = [] {
        auto &core = PlayerCore::instance();
        switch (core.state()) {
        case PlaybackState::Playing:
        case PlaybackState::Paused:
            core.togglePause();
            break;
        case PlaybackState::Ended:
            core.replay();
            break;
        default:
            break;
        }
    };
    callbacks.stop = [] {
        PlayerCore::instance().close();
    };
    callbacks.seekTo = [](qint64 positionMs) {
        PlayerCore::instance().seekTo(positionMs);
    };
    callbacks.fastForward = [this] {
        PlayerCore::instance().seekBy(seekStepMs());
    };
    callbacks.rewind = [this] {
        PlayerCore::instance().seekBy(-seekStepMs());
    };
    callbacks.setSpeed = [](double rate) {
        PlayerCore::instance().setSpeed(rate);
    };
    // 上/下一个映射的是 §4.6 的「推荐上/下一个」，该功能落地后再接；
    // 现在后端对应的按钮是禁用的，这里留空即可。

    m_controls->setCallbacks(std::move(callbacks));
}

int MediaSession::seekStepMs() const
{
    const int seconds =
        AppSettings::instance().value(QStringLiteral("player.seekStepSeconds"), 10).toInt();
    return qBound(kMinSeekStepSeconds, seconds, kMaxSeekStepSeconds) * 1000;
}

void MediaSession::push(bool timelineOnly)
{
    if (!m_controls) {
        return;
    }

    // 位置每 250ms 就来一次，全推会把系统面板刷成幻灯；状态变化不走节流
    if (timelineOnly && m_timelineClock.isValid()
        && m_timelineClock.elapsed() < kTimelineIntervalMs) {
        return;
    }

    const MediaSnapshot snapshot = buildSnapshot();
    if (snapshot.active) {
        m_timelineClock.restart();
    }
    if (m_pushed && snapshot == m_last) {
        return;
    }

    m_last = snapshot;
    m_pushed = true;
    m_controls->apply(snapshot);
}

MediaSnapshot MediaSession::buildSnapshot()
{
    auto &core = PlayerCore::instance();
    MediaSnapshot snapshot;

    const PlaybackRequest request = core.currentRequest();
    if (core.state() == PlaybackState::Idle || request.path.isEmpty()) {
        m_coverRequestedFor.clear();
        return snapshot;
    }

    // 作者/标题的解析与 mini 条、全屏封面共用 TrackName，三处显示必须一致
    const TrackName::Parts parts = TrackName::parse(request.title);
    snapshot.active = true;
    snapshot.title = parts.title.isEmpty() ? core.title() : parts.title;
    snapshot.artist = parts.artist;
    snapshot.video = core.hasVideo();
    snapshot.playing = core.state() == PlaybackState::Playing;
    snapshot.positionMs = core.positionMs();
    snapshot.durationMs = core.durationMs();
    snapshot.speed = core.speed();
    snapshot.coverUrl = coverUrlFor(request.connectionId, request.path);
    return snapshot;
}

QUrl MediaSession::coverUrlFor(const QString &connectionId, const QString &path)
{
    auto &covers = CoverService::instance();
    const QString key = covers.coverKey(connectionId, path);

    const QString cached = covers.cachedCover(connectionId, path);
    if (!cached.isEmpty()) {
        m_coverRequestedFor = key;
        return QUrl(cached);
    }

    if (m_coverRequestedFor != key) {
        // 首次播放：请求一次，coverReady 回来再补推。同一份请求会被 CoverService 去重，
        // 与 mini 条 / 全屏封面的请求共用同一条在途任务，不会多打一次网络。
        m_coverRequestedFor = key;
        covers.requestCover(connectionId, path);
    }
    return {};
}

} // namespace myhub
