#pragma once

#include "PlaybackTypes.h"
#include "core/history/ProgressRepository.h"

#include <QObject>
#include <QTimer>

namespace myhub {

class PlayerCore;

/**
 * 把 PlayerCore 的播放事实写成阅读进度（PC-209）。
 *
 * 上报节奏（需求文档 §4.3）：
 *   - 播放中**节流 5s** 落盘，避免每帧写库
 *   - **暂停 / seek / 播完 / 切换文件 / 退出**一律强制落盘
 *
 * 放在 myhub_core：只依赖 QtCore，可用 FakeEngine 完整覆盖；
 * PlayerBridge 只负责在装配引擎时顺手创建它。
 */
class PlaybackProgressTracker : public QObject
{
    Q_OBJECT
public:
    PlaybackProgressTracker(PlayerCore *core, ProgressRepository *repository,
                            QObject *parent = nullptr);
    ~PlaybackProgressTracker() override;

    /// 播放中的落盘间隔（默认 5s；单测调小以免空等）
    void setIntervalMs(int ms);
    int intervalMs() const { return m_heartbeat.interval(); }

    /// 立即把当前会话落盘（幂等：无会话或无进展时什么都不做）
    void flush();

    /**
     * 播放事实 → 进度记录（纯函数，单测直接覆盖）。
     *
     * `finished` 的判定集中在这里：播到结尾（引擎 endReached）或距结尾不足 3s
     * 都算看完，续播时才会从头开始而不是一进去就结束。
     */
    static ProgressRecord buildRecord(const PlaybackRequest &request, qint64 positionMs,
                                      qint64 durationMs, bool ended);

private:
    void onStateChanged(PlaybackState state);
    void onPositionChanged(qint64 positionMs);
    void onSeeked(qint64 positionMs);
    void onSessionEnding();

    PlayerCore *m_core = nullptr;
    ProgressRepository *m_repository = nullptr;
    QTimer m_heartbeat;
    qint64 m_positionMs = 0;
    bool m_dirty = false; ///< 自上次落盘以来位置有推进
};

} // namespace myhub
