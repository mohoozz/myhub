#pragma once

#include "core/stream/LocalStreamProxy.h"

#include <QHash>
#include <QObject>
#include <QString>
#include <QUrl>
#include <QVariantMap>

#include <memory>

namespace myhub {

class AdapterRangeSource;
class CachedRangeReader;
class SegmentCache;

/**
 * 远程条目的「边下边播」会话管理（§4.2 的装配层）。
 *
 * 职责只有装配：把「连接源 + 路径」变成一条 `http://127.0.0.1:port/stream/...` 的流，
 * 并把拉流（AdapterRangeSource）、分片缓存（SegmentCache）、装配/预读（CachedRangeReader）
 * 串起来。真正的协议与缓存逻辑都在 core 层，便于单测。
 *
 * 生命周期纪律：
 *   - 每次起播先释放同一缓存键的旧会话——否则连着点两个视频会有两条管线同时拉流，
 *     新视频的起播被旧视频的预读拖慢
 *   - `release()` 会 `cancelAll()`，排队中的预读立刻作废（会话注销语义）
 *   - 回环监听换端口后自动重新注册全部会话并广播新 URL，由播放门面决定是否重开
 *   - `size <= 0` 直接拒绝：长度未知的分段读取无法保证 seek 正确，宁可回退到下载后播放
 */
class PlaybackStreamService : public QObject
{
    Q_OBJECT
public:
    struct Prepared
    {
        QString streamId;
        QUrl url;
        QString error;

        bool ok() const { return error.isEmpty() && !streamId.isEmpty() && url.isValid(); }
    };

    struct Session
    {
        QString key;
        QString fileName;
        qint64 size = -1;
        AdapterRangeSource *source = nullptr;
        CachedRangeReader *reader = nullptr;
    };

    static PlaybackStreamService &instance();

    /// 建立（或重建）一条远程播放会话
    Prepared prepare(const QString &connectionId, const QString &path, const QString &displayName,
                     qint64 size, const QString &fingerprint);

    /**
     * 离线起播：不看连接源，直接凭缓存身份（meta.json）起播。
     * 只接受「缓存已完整」的文件；`reason` 是上层拿到的原始失败原因，用于拼错误文案。
     * 供门面在 stat 失败（断网）时兜底调用。
     */
    Prepared prepareOffline(const QString &connectionId, const QString &path,
                            const QString &displayName, const QString &reason = QString());

    void release(const QString &streamId);
    void releaseAll();

    /// 主动探活回环监听（起播报错时由播放门面调用）
    void verifyHealth() { m_proxy->verifyHealth(); }

    QString activeStreamId() const { return m_activeStream; }
    QVariantMap snapshot() const;

signals:
    /// 回环监听换端口：`streamId` 的 URL 变了，正在播的会话需按新地址重开
    void streamUrlRebuilt(const QString &streamId, const QUrl &url);

private:
    PlaybackStreamService();
    ~PlaybackStreamService() override;

    QUrl registerStream(const QString &streamId);
    void onListenerRebuilt(quint16 oldPort, quint16 newPort);

    /// 注销某一缓存键的全部会话（同文件重复起播 / 轨道切换）
    void releaseByKey(const QString &key);

    std::unique_ptr<LocalStreamProxy> m_proxy;
    std::unique_ptr<SegmentCache> m_cache;
    QHash<QString, Session> m_sessions;
    int m_seq = 0;
    QString m_activeStream;
};

} // namespace myhub
