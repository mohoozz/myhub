#pragma once

#include "WebDAVAdapter.h"

#include <QElapsedTimer>
#include <QVariantMap>

namespace myhub {

/**
 * 内外网双地址路由装饰器（PC-708）。
 *
 * Happy Eyeballs 竞速：内网先发、外网延迟 ~700ms 并发兜底，先成功者**锁定**。
 * 锁定后所有请求复用该地址，不再每次判定（§14.9：判定 ~700ms 完成，不得等待数秒）。
 *
 * 失败自愈纪律：
 *   - **仅连接类/网关类错误**（超时/DNS/连不上/断网/5xx/InvalidResponse）才回退或清锁
 *   - 404/409/鉴权等业务错误**不触发**切换
 *   - 清锁带 8s 冷却，避免抖动
 *   - **流式读写先解析路由再选址**（流不可中途换址）
 */
class RoutedWebDAVAdapter : public StorageAdapter
{
    Q_OBJECT
public:
    explicit RoutedWebDAVAdapter(WebDAVConfig config, QObject *parent = nullptr);
    ~RoutedWebDAVAdapter() override;

    QString typeName() const override { return QStringLiteral("webdav"); }

    void list(const QString &dir, ListCallback cb) override;
    void stat(const QString &path, StatCallback cb) override;
    void readRange(const QString &path, std::optional<qint64> start, std::optional<qint64> end,
                   DataCallback cb) override;
    void testConnection(ErrorCallback cb) override;

    void writeFile(const QString &path, const QByteArray &data, ErrorCallback cb) override;
    void uploadFile(const QString &path, const QString &localPath, UploadProgress progress,
                    CancelProbe isCancelled, ErrorCallback cb) override;
    void writeFrom(const QString &path, QIODevice *source, qint64 totalBytes,
                   UploadProgress progress, CancelProbe isCancelled, ErrorCallback cb) override;
    void makeDirectory(const QString &path, ErrorCallback cb) override;
    void remove(const QString &path, ErrorCallback cb) override;
    void move(const QString &src, const QString &dst, ErrorCallback cb) override;
    void copy(const QString &src, const QString &dst, ErrorCallback cb) override;

    /// 诊断快照（设置 → 关于 → 日志中展示，§1.5 关键链路埋点）
    QVariantMap lockSnapshot() const;

    /// 使当前锁定失效（供播放层在连续零进展时调用）
    void invalidateRoute();

    /// 已锁定的地址；未锁定返回空
    QString lockedBaseURL() const { return m_lockedURL; }

    /// 锁定的是否为内网地址
    bool lockedIsInternal() const { return m_lockedIsInternal; }

signals:
    /// 地址锁定变化（供 UI 显示「内网可达 / 外网可达」）
    void routeLocked(const QString &url, bool isInternal);

private:
    /// 解析路由：已锁定直接回调；未锁定则发起竞速
    void resolveRoute(std::function<void(const QString &url, StorageError)> done);
    void startRace(std::function<void(const QString &url, StorageError)> done);
    void applyLock(const QString &url, bool isInternal);
    bool canClearLock() const;

    /// 执行一次带自愈的操作：失败且可恢复时清锁并重试一次
    template <typename Invoke, typename Fail>
    void withRoute(Invoke invoke, Fail onFail);

    WebDAVConfig m_config;
    WebDAVAdapter *m_adapter = nullptr; ///< 实际执行者，地址由本类注入

    QString m_lockedURL;
    bool m_lockedIsInternal = false;
    QElapsedTimer m_lockClearedAt; ///< 清锁冷却计时（8s）
    bool m_raceInFlight = false;
    QList<std::function<void(const QString &, StorageError)>> m_pendingRace;

    qint64 m_lastRaceMs = -1;
    QString m_lastRaceWinner;
};

} // namespace myhub
