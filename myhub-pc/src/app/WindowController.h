#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QQuickWindow>
#include <QRect>

namespace myhub {

/**
 * 窗口管理（§2.2 / PC-607）。
 *
 * - 尺寸 / 位置 / 最大化状态记忆并恢复
 * - 最小尺寸限制
 * - 跨显示器移动时保证窗口仍在可见区域内
 */
class WindowController : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(bool sidebarCollapsed READ sidebarCollapsed WRITE setSidebarCollapsed NOTIFY
                   sidebarCollapsedChanged)

    /// 是否处于置顶悬浮小窗形态（§4.4）。窗口本身变身，不另开窗口。
    Q_PROPERTY(bool floating READ floating NOTIFY floatingChanged)

    /// 最小化主窗口时自动进入悬浮小窗（默认关，运行期改动立即生效）
    Q_PROPERTY(bool minimizeToFloating READ minimizeToFloating WRITE setMinimizeToFloating NOTIFY
                   minimizeToFloatingChanged)

public:
    explicit WindowController(QObject *parent = nullptr);

    /// 由 QML 在窗口创建后注册，用于恢复与持久化几何信息
    Q_INVOKABLE void attach(QQuickWindow *window);

    /// 恢复上次窗口几何；返回是否成功恢复
    Q_INVOKABLE bool restoreGeometry();

    /// 立即保存窗口几何（退出前兜底）
    Q_INVOKABLE void saveGeometry();

    /// 手动固定的侧边栏折叠状态（§2.2.1 可手动固定并持久化）
    bool sidebarCollapsed() const;
    void setSidebarCollapsed(bool v);

    Q_INVOKABLE void toggleFullScreen();

    /**
     * 进入 / 退出置顶悬浮小窗（§4.4）。
     *
     * 为什么是「主窗口变身」而不是另开一个窗口：全进程只有一个 `MpvVideoItem`，
     * 它的 render context 绑在唯一 `QQuickWindow` 的场景图上；把一个
     * `QQuickFramebufferObject` 搬进另一个窗口的 scene graph 必然销毁重建渲染节点，
     * 实测「切回来整片黑 + 渲染线程死锁」。所以小窗就是主窗口本人：
     * 改 flags（无边框 + 置顶）、缩到小窗尺寸、记住还原点。
     *
     * mpvqt 的 `MpvRenderer` 在析构时会 `freeContext()`、在新场景图里重新
     * `createFramebufferObject()` 时重建 context，因此改 flags 引起的场景图重建
     * 不会丢掉解码会话（播放不中断、进度不丢）。
     */
    Q_INVOKABLE void enterFloating();
    Q_INVOKABLE void exitFloating();

    /// 无边框窗口的系统拖动 / 缩放（QML 里由拖动区与边缘热区调用）
    Q_INVOKABLE void startSystemMove();
    Q_INVOKABLE void startSystemResize(int edges);

    bool floating() const { return m_floating; }
    bool minimizeToFloating() const;
    void setMinimizeToFloating(bool v);

    /// 在资源管理器 / 访达中显示（PC-601）
    Q_INVOKABLE void revealInFileManager(const QString &localPath);

    /// 打开数据目录 / 日志目录（设置页）
    Q_INVOKABLE void openDataFolder();
    Q_INVOKABLE void openLogFolder();

signals:
    void sidebarCollapsedChanged();
    void floatingChanged();
    void minimizeToFloatingChanged();

private:
    /// 确保窗口矩形至少部分落在某个屏幕内，避免显示器变更后窗口「消失」
    QRect sanitizeGeometry(const QRect &r) const;

    /// 小窗尺寸：记忆值，夹在允许区间内
    QSize floatingSize() const;
    void saveFloatingSize(const QSize &size);

    QQuickWindow *m_window = nullptr;

    bool m_floating = false;
    /// 进入小窗前的还原点（几何 / 最大化 / 原始 flags）
    QRect m_savedGeometry;
    bool m_savedMaximized = false;
    Qt::WindowFlags m_savedFlags;
};

} // namespace myhub
