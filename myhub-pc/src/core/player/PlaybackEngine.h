#pragma once

#include "PlaybackTypes.h"

#include <QObject>

namespace myhub {

/**
 * 解码引擎抽象（《需求分析文档》§4.3：PlayerCore → PlaybackEngine 接口 → libmpv）。
 *
 * 之所以把它做成接口而不是直接写 mpv：
 *  1. 单测可以注入 FakeEngine，状态机不必依赖真实解码器与音视频设备；
 *  2. 将来若出现平台限制（例如某些格式需要额外后端），门面与 UI 不必改动。
 *
 * 约定：引擎只上报**事实**（pause 属性、播完、失败、轨道列表），
 * 状态机由 PlayerCore 统一维护，避免两处各自推断状态而打架。
 */
class PlaybackEngine : public QObject
{
    Q_OBJECT
public:
    explicit PlaybackEngine(QObject *parent = nullptr)
        : QObject(parent)
    {}

    ~PlaybackEngine() override = default;

    /// 绑定渲染面（QQuickItem）。视频类引擎必须实现；纯音频引擎可忽略。
    virtual void attachSurface(QObject *surface) { Q_UNUSED(surface) }

    virtual void load(const PlaybackRequest &request) = 0;
    virtual void play() = 0;
    virtual void pause() = 0;
    virtual void stop() = 0;
    virtual void seek(qint64 positionMs) = 0;

    virtual void setVolume(double volume) = 0; // 0.0 ~ 1.0
    virtual void setMuted(bool muted) = 0;
    virtual void setSpeed(double speed) = 0; // 0.5 ~ 3.0（PC-201）

    virtual void selectAudioTrack(int id) = 0;
    virtual void selectSubtitleTrack(int id) = 0; // -1 = 关闭字幕
    virtual void addSubtitleFile(const QUrl &url) = 0;

    /**
     * 字幕样式即时调整（§4.3）：字号（pt）与延迟（秒，正 = 字幕整体延后）。
     * 默认空实现，纯音频后端的 FakeEngine 不必关心；真引擎在会话进行中也要立即生效，
     * 不能只在 configureForLoad() 里读设置。
     */
    virtual void setSubtitleStyle(int fontSize, double delaySeconds)
    {
        Q_UNUSED(fontSize)
        Q_UNUSED(delaySeconds)
    }

    virtual void setAudioOnly(bool audioOnly) = 0;
    virtual void setDecodePreference(const QString &mode) = 0; // auto / hardware / software

    /**
     * 截取当前帧到 `filePath`（§4.3，PNG，带字幕不带界面）。
     *
     * 默认实现直接回 `screenshotFailed`：截图依赖「有渲染面 + 有视频轨」，
     * 纯音频引擎与单测里的 FakeEngine 都不该被迫实现它，
     * 但**必须给出回复**——否则上层按钮点下去永远没有结果反馈。
     * 结果通过 `screenshotSaved` / `screenshotFailed` 回到门面。
     */
    virtual void saveScreenshot(const QString &filePath)
    {
        Q_UNUSED(filePath)
        emit screenshotFailed(tr("当前解码引擎不支持截图"));
    }

signals:
    /// 文件已加载：时长与音视频轨存在性是起播后才知道的
    void fileLoaded(qint64 durationMs, bool hasVideo, bool hasAudio);
    void pausedChanged(bool paused);
    void positionChanged(qint64 positionMs);
    void durationChanged(qint64 durationMs);
    void mediaChanged(bool hasVideo, bool hasAudio);
    void tracksChanged(const QList<myhub::PlaybackTrack> &audio,
                       const QList<myhub::PlaybackTrack> &subtitle);
    void bufferingChanged(bool buffering);
    void endReached();
    void errorOccurred(const QString &message);
    /// 截图已落盘（`filePath` 为完整路径，供 UI 提示与「打开所在目录」用）
    void screenshotSaved(const QString &filePath);
    /// 截图失败（无视频轨 / 暂停在 0 帧之前 / 写盘失败），`reason` 直接给用户看
    void screenshotFailed(const QString &reason);
};

} // namespace myhub
