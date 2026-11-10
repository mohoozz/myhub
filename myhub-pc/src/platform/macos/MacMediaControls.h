#pragma once

#include "platform/media/MediaControls.h"

#include <QObject>

#include <memory>

namespace myhub {

/**
 * macOS 系统媒体控制（PC-602）：`MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`。
 *
 * 与控制中心 / 键盘媒体键 / 耳机线控共用同一套命令通道：
 * 标题、作者、封面、时长、进度、播放态、播放速率；播放暂停、上/下一个、
 * 快进快退、拖动定位、改速率。
 *
 * 注意：本文件依赖 MediaPlayer / AppKit 框架，只在 APPLE 分支编译。
 */
class MacMediaControls : public QObject, public MediaControls
{
    Q_OBJECT
public:
    explicit MacMediaControls(QObject *parent = nullptr);
    ~MacMediaControls() override;

    void setCallbacks(MediaControlsCallbacks callbacks) override;
    bool attach(QWindow *window) override;
    void apply(const MediaSnapshot &snapshot) override;
    void detach() override;

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
    MediaControlsCallbacks m_callbacks;
};

} // namespace myhub
