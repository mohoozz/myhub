#pragma once

#include "PlaybackEngine.h"
#include "PlaybackTypes.h"

#include <QList>
#include <QObject>
#include <QString>

namespace myhub {

/**
 * 播放门面（《需求分析文档》§2.5 PC-201~PC-209、§4.3）。
 *
 * 位于 myhub_core、只依赖 QtCore，因此状态机与偏好逻辑可以用 QTest 全覆盖；
 * QML 侧经 app/PlayerBridge 暴露，解码器经 PlaybackEngine 注入（app 层 MpvEngine）。
 *
 * 状态由引擎上报的事实驱动（mpv 的 pause / eof-reached / endFile），
 * 门面只负责策略：播完重播、seek 钳制、倍速/音量边界、偏好持久化。
 */
class PlayerCore : public QObject
{
    Q_OBJECT
public:
    static PlayerCore &instance();

    explicit PlayerCore(QObject *parent = nullptr);
    ~PlayerCore() override;

    /// 注入引擎（不接管所有权）。nullptr 表示引擎尚未就绪，此时请求会被忽略。
    void setEngine(PlaybackEngine *engine);
    PlaybackEngine *engine() const { return m_engine; }

    // ---- 会话状态 ----
    PlaybackState state() const { return m_state; }
    qint64 positionMs() const { return m_positionMs; }
    qint64 durationMs() const { return m_durationMs; }
    QString title() const { return m_title; }
    QString errorText() const { return m_errorText; }
    bool buffering() const { return m_buffering; }
    bool hasVideo() const { return m_hasVideo && !m_audioOnly; }
    bool audioOnly() const { return m_audioOnly; }
    bool paused() const { return m_state == PlaybackState::Paused; }
    bool active() const { return m_state != PlaybackState::Idle; }

    /// 当前会话的请求（进度上报 / 「下一个」需要 connectionId + path）
    const PlaybackRequest &currentRequest() const { return m_request; }

    // ---- 音量 / 倍速 ----
    double volume() const { return m_volume; }
    bool muted() const { return m_muted; }
    double speed() const { return m_speed; }

    // ---- 轨道 ----
    QList<PlaybackTrack> audioTracks() const { return m_audioTracks; }
    QList<PlaybackTrack> subtitleTracks() const { return m_subtitleTracks; }

    // ---- 控制 ----
    void open(const PlaybackRequest &request);
    void close();
    void togglePause();
    void replay();

    void seekTo(qint64 positionMs);
    void seekBy(qint64 deltaMs);

    void setVolume(double volume);
    void adjustVolume(double delta);
    void setMuted(bool muted);
    void toggleMute();

    void setSpeed(double speed);

    void selectAudioTrack(int id);
    void selectSubtitleTrack(int id);
    void addSubtitleFile(const QUrl &url);
    /// 字幕字号 / 延迟即时生效（§4.3）
    void setSubtitleStyle(int fontSize, double delaySeconds);

    void setAudioOnly(bool audioOnly);
    void toggleAudioOnly();

    /**
     * 截取当前帧（§4.3，P2）。
     *
     * 门面只负责**策略**：没有会话、没有画面（纯音频 / 未加载）时直接拒绝并回
     * `screenshotFailed`，不惊动引擎；有画面时生成落盘路径交给引擎写文件。
     * 路径规则见 `core/utils/ScreenshotPath`（非法字符净化 + 同秒重名去重）。
     */
    void saveScreenshot();

signals:
    void stateChanged(myhub::PlaybackState state);
    void positionChanged(qint64 positionMs);
    /// 用户/程序主动定位完成（进度上报需立即落盘，不等 5s 节流）
    void seeked(qint64 positionMs);
    /**
     * 会话即将结束（切换文件 / close / 退出）。
     *
     * 在任何状态归零**之前**发出，让进度记录拿到最后的位置；
     * 接入方若在状态归零后再取，就只能读到 0。
     */
    void sessionEnding();
    void durationChanged(qint64 durationMs);
    void titleChanged(const QString &title);
    void errorTextChanged(const QString &errorText);
    void bufferingChanged(bool buffering);
    void mediaChanged(bool hasVideo);
    void audioTracksChanged(const QList<myhub::PlaybackTrack> &tracks);
    void subtitleTracksChanged(const QList<myhub::PlaybackTrack> &tracks);
    void volumeChanged(double volume);
    void mutedChanged(bool muted);
    void speedChanged(double speed);
    void audioOnlyChanged(bool audioOnly);
    /// 截图结果（§4.3）；失败原因已是用户可读文案，UI 直接展示
    void screenshotSaved(const QString &filePath);
    void screenshotFailed(const QString &reason);

private:
    void attachEngineSignals();
    void setState(PlaybackState state);
    void setPosition(qint64 positionMs);
    void setDuration(qint64 durationMs);
    void setTitle(const QString &title);
    void setErrorText(const QString &errorText);
    void setBuffering(bool buffering);
    void setHasVideo(bool hasVideo);
    void setVolumeInternal(double volume, bool persist);
    void setSpeedInternal(double speed);
    void applyAudioOnly();

    void onFileLoaded(qint64 durationMs, bool hasVideo, bool hasAudio);
    void onPausedChanged(bool paused);
    void onEndReached();
    void onError(const QString &message);
    void onMediaChanged(bool hasVideo, bool hasAudio);
    void onTracksChanged(const QList<PlaybackTrack> &audio, const QList<PlaybackTrack> &subtitle);

    PlaybackEngine *m_engine = nullptr;
    PlaybackRequest m_request;
    PlaybackState m_state = PlaybackState::Idle;
    qint64 m_positionMs = 0;
    qint64 m_durationMs = 0;
    QString m_title;
    QString m_errorText;
    bool m_buffering = false;
    bool m_pausedFact = false;
    bool m_hasVideo = false;
    bool m_hasAudio = false;
    bool m_audioOnly = false;
    double m_volume = 1.0;
    bool m_muted = false;
    double m_speed = 1.0;
    QList<PlaybackTrack> m_audioTracks;
    QList<PlaybackTrack> m_subtitleTracks;
};

} // namespace myhub
