#pragma once

#include "core/storage/StorageError.h"

#include <QByteArray>
#include <QHash>
#include <QObject>
#include <QString>
#include <QVariantMap>

#include <functional>

class QTcpServer;
class QTcpSocket;

namespace myhub {

/**
 * 127.0.0.1 回环 HTTP 代理（§4.2）。
 *
 * 为什么要多绕这一跳：mpv 对 `http://` 才有完整的 seek / 缓存 / 断流重连策略，
 * 而 WebDAV / SMB 的随机读接口并不是 URL。把「条目 → 字节源」的差异全部收在本服务内，
 * 播放器只看见一个普通的可 Range 的 HTTP 文件。
 *
 * 接口纪律：
 *   - 路由 `/stream/<id>/<fileName>`：`id` 由上层（播放源解析器）分配，
 *     `fileName` 只用于 Content-Type 与 mpv 的标题推断，不参与寻址
 *   - `GET` / `HEAD` + 单区间 `Range`（`a-b` / `a-` / `-n`），200 / 206 / 416 语义按 RFC 7233
 *   - **端口随机**（bind 0），只绑 127.0.0.1，不对外暴露
 *   - **健康探活**：真实 GET `/health`，300ms 内没拿到 200 即判定监听已僵死，
 *     立即换端口重建并把已注册的流原样挂回去（换端口后 URL 变了，
 *     上层需据此重开播放——回环连接被拒时换端口重试一次）
 *   - 响应体边读边写，不整段缓冲；`bytesToWrite` 超阈值时靠 bytesWritten 回压，
 *     避免 4K 源把内存打满
 */
class LocalStreamProxy : public QObject
{
    Q_OBJECT
public:
    using ReadCallback = std::function<void(QByteArray data, StorageError error)>;

    struct Stream
    {
        qint64 size = -1; ///< 总长度；-1 未知时按顺序流式返回
        QString fileName; ///< 用于 Content-Type 与标题推断
        /// 读 `[start, start + length)`；必须在本线程回调
        std::function<void(qint64 start, qint64 length, ReadCallback)> read;
    };

    explicit LocalStreamProxy(QObject *parent = nullptr);
    ~LocalStreamProxy() override;

    /// 启动监听；port 为 0 时随机。失败自动换端口重试（最多 5 次）
    bool start(quint16 port = 0);
    void stop();
    bool isRunning() const;
    quint16 port() const { return m_port; }
    QString baseUrl() const;

    /// 注册一条流，返回可直接交给播放器的 URL；同一 id 重复注册即覆盖
    QString registerStream(const QString &id, Stream stream);
    void unregisterStream(const QString &id);
    void clearStreams();
    int streamCount() const { return m_streams.size(); }

    /// 非阻塞探活（300ms）；僵死则换端口重建监听
    void verifyHealth();
    /// 探活超时（毫秒），供测试缩短
    void setHealthTimeoutMs(int ms) { m_healthTimeoutMs = qMax(50, ms); }

    QVariantMap healthSnapshot() const;

signals:
    /// 监听换端口了：旧 URL 全部失效，上层需用新 baseUrl 重开正在播的流
    void listenerRebuilt(quint16 oldPort, quint16 newPort);
    void healthChecked(bool ok);

private:
    friend class StreamHttpConnection;

    void onNewConnection();
    void rebuildListener();
    QString urlFor(const QString &id, const QString &fileName) const;

    QTcpServer *m_server = nullptr;
    quint16 m_port = 0;
    QHash<QString, Stream> m_streams;

    int m_healthTimeoutMs = 300;
    bool m_healthInFlight = false;
    bool m_lastHealthOk = false;
    int m_lastHealthMs = -1;
    QString m_lastHealthError;
    int m_rebuildCount = 0;
};

} // namespace myhub
