#pragma once

#include "core/player/DecodeRouter.h"
#include "core/player/PlaybackEngine.h"

#include <MpvController>

#include <QList>
#include <QObject>
#include <QString>

namespace myhub {

class MpvVideoItem;

/**
 * libmpv 引擎实现（《需求分析文档》§4.3：唯一解码后端，GPL 隔离在独立进程边界之外）。
 *
 * 职责：把 mpv 的**事实**翻译成 PlaybackEngine 信号，不做状态推断：
 *  - pause / eof-reached / endFile / track-list 属性变化
 *  - 精准续播：加载前设置 `start` 选项，避免「先从 0 起播再 seek」（PC-209）
 *  - 硬解失败自动回退软解（§4.3 双引擎策略）：
 *    endFile("error") 且当前不是软解 → 保留进度，改 hwdec=no 重载一次
 */
class MpvEngine : public PlaybackEngine
{
    Q_OBJECT
public:
    explicit MpvEngine(QObject *parent = nullptr);
    ~MpvEngine() override;

    void attachSurface(QObject *surface) override;

    void load(const PlaybackRequest &request) override;
    void play() override;
    void pause() override;
    void stop() override;
    void seek(qint64 positionMs) override;

    void setVolume(double volume) override;
    void setMuted(bool muted) override;
    void setSpeed(double speed) override;

    void selectAudioTrack(int id) override;
    void selectSubtitleTrack(int id) override;
    void addSubtitleFile(const QUrl &url) override;
    void setSubtitleStyle(int fontSize, double delaySeconds) override;

    void setAudioOnly(bool audioOnly) override;
    void setDecodePreference(const QString &mode) override;

    /**
     * 截取当前帧（§4.3）：mpv `screenshot-to-file <path> subtitles`。
     *
     * 选 `subtitles` 模式而不是 `window`：`window` 要读窗口像素，在 libmpv 渲染 API
     * （本项目唯一渲染路径）下不可用；`subtitles` 从解码帧出发、带字幕不带 OSD，
     * 与「我想要这一帧画面」的预期一致，分辨率也是片源原生分辨率。
     */
    void saveScreenshot(const QString &filePath) override;

private:
    bool ready() const { return m_controller != nullptr; }

    /// 渲染面（libmpv VO）是否已经可用。
    /// 只有 mpv 的 render context 建好之后再 loadfile，视频轨才会被真正解出来；
    /// 早于此时机加载，mpv 会因为没有 VO 直接丢弃视频轨（表现为黑屏但有声音）。
    bool videoOutputReady() const { return m_voReady; }
    void onRendererReady();

    void startLoad();
    void configureForLoad();
    void onPropertyChanged(const QString &name, const QVariant &value);
    void onFileLoaded();
    void onEndFile(const QString &reason);
    void publishTracks();
    void reloadWithSoftwareDecoding();

    void setMpv(const QString &name, const QVariant &value);

    /// 每次起播/改偏好时重算硬解决策（偏好强制 > 容器 > 默认硬解优先）
    void refreshDecodeDecision();
    /// 是否允许运行期自动改判软解（强制偏好下不允许）
    bool canFallbackToSoftware() const;

    MpvVideoItem *m_item = nullptr;
    MpvController *m_controller = nullptr;
    /// mpv render context 已就绪（MpvAbstractItem::ready 已触发过一次）
    bool m_voReady = false;

    PlaybackRequest m_request;
    PlaybackRequest m_pendingRequest;
    bool m_hasPendingRequest = false;

    qint64 m_positionMs = 0;
    qint64 m_durationMs = 0;
    double m_volume = 1.0;
    bool m_muted = false;
    double m_speed = 1.0;
    bool m_audioOnly = false;
    QString m_decodePreference = QStringLiteral("auto");

    /// 本次会话已改判软解（不回写偏好，仅影响当前播放）
    bool m_softwareFallback = false;
    /// 当前这次起播的解码决策（起播前由 DecodeRouter 算出）
    DecodeDecision m_decode;

    bool m_hwdecFallbackTried = false;
    bool m_endEmitted = false;
    bool m_buffering = false;

    int m_videoTrackCount = 0;
    QList<PlaybackTrack> m_audioTracks;
    QList<PlaybackTrack> m_subtitleTracks;
};

} // namespace myhub
