#include "WindowController.h"

#include "core/preferences/AppSettings.h"
#include "core/utils/AppLogger.h"
#include "core/utils/AppPaths.h"

#include <QDesktopServices>
#include <QDir>
#include <QFileInfo>
#include <QGuiApplication>
#include <QProcess>
#include <QQuickWindow>
#include <QScreen>
#include <QUrl>

namespace myhub {

namespace {
constexpr int kMinWidth = 640;
constexpr int kMinHeight = 480;

// 悬浮小窗（§4.4）：默认 480 宽（16:9），下限保证控制条放得下，上限不超过常见屏宽
constexpr int kFloatingDefaultWidth = 480;
constexpr int kFloatingMinWidth = 320;
constexpr int kFloatingMinHeight = 180;
constexpr int kFloatingMaxWidth = 1280;
constexpr int kFloatingMargin = 24;

constexpr auto kFloatingSizeKey = "window.floatingSize";
constexpr auto kMinimizeToFloatingKey = "player.minimizeToFloating";
} // namespace

WindowController::WindowController(QObject *parent)
    : QObject(parent)
{}

void WindowController::attach(QQuickWindow *window)
{
    m_window = window;
    if (!m_window)
        return;

    m_window->setMinimumSize(QSize(kMinWidth, kMinHeight));

    // 窗口关闭前兜底保存几何
    connect(m_window, &QQuickWindow::closing, this, [this] { saveGeometry(); });
}

QRect WindowController::sanitizeGeometry(const QRect &r) const
{
    if (r.isEmpty())
        return {};

    // 至少与某块屏幕有交集，否则视为无效（显示器已拔除等情况）
    bool visible = false;
    for (const QScreen *screen : QGuiApplication::screens()) {
        if (screen->availableGeometry().intersects(r)) {
            visible = true;
            break;
        }
    }
    if (!visible)
        return {};

    QRect out = r;
    out.setWidth(qMax(out.width(), kMinWidth));
    out.setHeight(qMax(out.height(), kMinHeight));
    return out;
}

bool WindowController::restoreGeometry()
{
    if (!m_window)
        return false;

    auto &settings = AppSettings::instance();
    const QRect saved = sanitizeGeometry(settings.windowBounds());

    if (saved.isValid()) {
        m_window->setGeometry(saved);
    } else if (QScreen *screen = QGuiApplication::primaryScreen()) {
        // 首次启动：居中，取可用区域的 80%
        const QRect avail = screen->availableGeometry();
        const int w = qMax(kMinWidth, static_cast<int>(avail.width() * 0.8));
        const int h = qMax(kMinHeight, static_cast<int>(avail.height() * 0.8));
        m_window->setGeometry(avail.x() + (avail.width() - w) / 2,
                              avail.y() + (avail.height() - h) / 2, w, h);
    }

    if (settings.windowMaximized())
        m_window->showMaximized();

    return saved.isValid();
}

void WindowController::saveGeometry()
{
    if (!m_window)
        return;

    auto &settings = AppSettings::instance();
    const bool maximized = (m_window->visibility() == QQuickWindow::Maximized);
    settings.setWindowMaximized(maximized);

    // 最大化时不要把最大化后的矩形存成常规尺寸；
    // 小窗时更不能存 —— 否则下次启动会把 480x270 当成主窗口尺寸恢复
    if (!maximized && !m_floating && m_window->visibility() == QQuickWindow::Windowed)
        settings.setWindowBounds(m_window->geometry());

    settings.sync();
}

bool WindowController::sidebarCollapsed() const
{
    return AppSettings::instance().sidebarCollapsed();
}

void WindowController::setSidebarCollapsed(bool v)
{
    if (sidebarCollapsed() == v)
        return;
    AppSettings::instance().setSidebarCollapsed(v);
    emit sidebarCollapsedChanged();
}

void WindowController::toggleFullScreen()
{
    if (!m_window)
        return;
    if (m_window->visibility() == QQuickWindow::FullScreen)
        m_window->showNormal();
    else
        m_window->showFullScreen();
}

QSize WindowController::floatingSize() const
{
    const QSize saved = AppSettings::instance().value(kFloatingSizeKey).toSize();
    int w = saved.width() > 0 ? saved.width() : kFloatingDefaultWidth;
    int h = saved.height() > 0 ? saved.height() : (w * 9) / 16;
    w = qBound(kFloatingMinWidth, w, kFloatingMaxWidth);
    h = qBound(kFloatingMinHeight, h, (kFloatingMaxWidth * 9) / 16);
    return QSize(w, h);
}

void WindowController::saveFloatingSize(const QSize &size)
{
    if (size.width() <= 0 || size.height() <= 0)
        return;
    AppSettings::instance().setValue(kFloatingSizeKey, size);
}

void WindowController::enterFloating()
{
    if (!m_window || m_floating)
        return;

    // 还原点。最大化要单独记住：showNormal() 会把矩形换成 normalGeometry
    m_savedMaximized = (m_window->visibility() == QQuickWindow::Maximized);
    m_savedGeometry = m_window->geometry();
    m_savedFlags = m_window->flags();

    // 先回普通态再改 flags：最大化时改 flags 会把窗口丢到 (0,0) 并且尺寸错乱
    if (m_window->visibility() != QQuickWindow::Windowed)
        m_window->showNormal();

    const QSize size = floatingSize();
    m_window->setMinimumSize(QSize(kFloatingMinWidth, kFloatingMinHeight));
    // 无边框 + 置顶。Windows 11 的 DWM 会给无边框窗口补圆角与投影，
    // 因此不需要自绘窗口形状（自绘反而会和视频 FBO 打架）
    m_window->setFlags(Qt::Window | Qt::FramelessWindowHint | Qt::WindowStaysOnTopHint);

    QScreen *screen = m_window->screen();
    if (!screen)
        screen = QGuiApplication::primaryScreen();
    if (screen) {
        const QRect avail = screen->availableGeometry();
        m_window->setGeometry(avail.right() - size.width() - kFloatingMargin,
                              avail.bottom() - size.height() - kFloatingMargin, size.width(),
                              size.height());
    } else {
        m_window->resize(size);
    }

    m_window->show();
    m_window->raise();
    m_window->requestActivate();

    m_floating = true;
    emit floatingChanged();
    MH_INFO(App, QStringLiteral("进入悬浮小窗：%1x%2").arg(size.width()).arg(size.height()));
}

void WindowController::exitFloating()
{
    if (!m_window || !m_floating)
        return;

    saveFloatingSize(m_window->size());

    m_floating = false;
    // 与进入相反的顺序：先恢复 flags / 最小尺寸，再摆回原位置
    m_window->setMinimumSize(QSize(kMinWidth, kMinHeight));
    m_window->setFlags(m_savedFlags);

    const QRect target = sanitizeGeometry(m_savedGeometry);
    if (target.isValid())
        m_window->setGeometry(target);

    if (m_savedMaximized)
        m_window->showMaximized();
    else
        m_window->show();
    m_window->raise();
    m_window->requestActivate();

    emit floatingChanged();
    MH_INFO(App, QStringLiteral("退出悬浮小窗"));
}

void WindowController::startSystemMove()
{
    if (m_window && m_floating)
        m_window->startSystemMove();
}

void WindowController::startSystemResize(int edges)
{
    if (m_window && m_floating)
        m_window->startSystemResize(Qt::Edges(edges));
}

bool WindowController::minimizeToFloating() const
{
    return AppSettings::instance().value(kMinimizeToFloatingKey, false).toBool();
}

void WindowController::setMinimizeToFloating(bool v)
{
    if (minimizeToFloating() == v)
        return;
    AppSettings::instance().setValue(kMinimizeToFloatingKey, v);
    emit minimizeToFloatingChanged();
}

void WindowController::revealInFileManager(const QString &localPath)
{
    if (localPath.isEmpty())
        return;

#if defined(Q_OS_WIN)
    // /select 让资源管理器定位到该项而非进入目录
    QProcess::startDetached(QStringLiteral("explorer.exe"),
                            {QStringLiteral("/select,") + QDir::toNativeSeparators(localPath)});
#elif defined(Q_OS_MACOS)
    QProcess::startDetached(QStringLiteral("open"), {QStringLiteral("-R"), localPath});
#else
    QDesktopServices::openUrl(QUrl::fromLocalFile(QFileInfo(localPath).absolutePath()));
#endif
}

void WindowController::openDataFolder()
{
    QDesktopServices::openUrl(QUrl::fromLocalFile(AppPaths::dataDir()));
}

void WindowController::openLogFolder()
{
    QDesktopServices::openUrl(QUrl::fromLocalFile(AppPaths::logDir()));
}

} // namespace myhub
