#include "PlaybackProgressTracker.h"

#include "core/player/PlayerCore.h"
#include "core/utils/MediaType.h"

#include <QVariantMap>

namespace myhub {
namespace {

constexpr int kDefaultIntervalMs = 5000;

QString mediaTypeId(const QString &path)
{
    switch (MediaType::fromPath(path)) {
    case MediaType::Video:
        return QStringLiteral("video");
    case MediaType::Audio:
        return QStringLiteral("audio");
    case MediaType::Novel:
        return QStringLiteral("novel");
    case MediaType::Comic:
        return QStringLiteral("comic");
    default:
        return QString();
    }
}

} // namespace

PlaybackProgressTracker::PlaybackProgressTracker(PlayerCore *core, ProgressRepository *repository,
                                                 QObject *parent)
    : QObject(parent)
    , m_core(core)
    , m_repository(repository)
{
    m_heartbeat.setInterval(kDefaultIntervalMs);
    m_heartbeat.setTimerType(Qt::VeryCoarseTimer); // 5s 级的节流不需要精确定时
    connect(&m_heartbeat, &QTimer::timeout, this, [this]() {
        if (m_dirty) {
            flush();
        }
    });

    if (!m_core) {
        return;
    }
    connect(m_core, &PlayerCore::stateChanged, this, &PlaybackProgressTracker::onStateChanged);
    connect(m_core, &PlayerCore::positionChanged, this,
            &PlaybackProgressTracker::onPositionChanged);
    connect(m_core, &PlayerCore::seeked, this, &PlaybackProgressTracker::onSeeked);
    connect(m_core, &PlayerCore::sessionEnding, this, &PlaybackProgressTracker::onSessionEnding);
}

PlaybackProgressTracker::~PlaybackProgressTracker() = default;

void PlaybackProgressTracker::setIntervalMs(int ms)
{
    m_heartbeat.setInterval(qMax(10, ms));
}

void PlaybackProgressTracker::flush()
{
    if (!m_core || !m_repository) {
        return;
    }
    const PlaybackRequest &request = m_core->currentRequest();
    if (request.path.isEmpty() || request.connectionId.isEmpty()) {
        return;
    }

    const qint64 duration = m_core->durationMs();
    const bool ended = m_core->state() == PlaybackState::Ended;
    if (m_positionMs <= 0 && duration <= 0) {
        return; // 起播都没成功，不产生垃圾记录
    }

    m_repository->upsert(buildRecord(request, m_positionMs, duration, ended));
    m_dirty = false;
}

ProgressRecord PlaybackProgressTracker::buildRecord(const PlaybackRequest &request,
                                                    qint64 positionMs, qint64 durationMs,
                                                    bool ended)
{
    const qint64 position = qMax<qint64>(0, positionMs);
    const qint64 duration = qMax<qint64>(0, durationMs);

    ProgressRecord record;
    record.connectionId = request.connectionId;
    record.path = request.path;
    record.mediaType = mediaTypeId(request.path);
    record.title = request.title;
    record.finished = ended || ProgressRepository::isNearEnd(position, duration);
    record.percent = duration > 0 ? qBound(0.0, double(position) / double(duration), 1.0) : 0.0;

    QVariantMap progress;
    progress.insert(QStringLiteral("positionMs"), position);
    progress.insert(QStringLiteral("durationMs"), duration);
    record.progress = progress;
    return record;
}

void PlaybackProgressTracker::onStateChanged(PlaybackState state)
{
    switch (state) {
    case PlaybackState::Playing:
        m_heartbeat.start();
        return;
    case PlaybackState::Paused:
    case PlaybackState::Ended:
    case PlaybackState::Error:
        m_heartbeat.stop();
        flush();
        return;
    case PlaybackState::Idle:
        // close() 已通过 sessionEnding 落过盘；此处 position 已被清零，
        // 再写一次会把进度覆盖成 0，所以只停表不动库。
        m_heartbeat.stop();
        m_positionMs = 0;
        m_dirty = false;
        return;
    case PlaybackState::Loading:
        m_heartbeat.stop();
        return;
    }
}

void PlaybackProgressTracker::onPositionChanged(qint64 positionMs)
{
    m_positionMs = positionMs;
    m_dirty = true;
}

void PlaybackProgressTracker::onSeeked(qint64 positionMs)
{
    m_positionMs = positionMs;
    flush();
}

void PlaybackProgressTracker::onSessionEnding()
{
    m_heartbeat.stop();
    flush();
}

} // namespace myhub
