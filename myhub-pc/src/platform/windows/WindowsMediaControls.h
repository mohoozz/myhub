#pragma once

#include "platform/media/MediaControls.h"

#include <QObject>

#include <memory>

namespace myhub {

/**
 * Windows 系统媒体控制（PC-602）：SMTC（`SystemMediaTransportControls`）。
 *
 * 绑定窗口后，Windows 的媒体弹出面板（音量键唤起的那个）与硬件媒体键
 * 都归本进程：标题 / 作者 / 封面 / 时长 / 进度 / 播放态，播放暂停、
 * 快进快退（按设置里的 seek 步长）、拖动定位、改速率。
 *
 * 实现说明：
 *   - 使用 C++/WinRT，`GetForWindow` 走 `ISystemMediaTransportControlsInterop`
 *   - SMTC 的事件回调可能在后台线程触发，统一 `invokeMethod` 回 GUI 线程
 *   - 上/下一个按钮在 §4.6「连续播放推荐」落地前保持禁用（没有推荐目标）
 */
class WindowsMediaControls : public QObject, public MediaControls
{
    Q_OBJECT
public:
    explicit WindowsMediaControls(QObject *parent = nullptr);
    ~WindowsMediaControls() override;

    void setCallbacks(MediaControlsCallbacks callbacks) override;
    bool attach(QWindow *window) override;
    void apply(const MediaSnapshot &snapshot) override;
    void detach() override;

private:
    /// 真正推快照的实现；外层 `apply` 只负责兜住 WinRT 异常
    void applySnapshot(const MediaSnapshot &snapshot);
    /// SMTC 按钮枚举（存成 int，避免 winrt 头文件向上层泄漏）
    void handleButton(int button);
    void handlePositionRequest(qint64 positionMs);
    void handleRateRequest(double rate);

    struct Impl;
    std::unique_ptr<Impl> m_impl;
    MediaControlsCallbacks m_callbacks;
};

} // namespace myhub
