#include "WindowsIntegration.h"

#include <QOperatingSystemVersion>
#include <QWindow>

#include <windows.h>
#include <dwmapi.h>

namespace myhub {

namespace {

// 这些属性值在较旧的 SDK 头文件中可能未定义
constexpr DWORD kDwmUseImmersiveDarkMode = 20;
constexpr DWORD kDwmSystemBackdropType = 38;

// DWM_SYSTEMBACKDROP_TYPE
constexpr DWORD kBackdropMica = 2;    // Mica（Win11 22H2+）
constexpr DWORD kBackdropAcrylic = 3; // Acrylic

HWND handleOf(QWindow *window)
{
    if (!window)
        return nullptr;
    // QWindow::winId() 在 Windows 上返回 WId（整数句柄），HWND 就是同一个值；
    // Win32 侧没有别的拿法，此处的 int->ptr 转换属于平台约定
    return reinterpret_cast<HWND>(window->winId()); // NOLINT(performance-no-int-to-ptr)
}

} // namespace

bool WindowsIntegration::isWindows11OrGreater()
{
    // Windows 11 的内部版本号从 22000 起
    const auto v = QOperatingSystemVersion::current();
    return v.majorVersion() > 10 || (v.majorVersion() == 10 && v.microVersion() >= 22000);
}

bool WindowsIntegration::enableWindowMaterial(QWindow *window)
{
    HWND hwnd = handleOf(window);
    if (!hwnd)
        return false;

    // Win11 优先 Mica，观感更贴近「液体玻璃」的桌面等价
    DWORD backdrop = isWindows11OrGreater() ? kBackdropMica : kBackdropAcrylic;
    const HRESULT hr =
        DwmSetWindowAttribute(hwnd, kDwmSystemBackdropType, &backdrop, sizeof(backdrop));
    return SUCCEEDED(hr);
}

void WindowsIntegration::setDarkTitleBar(QWindow *window, bool dark)
{
    HWND hwnd = handleOf(window);
    if (!hwnd)
        return;

    const BOOL value = dark ? TRUE : FALSE;
    DwmSetWindowAttribute(hwnd, kDwmUseImmersiveDarkMode, &value, sizeof(value));
}

} // namespace myhub
