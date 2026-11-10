#include "MpvEngine.h"

#include "MpvVideoItem.h"

#include "core/preferences/AppSettings.h"

#include <MpvController>
#include <mpv/client.h>

#include <QDebug>
#include <QFileInfo>
#include <QUrl>
#include <QVariantList>
#include <QtGlobal>
#include <QtMath>

namespace myhub {
namespace {

constexpr qint64 kMsPerSecond = 1000;

qint64 secondsToMs(double seconds)
{
    if (!(seconds > 0.0)) {
        return 0;
    }
    return qRound64(seconds * kMsPerSecond);
}

} // namespace

MpvEngine::MpvEngine(QObject *parent)
    : PlaybackEngine(parent)
{}

MpvEngine::~MpvEngine() = default;

void MpvEngine::attachSurface(QObject *surface)
{
    if (m_item) {
        return;
    }

    m_item = qobject_cast<MpvVideoItem *>(surface);
    if (!m_item) {
        qWarning("MpvEngine: surface is not a MpvVideoItem, playback stays unavailable");
        return;
    }

    m_controller = m_item->controller();
    if (!m_controller) {
        qWarning("MpvEngine: mpv controller not created");
        m_item = nullptr;
        return;
    }

    connect(m_controller, &MpvController::propertyChanged, this, &MpvEngine::onPropertyChanged);
    connect(m_controller, &MpvController::fileLoaded, this, &MpvEngine::onFileLoaded);
    connect(m_controller, &MpvController::endFile, this, &MpvEngine::onEndFile);

    // 只订阅「事实」，不订阅可用命令推出来的状态
    const struct
    {
        const char *name;
        mpv_format format;
    } observed[] = {
        {"time-pos", MPV_FORMAT_DOUBLE},
        {"duration", MPV_FORMAT_DOUBLE},
        {"pause", MPV_FORMAT_FLAG},
        {"eof-reached", MPV_FORMAT_FLAG},
        {"paused-for-cache", MPV_FORMAT_FLAG},
        {"track-list/count", MPV_FORMAT_INT64},
        {"aid", MPV_FORMAT_INT64},
        {"sid", MPV_FORMAT_INT64},
        {"hwdec-current", MPV_FORMAT_STRING},
    };
    for (const auto &entry : observed) {
        m_item->observeProperty(QString::fromLatin1(entry.name), entry.format);
    }

    // MpvAbstractItem::ready 在渲染线程的 synchronize() 里发出，必须排队回 GUI 线程
    connect(m_item, &MpvAbstractItem::ready, this, &MpvEngine::onRendererReady,
            Qt::QueuedConnection);

    if (m_hasPendingRequest && m_voReady) {
        m_hasPendingRequest = false;
        startLoad();
    }
}

void MpvEngine::onRendererReady()
{
    m_voReady = true;
    if (m_hasPendingRequest) {
        m_hasPendingRequest = false;
        startLoad();
    }
}

// ---------------------------------------------------------------- 播放控制

void MpvEngine::load(const PlaybackRequest &request)
{
    m_request = request;
    m_positionMs = qMax<qint64>(0, request.startPositionMs);
    m_durationMs = 0;
    m_endEmitted = false;
    m_hwdecFallbackTried = false;
    m_softwareFallback = false; // 换片重新按容器/偏好判定，不继承上一部的救场结果
    m_buffering = false;
    m_videoTrackCount = 0;
    m_audioTracks.clear();
    m_subtitleTracks.clear();

    if (!ready() || !m_voReady) {
        // 渲染面还没出 VO 就 loadfile，mpv 会丢弃视频轨（只剩声音 / 黑屏）
        m_pendingRequest = request;
        m_hasPendingRequest = true;
        return;
    }
    startLoad();
}

void MpvEngine::startLoad()
{
    configureForLoad();
    m_controller->command(QStringList{QStringLiteral("loadfile"), m_request.url.toString(),
                                      QStringLiteral("replace")});
}

void MpvEngine::configureForLoad()
{
    refreshDecodeDecision();
    setMpv(QStringLiteral("hwdec"), m_decode.hwdec);
    setMpv(QStringLiteral("aid"), QStringLiteral("auto"));
    setMpv(QStringLiteral("sid"), QStringLiteral("auto"));
    setMpv(QStringLiteral("vid"), m_audioOnly ? QStringLiteral("no") : QStringLiteral("auto"));
    setMpv(QStringLiteral("pause"), false);
    setMpv(QStringLiteral("speed"), m_speed);
    setMpv(QStringLiteral("volume"), m_volume * 100.0);
    setMpv(QStringLiteral("mute"), m_muted);
    /*
      精准续播起点（PC-209）。必须在 loadfile 之前下发，mpv 直接从该点起播，
      不会出现「先 0 后跳」。

      两个坑（都实测过）：
      1. 必须传**字符串**。`start` 是时间型选项，用 MPV_FORMAT_NODE+double 下发会被
         拒绝（-11 PROPERTY_ERROR），表现为静默从 0 起播；
      2. 不能用 `loadfile <url> replace start=60` 的文件局部选项形式 —— 这个 libmpv
         构建对该写法直接返回 -4 INVALID_PARAMETER，文件根本不会加载。
      每次起播都会重设，因此不会残留到下一部片。
    */
    const qint64 startMs = qMax<qint64>(0, m_request.startPositionMs);
    setMpv(QStringLiteral("start"), QString::number(static_cast<double>(startMs) / 1000.0, 'f', 3));

    // 字幕与预读偏好（§5.4 player.*），每次起播下发；运行期改动走 setSubtitleStyle()
    const auto &settings = AppSettings::instance();
    setSubtitleStyle(settings.value(QStringLiteral("player.subtitleFontSize"), 16).toInt(),
                     settings.value(QStringLiteral("player.subtitleDelay"), 0.0).toDouble());
    // 前向缓冲（§4.2 抗抖动）：三个量同源换算自 preloadSeconds
    //  - cache-secs：网络流缓存保留时长
    //  - demuxer-readahead-secs：demuxer 预读秒数（不足时 mpv 会以 cache-secs 兜底）
    //  - demuxer-max-bytes：按 4MB/s 粗估上限，夹在 32~512MiB，避免超高码率把内存吃满
    const int preloadSeconds =
        qBound(5, settings.value(QStringLiteral("player.preloadSeconds"), 30).toInt(), 300);
    setMpv(QStringLiteral("cache-secs"), preloadSeconds);
    setMpv(QStringLiteral("demuxer-readahead-secs"), preloadSeconds);
    const int readaheadMiB = qBound(32, preloadSeconds * 4, 512);
    setMpv(QStringLiteral("demuxer-max-bytes"), QStringLiteral("%1MiB").arg(readaheadMiB));

    /*
      截图（§4.3）：格式固定 PNG，与 ScreenshotPath 拼出的扩展名一致；
      screenshot-sw 强制走软渲染路径 —— libmpv 渲染 API 下硬解帧不在 mpv 可读位置，
      打开它由 mpv 自己把帧取回来再编码，否则截出来是黑的或直接失败。
    */
    setMpv(QStringLiteral("screenshot-format"), QStringLiteral("png"));
    setMpv(QStringLiteral("screenshot-sw"), true);
}

void MpvEngine::play()
{
    setMpv(QStringLiteral("pause"), false);
}

void MpvEngine::pause()
{
    setMpv(QStringLiteral("pause"), true);
}

void MpvEngine::stop()
{
    if (!ready()) {
        return;
    }
    m_controller->command(QStringList{QStringLiteral("stop")});
    m_positionMs = 0;
    m_durationMs = 0;
    m_endEmitted = false;
    m_videoTrackCount = 0;
    m_audioTracks.clear();
    m_subtitleTracks.clear();
    emit tracksChanged(m_audioTracks, m_subtitleTracks);
}

void MpvEngine::seek(qint64 positionMs)
{
    if (!ready()) {
        return;
    }
    m_positionMs = qMax<qint64>(0, positionMs);
    m_controller->command(QStringList{QStringLiteral("seek"),
                                      QString::number(m_positionMs / 1000.0, 'f', 3),
                                      QStringLiteral("absolute"), QStringLiteral("exact")});
    m_endEmitted = false;
}

void MpvEngine::setVolume(double volume)
{
    m_volume = qBound(0.0, volume, 1.0);
    setMpv(QStringLiteral("volume"), m_volume * 100.0);
}

void MpvEngine::setMuted(bool muted)
{
    m_muted = muted;
    setMpv(QStringLiteral("mute"), m_muted);
}

void MpvEngine::setSpeed(double speed)
{
    m_speed = qBound(0.5, speed, 3.0);
    setMpv(QStringLiteral("speed"), m_speed);
}

void MpvEngine::selectAudioTrack(int id)
{
    setMpv(QStringLiteral("aid"), id);
}

void MpvEngine::selectSubtitleTrack(int id)
{
    setMpv(QStringLiteral("sid"), id >= 0 ? QVariant(id) : QVariant(QStringLiteral("no")));
}

void MpvEngine::addSubtitleFile(const QUrl &url)
{
    if (!ready() || !url.isValid()) {
        return;
    }
    m_controller->command(
        QStringList{QStringLiteral("sub-add"), url.toString(), QStringLiteral("select")});
}

void MpvEngine::setSubtitleStyle(int fontSize, double delaySeconds)
{
    // 字号夹在 8~64pt：设置页滑杆范围与之一致，过小的值 mpv 会渲染成看不清的一行
    setMpv(QStringLiteral("sub-font-size"), qBound(8, fontSize, 64));
    // 延迟夹在 ±30s：再大的偏移多半是用户误触，放开只会让字幕永远不出现
    setMpv(QStringLiteral("sub-delay"), qBound(-30.0, delaySeconds, 30.0));
}

void MpvEngine::setAudioOnly(bool audioOnly)
{
    m_audioOnly = audioOnly;
    setMpv(QStringLiteral("vid"), audioOnly ? QStringLiteral("no") : QStringLiteral("auto"));
}

void MpvEngine::setDecodePreference(const QString &mode)
{
    m_decodePreference = mode;
    m_hwdecFallbackTried = false;
    m_softwareFallback = false;
    refreshDecodeDecision();
    setMpv(QStringLiteral("hwdec"), m_decode.hwdec);
}

void MpvEngine::saveScreenshot(const QString &filePath)
{
    if (!ready()) {
        emit screenshotFailed(tr("播放引擎未就绪"));
        return;
    }
    // 纯音频模式 mpv 里没有视频轨（vid=no），截图命令只会报错，提前给出明确提示
    if (m_audioOnly || m_videoTrackCount == 0) {
        emit screenshotFailed(tr("当前没有可截取的画面"));
        return;
    }

    /*
      同步下发：mpv 的 screenshot-to-file 在命令返回前就把文件写完，
      这样我们能靠「文件是否存在」确认成功，不必等异步 reply。
      实测这一步在 1080p 上是毫秒级（软解路径由 screenshot-sw 兜底），
      对播放体验无影响。
    */
    const QVariant reply = m_controller->command(
        QStringList{QStringLiteral("screenshot-to-file"), filePath, QStringLiteral("subtitles")});

    const auto error = reply.value<ErrorReturn>();
    if (error.error < 0) {
        emit screenshotFailed(tr("截图失败：%1").arg(MpvController::getError(error.error)));
        return;
    }
    // 命令成功但文件没落盘（路径不可写 / 磁盘满）：不能对用户报「已保存」
    if (!QFileInfo::exists(filePath)) {
        emit screenshotFailed(tr("截图未能写入文件"));
        return;
    }
    emit screenshotSaved(filePath);
}

void MpvEngine::reloadWithSoftwareDecoding()
{
    // 自动回退：保留进度、本次会话改判软解。
    // 注意**不改 m_decodePreference**——用户偏好设置不该被运行期救场覆盖。
    m_hwdecFallbackTried = true;
    m_softwareFallback = true;
    m_request.startPositionMs = m_positionMs;
    qInfo("MpvEngine: retrying with software decoding (reason=%s)", qPrintable(m_decode.reason));
    if (!ready()) {
        m_pendingRequest = m_request;
        m_hasPendingRequest = true;
        return;
    }
    startLoad();
}

void MpvEngine::refreshDecodeDecision()
{
    if (m_softwareFallback) {
        m_decode = DecodeDecision{QStringLiteral("no"), true, QStringLiteral("fallback:software")};
        return;
    }
    // 探测优先用源路径（保留原始扩展名），回环代理 URL 拿不到扩展名时退回 url
    const QString source = m_request.path.isEmpty() ? m_request.url.toString() : m_request.path;
    m_decode = DecodeRouter::decide(m_decodePreference, source);
}

bool MpvEngine::canFallbackToSoftware() const
{
    // 已经是软解、或用户明确「强制硬解/强制软解」时不再自动改判：
    // 强制语义就是把选择权交给用户，失败要给出可操作提示而不是偷偷换档。
    return !m_softwareFallback && !m_decode.forced && m_decode.hwdec != QStringLiteral("no");
}

void MpvEngine::setMpv(const QString &name, const QVariant &value)
{
    if (ready()) {
        m_controller->setProperty(name, value);
    }
}

// ---------------------------------------------------------------- mpv 上行

void MpvEngine::onPropertyChanged(const QString &name, const QVariant &value)
{
    if (name == QStringLiteral("time-pos")) {
        const qint64 ms = secondsToMs(value.toDouble());
        if (ms != m_positionMs) {
            m_positionMs = ms;
            emit positionChanged(ms);
        }
        return;
    }
    if (name == QStringLiteral("duration")) {
        const qint64 ms = secondsToMs(value.toDouble());
        if (ms != m_durationMs) {
            m_durationMs = ms;
            emit durationChanged(ms);
        }
        return;
    }
    if (name == QStringLiteral("pause")) {
        emit pausedChanged(value.toBool());
        return;
    }
    if (name == QStringLiteral("eof-reached")) {
        if (value.toBool() && !m_endEmitted) {
            m_endEmitted = true;
            emit endReached();
        }
        return;
    }
    if (name == QStringLiteral("paused-for-cache")) {
        const bool buffering = value.toBool();
        if (buffering != m_buffering) {
            m_buffering = buffering;
            emit bufferingChanged(buffering);
        }
        return;
    }
    if (name == QStringLiteral("track-list/count") || name == QStringLiteral("aid")
        || name == QStringLiteral("sid")) {
        publishTracks();
        return;
    }
}

void MpvEngine::onFileLoaded()
{
    m_endEmitted = false;
    const qint64 ms = secondsToMs(m_controller->getProperty(QStringLiteral("duration")).toDouble());
    if (ms > 0 && ms != m_durationMs) {
        m_durationMs = ms;
        emit durationChanged(ms);
    }
    publishTracks();

    // 「有视频轨但无音频轨」通常意味着音频编码不受支持（DTS / TrueHD / E-AC-3 等），
    // 硬解链路上尤其容易只剩画面：先回退软解重试一次，重试后不再触发（避免循环）
    if (!m_audioOnly && m_videoTrackCount > 0 && m_audioTracks.isEmpty() && !m_hwdecFallbackTried
        && canFallbackToSoftware()) {
        qInfo("MpvEngine: video track without audio track, retrying with software decoding");
        reloadWithSoftwareDecoding();
        return;
    }
    if (!m_audioOnly && m_videoTrackCount > 0 && m_audioTracks.isEmpty() && m_decode.forced
        && m_decode.hwdec != QStringLiteral("no")) {
        // 用户强制硬解时不做改判，但必须把原因说清楚，否则只能看到「有画面没声音」
        qWarning("MpvEngine: no audio track under forced hardware decoding (container=%s)",
                 qPrintable(m_decode.reason));
    }

    emit fileLoaded(m_durationMs, m_videoTrackCount > 0, !m_audioTracks.isEmpty());
}

void MpvEngine::onEndFile(const QString &reason)
{
    if (reason == QStringLiteral("error")) {
        if (!m_hwdecFallbackTried && canFallbackToSoftware()) {
            reloadWithSoftwareDecoding();
            return;
        }
        if (m_decode.forced && m_decode.hwdec != QStringLiteral("no")) {
            emit errorOccurred(
                tr("硬解失败（已按设置强制硬解），可在 设置 → 播放器 改为「自动」后重试"));
            return;
        }
        emit errorOccurred(tr("无法解码该文件，可能已损坏或格式不受支持"));
        return;
    }
    if (reason == QStringLiteral("eof") && !m_endEmitted) {
        m_endEmitted = true;
        emit endReached();
    }
}

void MpvEngine::publishTracks()
{
    if (!ready()) {
        return;
    }

    const int count = m_controller->getProperty(QStringLiteral("track-list/count")).toInt();
    int videoCount = 0;
    QList<PlaybackTrack> audio;
    QList<PlaybackTrack> subtitle;

    for (int i = 0; i < count; ++i) {
        const QString prefix = QStringLiteral("track-list/%1/").arg(i);
        const QString type = m_controller->getProperty(prefix + QStringLiteral("type")).toString();
        if (type == QStringLiteral("video")) {
            ++videoCount;
            continue;
        }
        if (type != QStringLiteral("audio") && type != QStringLiteral("sub")) {
            continue;
        }

        PlaybackTrack track;
        track.id = m_controller->getProperty(prefix + QStringLiteral("id")).toInt();
        track.title = m_controller->getProperty(prefix + QStringLiteral("title")).toString();
        track.lang = m_controller->getProperty(prefix + QStringLiteral("lang")).toString();
        track.codec = m_controller->getProperty(prefix + QStringLiteral("codec")).toString();
        track.external = m_controller->getProperty(prefix + QStringLiteral("external")).toBool();
        track.selected = m_controller->getProperty(prefix + QStringLiteral("selected")).toBool();

        if (type == QStringLiteral("audio")) {
            audio.append(track);
        } else {
            subtitle.append(track);
        }
    }

    const bool mediaDirty =
        (videoCount != m_videoTrackCount) || (audio.isEmpty() != m_audioTracks.isEmpty());
    m_videoTrackCount = videoCount;
    m_audioTracks = audio;
    m_subtitleTracks = subtitle;

    emit tracksChanged(m_audioTracks, m_subtitleTracks);
    if (mediaDirty) {
        emit mediaChanged(m_videoTrackCount > 0, !m_audioTracks.isEmpty());
    }
}

} // namespace myhub
