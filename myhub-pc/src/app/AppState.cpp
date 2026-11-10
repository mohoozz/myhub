#include "AppState.h"

#include "features/connections/ConnectionStore.h"
#include "features/favorites/FavoritesBridge.h"

#include "core/database/AppDatabase.h"
#include "core/preferences/AppSettings.h"
#include "core/utils/AppLogger.h"
#include "core/utils/AppPaths.h"
#include "core/utils/CrashReporter.h"

#include <QTimer>

namespace myhub {
namespace {

/// 进程级唯一实例（退出时随进程回收，不做析构期清理以免与 QML 引擎竞争）
AppState *g_instance = nullptr;

} // namespace

AppState::AppState(QObject *parent)
    : QObject(parent)
{
    if (!g_instance)
        g_instance = this;
}

AppState &AppState::instance()
{
    if (!g_instance)
        g_instance = new AppState(nullptr);
    return *g_instance;
}

AppState *AppState::create(QQmlEngine *engine, QJSEngine *)
{
    AppState *state = &AppState::instance();
    // 生命周期归 main()：引擎销毁时不得删除它
    engine->setObjectOwnership(state, QQmlEngine::CppOwnership);
    return state;
}

QString AppState::version() const
{
    return QLatin1String(MYHUB_VERSION);
}

QString AppState::statusText() const
{
    switch (m_phase) {
    case Starting:
        return tr("正在启动…");
    case OpeningDatabase:
        return tr("正在准备数据…");
    case LoadingStores:
        return tr("正在载入配置…");
    case ProbingConnections:
        return tr("正在检测连接源…");
    case Ready:
        return QString();
    case Failed:
        return tr("启动失败");
    }
    return {};
}

void AppState::setPhase(Phase p)
{
    if (m_phase == p)
        return;
    m_phase = p;
    emit phaseChanged();
}

void AppState::bootstrap()
{
    // 1) 目录 + 日志 + 崩溃捕获（必须最先，后续问题才有记录）
    AppPaths::initializeAll();
    AppLogger::instance().initialize();
    CrashReporter::install();

    m_hasCrashReport = CrashReporter::hasPendingReport();
    if (m_hasCrashReport)
        MH_WARN(Lifecycle, QStringLiteral("previous session left a crash report"));

    // 2) 偏好
    AppSettings::instance().initialize();

    // 3) 数据库（同步打开并迁移）
    setPhase(OpeningDatabase);
    auto &db = AppDatabase::instance();

    // Store 必须等数据库就绪后再装载
    connect(
        &db, &AppDatabase::ready, this,
        [this] {
            setPhase(LoadingStores);
            ConnectionStore::instance().load();
            // 收藏键集预载：冷启动后浏览页首批行的星标必须是对的（PC-107 双向同步）
            FavoritesBridge::instance().preload();
            // 让 UI 先渲染出来，再做网络探测，避免拖慢首屏
            QTimer::singleShot(0, this, &AppState::continueBoot);
        },
        Qt::SingleShotConnection);

    if (!db.open()) {
        MH_ERROR(Lifecycle, QStringLiteral("database open failed, running degraded"));
        setPhase(Failed);
        emit bootFailed(tr("数据库打开失败，请检查数据目录权限"));
        return;
    }
}

void AppState::continueBoot()
{
    // 4) 连接源启动探测（内外网竞速并锁定地址）
    setPhase(ProbingConnections);
    ConnectionStore::instance().probeAllOnStartup();

    // 探测为异步，不阻塞可交互状态
    setPhase(Ready);
    MH_INFO(Lifecycle, QStringLiteral("app ready"));
}

QString AppState::crashReport() const
{
    return CrashReporter::readReport();
}

void AppState::clearCrashReport()
{
    CrashReporter::clearReport();
    m_hasCrashReport = false;
    emit phaseChanged();
}

QStringList AppState::logTail(int lines) const
{
    return AppLogger::instance().tail(lines);
}

void AppState::clearLogs()
{
    AppLogger::instance().clear();
}

void AppState::shutdown()
{
    MH_INFO(Lifecycle, QStringLiteral("shutting down"));
    AppSettings::instance().sync();
    AppDatabase::instance().close();
    AppLogger::instance().shutdown();
}

} // namespace myhub
