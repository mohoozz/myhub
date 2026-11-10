#pragma once

#include <QObject>

class QWindow;

namespace myhub {

/**
 * Windows 平台集成（PC-601）。
 *
 * M0 范围：窗口材质（Mica / Acrylic）与深色标题栏。
 * 后续里程碑接入：SMTC 媒体控制（M2）、Toast 通知与 Windows Hello（M5/M6）。
 *
 * 本文件是平台分叉点之一，上层只面向门面接口（§5.2）。
 */
class WindowsIntegration
{
public:
    /// 启用窗口毛玻璃材质；返回是否生效（不支持时由 QML 的 GlassPanel 降级）
    static bool enableWindowMaterial(QWindow *window);

    /// 跟随应用主题切换标题栏明暗
    static void setDarkTitleBar(QWindow *window, bool dark);

    /// 系统是否为 Windows 11（Mica 需 Win11）
    static bool isWindows11OrGreater();
};

} // namespace myhub
