#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QStringList>
#include <QVariantMap>

namespace myhub {

/**
 * 浏览模块的导航状态（PC-102）。
 *
 * - 维护「连接源选择页 ↔ 目录页」的切换
 * - **重复点击「浏览」导航回连接源选择页**（§14.5）
 * - **进入连接源恢复上次路径**（§3.1）
 */
class BrowseController : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(QString connectionId READ connectionId NOTIFY connectionIdChanged)
    Q_PROPERTY(bool inDirectory READ inDirectory NOTIFY connectionIdChanged)
    /// 待执行的「定位到原路径」请求（PC-109）：空 map 表示没有
    Q_PROPERTY(QVariantMap revealRequest READ revealRequest NOTIFY revealChanged)

public:
    explicit BrowseController(QObject *parent = nullptr);

    QString connectionId() const { return m_connectionId; }
    bool inDirectory() const { return !m_connectionId.isEmpty(); }

    /// 打开连接源（恢复上次浏览路径）
    Q_INVOKABLE void openConnection(const QString &id);

    /// 回到连接源选择页
    Q_INVOKABLE void backToConnections();

    /**
     * 跳到指定连接源的指定目录（收藏页「定位」用；页面切换由 QML 负责）。
     *
     * 与 `openConnection` 的差别：不复用「上次路径」，而是直奔给定路径。
     */
    Q_INVOKABLE void navigateTo(const QString &id, const QString &path);

    /**
     * 定位到原路径（PC-109）：从任意页面跳回浏览页并直达条目所在目录，
     * 由目录页负责滚动居中 + 呼吸灯高亮（约 10s 后淡出）。
     *
     * `isDir` 为 true 时定位到目录自身，否则定位到其父目录。
     * 同一目标的重复定位会换新 token，因此能再次触发定位（不会被当成同一次）。
     */
    Q_INVOKABLE void reveal(const QString &id, const QString &filePath, bool isDir);

    QVariantMap revealRequest() const { return m_reveal; }

    /// 目录页完成/放弃定位后调用，避免下次进入时重复触发
    Q_INVOKABLE void clearReveal();

    /// 记住当前路径，下次进入该连接源时恢复
    Q_INVOKABLE void rememberPath(const QString &id, const QString &path);
    Q_INVOKABLE QString lastPath(const QString &id) const;

    /// 当前连接源是否为本地磁盘：本地条目才能按文件路径直接交给播放器
    Q_INVOKABLE bool isCurrentConnectionLocal() const;

signals:
    void connectionIdChanged();
    /// 请求导航到指定路径（供 QML 侧的 model 响应）
    void navigationRequested(const QString &connectionId, const QString &path);
    /// 定位请求变化（含清空）
    void revealChanged();

private:
    QString m_connectionId;
    QVariantMap m_reveal;
    quint64 m_revealToken = 0;
};

} // namespace myhub
