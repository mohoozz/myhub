#pragma once

#include <QObject>
#include <QQmlEngine>

namespace myhub {

/**
 * 主题控制（§2.2.3）。
 *
 * 亮（白底蓝调）/ 暗（纯黑）双主题，支持「跟随系统」并实时响应
 * Windows 应用模式 / macOS 外观变化。
 * 沉浸场景（播放器 / 阅读器）强制纯黑，由 QML 侧单独处理。
 */
class ThemeController : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(Mode mode READ mode WRITE setMode NOTIFY modeChanged)
    Q_PROPERTY(bool isDark READ isDark NOTIFY isDarkChanged)

public:
    enum Mode
    {
        FollowSystem = 0,
        Light,
        Dark
    };
    Q_ENUM(Mode)

    explicit ThemeController(QObject *parent = nullptr);

    Mode mode() const { return m_mode; }
    void setMode(Mode m);

    /// 当前实际是否为暗色（跟随系统时取系统值）
    bool isDark() const;

    /// 与 AppSettings 的 app.themeMode 互转
    Q_INVOKABLE void setModeString(const QString &s);
    Q_INVOKABLE QString modeString() const;

signals:
    void modeChanged();
    void isDarkChanged();

private:
    void onSystemThemeChanged();

    Mode m_mode = FollowSystem;
    bool m_cachedDark = false;
};

} // namespace myhub
