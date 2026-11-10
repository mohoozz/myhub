#include "app/AppState.h"
#include "app/MediaSession.h"
#include "app/PlayerBridge.h"
#include "core/utils/AppLogger.h"

#include <QGuiApplication>
#include <QIcon>
#include <QLocalServer>
#include <QLocalSocket>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QTimer>
#include <QtWebEngineQuick>

using namespace myhub;

namespace {

/// 单实例：再次启动时激活已有窗口（§2.9 PC-607）
constexpr auto kSingleInstanceKey = "MyHub.SingleInstance.com.myhub.desktop";

bool notifyExistingInstance()
{
    QLocalSocket socket;
    socket.connectToServer(QLatin1String(kSingleInstanceKey));
    if (!socket.waitForConnected(300))
        return false;

    // 携带命令行参数（文件关联打开场景）
    const QStringList args = QCoreApplication::arguments().mid(1);
    socket.write(args.join(QLatin1Char('\n')).toUtf8());
    socket.waitForBytesWritten(300);
    socket.disconnectFromServer();
    return true;
}

QLocalServer *startSingleInstanceServer(QObject *parent)
{
    auto *server = new QLocalServer(parent);
    // 清理上次异常退出遗留的套接字
    QLocalServer::removeServer(QLatin1String(kSingleInstanceKey));
    server->listen(QLatin1String(kSingleInstanceKey));
    return server;
}

} // namespace

int main(int argc, char *argv[])
{
    // QtWebEngine 要求在 QGuiApplication 之前初始化
    QtWebEngineQuick::initialize();

    // HiDPI：跨屏移动 DPI 自适应不模糊（§1.2）
    QGuiApplication::setHighDpiScaleFactorRoundingPolicy(
        Qt::HighDpiScaleFactorRoundingPolicy::PassThrough);

    // 渲染后端必须为 OpenGL（§4.3.1）。
    //
    // 播放器用的 mpvqt `MpvAbstractItem` 继承自 QQuickFramebufferObject，
    // 该类仅支持 OpenGL；而 Qt 6 在 Windows 上默认 D3D11。
    // M-1 S1 实测：D3D11 后端下视频 100% 黑屏（非黑像素 0%、vf-fps 0、硬解未初始化）。
    //
    // 必须在 QGuiApplication 构造之前调用。即便 M0 尚未接入播放器，
    // 也在此固定下来，避免 M2 集成时才发现整条渲染链不可用。
    QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);

    QGuiApplication app(argc, argv);

    // 这些名称决定 QStandardPaths 的目录结构，必须在任何路径访问之前设置。
    // 注意：**不设 organizationName**——否则 AppDataLocation 会变成
    // %APPDATA%\MyHub\MyHub（双层嵌套），与需求文档 §2.3 约定的
    // %APPDATA%\MyHub 不符。
    QCoreApplication::setOrganizationDomain(QStringLiteral("myhub.com"));
    QCoreApplication::setApplicationName(QStringLiteral("MyHub"));
    QCoreApplication::setApplicationVersion(QLatin1String(MYHUB_VERSION));
    app.setWindowIcon(QIcon(QStringLiteral(":/icons/app.svg")));

    // 单实例检查
    if (notifyExistingInstance())
        return 0;
    QLocalServer *instanceServer = startSingleInstanceServer(&app);

    // 自绘 UI，不使用平台原生控件样式，保证两端视觉一致（§4.1）
    QQuickStyle::setStyle(QStringLiteral("Basic"));

    // 启动编排：日志 → 崩溃捕获 → 数据库 → Store
    // 用进程内唯一实例：QML 侧的 `AppState` 单例必须看到同一份 phase，
    // 否则启动 Loading 永远等不到 ready（§14.4）
    AppState &appState = AppState::instance();
    appState.bootstrap();

    QQmlApplicationEngine engine;

    // 单实例二次启动时激活窗口
    QObject::connect(instanceServer, &QLocalServer::newConnection, &engine,
                     [instanceServer, &engine]() {
                         QLocalSocket *client = instanceServer->nextPendingConnection();
                         QObject::connect(client, &QLocalSocket::disconnected, client,
                                          &QLocalSocket::deleteLater);
                         MH_INFO(Lifecycle, QStringLiteral("second instance requested activation"));
                         const auto roots = engine.rootObjects();
                         for (QObject *root : roots) {
                             if (auto *window = qobject_cast<QQuickWindow *>(root)) {
                                 window->show();
                                 window->raise();
                                 window->requestActivate();
                                 break;
                             }
                         }
                     });

    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app,
        []() {
            MH_ERROR(App, QStringLiteral("QML root object creation failed"));
            QCoreApplication::exit(2);
        },
        Qt::QueuedConnection);

    // 退出前收尾：先落盘播放进度（晚于下面的 shutdown 就写不进数据库了），
    // 再持久化偏好与窗口几何、关闭数据库
    QObject::connect(&app, &QGuiApplication::aboutToQuit, &appState, [&appState] {
        PlayerBridge::flushPendingProgress();
        // 先解绑系统媒体会话：进程退出后系统面板不该还挂着一条点不动的媒体
        MediaSession::instance().detach();
        appState.shutdown();
    });

    engine.loadFromModule("MyHub", "Main");

    if (engine.rootObjects().isEmpty())
        return -1;

    // 系统媒体会话（PC-602）要绑定到具体窗口：SMTC 的 GetForWindow 需要 HWND，
    // 所以只能等根窗口建好之后再接。平台没有后端时这里会静默降级。
    if (auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().constFirst())) {
        MediaSession::instance().attachWindow(window);
    }

    return app.exec();
}
