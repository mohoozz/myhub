#pragma once

#include "platform/media/MediaControls.h"

#include <QElapsedTimer>
#include <QObject>
#include <QString>
#include <QUrl>

#include <memory>

class QWindow;

namespace myhub {

/**
 * 系统媒体会话（PC-602）的应用层聚合。
 *
 * 职责只有一个：把 `PlayerCore` 的事实翻译成平台面板要的一份快照，并把面板/媒体键
 * 的操作翻译回 `PlayerCore` 的调用。**它不认识 mpv，也不认识 QML**：
 *   - 播放内核换了 → 本类不动
 *   - 平台换了 → 换 `MediaControls` 实现，本类不动
 *
 * 推送节流：位置类变化 1s 一次（系统时间轴每次更新都会重绘面板 UI），
 * 状态/元数据变化立即推。封面走 `CoverService`，与 mini 条、全屏封面同源同缓存。
 */
class MediaSession : public QObject
{
    Q_OBJECT
public:
    static MediaSession &instance();

    /**
     * QML 根窗口就绪后接上系统媒体会话（SMTC 需要窗口句柄）。
     *
     * 重复调用是空操作；平台没有后端或绑定失败时静默降级 ——
     * 系统面板是增强项，不该影响播放本身（§14.16 不得因附属功能阻断主流程）。
     */
    void attachWindow(QWindow *window);

    /// 退出前解开绑定，别在系统里留一个点不动的会话
    void detach();

private:
    explicit MediaSession(QObject *parent = nullptr);
    ~MediaSession() override;
    Q_DISABLE_COPY_MOVE(MediaSession)

    MediaSnapshot buildSnapshot();
    QUrl coverUrlFor(const QString &connectionId, const QString &path);
    /// @param timelineOnly 位置类上报（按 1s 节流）；false 表示状态变化，立即推
    void push(bool timelineOnly);
    void wireCallbacks();
    int seekStepMs() const;

    std::unique_ptr<MediaControls> m_controls;
    QElapsedTimer m_timelineClock;
    MediaSnapshot m_last;
    bool m_pushed = false;
    /// 已为哪个「连接 + 路径」请求过封面，避免每秒重复请求
    QString m_coverRequestedFor;
};

} // namespace myhub
