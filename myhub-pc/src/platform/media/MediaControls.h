#pragma once

#include <QString>
#include <QUrl>

#include <functional>
#include <memory>

class QWindow;

namespace myhub {

/**
 * 系统媒体控制（PC-602）的平台中立项。
 *
 * Windows 走 SMTC（`WindowsMediaControls`），macOS 走
 * `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`（`MacMediaControls`）。
 * 上层只有 `app/MediaSession` 一个使用者：它把播放会话聚合成 `MediaSnapshot`
 * 推下来，把系统面板/媒体键的操作经 `MediaControlsCallbacks` 收回去。
 *
 * 纪律：
 *   - 本接口**不认识 PlayerCore / mpv**：换了播放内核不需要改平台代码
 *   - 实现必须在 `apply()` 里做幂等：`MediaSession` 只保证「值变了才推」
 *   - 回调可能来自平台的后台线程，实现方负责回到 GUI 线程
 */
struct MediaSnapshot
{
    /// 是否有一个可展示的会话；false 表示面板该收起（关掉播放时）
    bool active = false;
    QString title;
    QString artist;
    /// 本地已缓存的封面（file:// URL）；空表示没有封面
    QUrl coverUrl;
    /// 有视频轨（SMTC 的媒体类型区分 Music / Video）
    bool video = false;
    bool playing = false;
    qint64 positionMs = 0;
    qint64 durationMs = 0;
    double speed = 1.0;
    /// 上/下一个（映射为 §4.6 的推荐上一个/下一个）；未接入时后端禁用按钮
    bool canNext = false;
    bool canPrevious = false;

    bool operator==(const MediaSnapshot &other) const
    {
        return active == other.active && title == other.title && artist == other.artist
            && coverUrl == other.coverUrl && video == other.video && playing == other.playing
            && positionMs == other.positionMs && durationMs == other.durationMs
            && qFuzzyCompare(speed + 1.0, other.speed + 1.0) && canNext == other.canNext
            && canPrevious == other.canPrevious;
    }
    bool operator!=(const MediaSnapshot &other) const { return !(*this == other); }
};

/// 系统面板 / 媒体键触发的操作（实现方保证在 GUI 线程调用）
struct MediaControlsCallbacks
{
    std::function<void()> play;
    std::function<void()> pause;
    std::function<void()> togglePlayPause;
    std::function<void()> stop;
    std::function<void()> next;
    std::function<void()> previous;
    std::function<void(qint64)> seekTo;
    /// 快进 / 快退（系统面板的 FF / Rewind 键，步长取设置里的 seek 步长）
    std::function<void()> fastForward;
    std::function<void()> rewind;
    std::function<void(double)> setSpeed;
};

class MediaControls
{
public:
    virtual ~MediaControls() = default;

    virtual void setCallbacks(MediaControlsCallbacks callbacks) = 0;

    /**
     * 把系统媒体会话绑定到窗口（SMTC 的 `GetForWindow` 需要 HWND）。
     * 返回是否绑定成功；失败时上层静默降级（没有系统媒体面板而已）。
     */
    virtual bool attach(QWindow *window) = 0;

    /// 推送当前快照（幂等；`active=false` 时应收起面板并禁用按钮）
    virtual void apply(const MediaSnapshot &snapshot) = 0;

    /// 解除绑定并移除事件处理器（析构时无需再调用）
    virtual void detach() = 0;
};

/// 平台工厂：Windows / macOS 各有一份实现；其余平台返回 nullptr
std::unique_ptr<MediaControls> createMediaControls();

} // namespace myhub
