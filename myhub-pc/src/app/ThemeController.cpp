#include "ThemeController.h"

#include "core/preferences/AppSettings.h"

#include <QGuiApplication>
#include <QStyleHints>

namespace myhub {

ThemeController::ThemeController(QObject *parent)
    : QObject(parent)
{
    setModeString(AppSettings::instance().themeMode());
    m_cachedDark = isDark();

    // 跟随系统时实时响应外观变化（Qt 6.5+ 提供跨平台的 colorScheme 通知）
    if (auto *hints = QGuiApplication::styleHints()) {
        connect(hints, &QStyleHints::colorSchemeChanged, this,
                [this](Qt::ColorScheme) { onSystemThemeChanged(); });
    }
}

void ThemeController::onSystemThemeChanged()
{
    if (m_mode != FollowSystem)
        return;
    const bool dark = isDark();
    if (dark != m_cachedDark) {
        m_cachedDark = dark;
        emit isDarkChanged();
    }
}

bool ThemeController::isDark() const
{
    switch (m_mode) {
    case Light:
        return false;
    case Dark:
        return true;
    case FollowSystem:
        break;
    }
    if (auto *hints = QGuiApplication::styleHints())
        return hints->colorScheme() == Qt::ColorScheme::Dark;
    return false;
}

void ThemeController::setMode(Mode m)
{
    if (m_mode == m)
        return;
    m_mode = m;
    AppSettings::instance().setThemeMode(modeString());
    emit modeChanged();

    const bool dark = isDark();
    if (dark != m_cachedDark) {
        m_cachedDark = dark;
        emit isDarkChanged();
    }
}

void ThemeController::setModeString(const QString &s)
{
    if (s == QLatin1String("light"))
        setMode(Light);
    else if (s == QLatin1String("dark"))
        setMode(Dark);
    else
        setMode(FollowSystem);
}

QString ThemeController::modeString() const
{
    switch (m_mode) {
    case Light:
        return QStringLiteral("light");
    case Dark:
        return QStringLiteral("dark");
    case FollowSystem:
        break;
    }
    return QStringLiteral("auto");
}

} // namespace myhub
