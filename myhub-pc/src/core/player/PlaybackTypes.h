#pragma once

#include <QList>
#include <QMetaType>
#include <QString>
#include <QUrl>

/*
  播放层数据类型（《需求分析文档》§4.3）。

  只依赖 QtCore：播放门面 PlayerCore 位于 myhub_core，可被 QTest 直接覆盖；
  与 QtQuick/mpv 相关的部分留在 app 层（MpvVideoItem / MpvEngine）。
*/

namespace myhub {

/// 播放状态机（PC-201：进入播放、播完、失败）
enum class PlaybackState
{
    Idle,    // 未加载
    Loading, // 已下 loadfile，等 fileLoaded
    Playing, // 播放中（mpv pause=false）
    Paused,  // 暂停（mpv pause=true）
    Ended,   // 播完（keep-open 保留最后一帧，等重播/下一集）
    Error,   // 起播失败
};

/// 一次播放请求
struct PlaybackRequest
{
    QUrl url;                   // 本地 file:// 或后续的本地流代理 http://127.0.0.1:port
    QString title;              // 展示用标题（已去扩展名）
    QString connectionId;       // 归属连接（「下一个」与进度记录用）
    QString path;               // 源路径（进度记录 / 同名字幕匹配）
    qint64 startPositionMs = 0; // 精准续播起点（PC-209）
    bool audioOnly = false;     // 纯音频模式起播（PC-206）

    bool isValid() const { return url.isValid() && !url.isEmpty(); }
};

/// 一条音轨 / 字幕轨（mpv track-list 的投影）
struct PlaybackTrack
{
    int id = -1;
    QString title;
    QString lang;
    QString codec;
    bool external = false;
    bool selected = false;
};

} // namespace myhub

Q_DECLARE_METATYPE(myhub::PlaybackState)
Q_DECLARE_METATYPE(myhub::PlaybackTrack)
Q_DECLARE_METATYPE(QList<myhub::PlaybackTrack>)
