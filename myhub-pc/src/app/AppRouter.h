#pragma once

#include <QObject>
#include <QQmlEngine>

namespace myhub {

/**
 * 模块路由（§2.2.1）。
 *
 * 导航项：阅读 / 收藏 / 动态 / 浏览 / 浏览器 / 设置。
 * **重复点击当前导航项 → 回到该模块起始页**（与 iOS AppRouter.reselect 等价）。
 */
class AppRouter : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(
        Module currentModule READ currentModule WRITE setCurrentModule NOTIFY currentModuleChanged)

public:
    enum Module
    {
        Reading = 0, ///< 正在阅读
        Favorites,   ///< 收藏
        Feed,        ///< 动态（预留）
        Browse,      ///< 浏览
        Browser,     ///< 内置浏览器
        Settings,    ///< 设置
    };
    Q_ENUM(Module)

    explicit AppRouter(QObject *parent = nullptr);

    Module currentModule() const { return m_currentModule; }
    void setCurrentModule(Module m);

    /**
     * 导航项被点击。若已在该模块则发出 reselected 信号
     * （浏览页借此回到连接源选择列表）。
     */
    Q_INVOKABLE void select(Module m);

    /// 模块显示名
    Q_INVOKABLE QString moduleName(Module m) const;

    /// 快捷键 Ctrl+1..6 映射
    Q_INVOKABLE void selectByIndex(int index);

signals:
    void currentModuleChanged();
    /// 重复点击当前导航项
    void reselected(Module m);

private:
    Module m_currentModule = Reading;
};

} // namespace myhub
