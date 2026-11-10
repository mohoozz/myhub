#include "AppSettings.h"
#include "../utils/AppPaths.h"

#include <QDateTime>
#include <QRect>
#include <QSettings>
#include <QVariantMap>

namespace myhub {

namespace {
// 键名常量——与 iOS 端 UserDefaults 对齐（需求文档 §5.4）
constexpr auto kThemeMode = "app.themeMode";
constexpr auto kSortKey = "browse.sortKey";
constexpr auto kSortAscending = "browse.sortAscending";
constexpr auto kViewMode = "browse.viewMode";
constexpr auto kFileNameLines = "browse.fileNameLines";
constexpr auto kOpenOnSingleClick = "browse.openOnSingleClick";
constexpr auto kSortPreferences = "browse.sortPreferences.v1";
constexpr auto kCacheTotalLimitMB = "cache.totalLimitMB";
constexpr auto kContentCaching = "cache.contentCachingEnabled";
constexpr auto kTrashRetentionDays = "trash.retentionDays";
constexpr auto kConnectionTestStates = "connectionTestStates.v1";
constexpr auto kWindowBounds = "window.bounds";
constexpr auto kWindowMaximized = "window.maximized";
constexpr auto kSidebarCollapsed = "window.sidebarCollapsed";

constexpr int kMaxSortPreferences = 500; // LRU 上限（§3.1）
} // namespace

AppSettings::AppSettings(QObject *parent)
    : QObject(parent)
{}

AppSettings::~AppSettings()
{
    if (m_settings) {
        m_settings->sync();
        delete m_settings;
    }
}

AppSettings &AppSettings::instance()
{
    static AppSettings s_instance;
    return s_instance;
}

void AppSettings::initialize()
{
    if (m_settings)
        return;
    AppPaths::ensureDir(AppPaths::dataDir());
    // 显式指定 INI 文件路径，避免注册表后端导致无法随配置导出
    m_settings = new QSettings(AppPaths::settingsFile(), QSettings::IniFormat);
}

void AppSettings::sync()
{
    if (m_settings)
        m_settings->sync();
}

QVariant AppSettings::value(const QString &key, const QVariant &defaultValue) const
{
    return m_settings ? m_settings->value(key, defaultValue) : defaultValue;
}

void AppSettings::setValue(const QString &key, const QVariant &v)
{
    if (!m_settings)
        return;
    if (m_settings->value(key) == v)
        return;
    m_settings->setValue(key, v);
    emit settingChanged(key);
}

bool AppSettings::contains(const QString &key) const
{
    return m_settings && m_settings->contains(key);
}

void AppSettings::remove(const QString &key)
{
    if (m_settings) {
        m_settings->remove(key);
        emit settingChanged(key);
    }
}

// ---------------------------------------------------------------- 外观
QString AppSettings::themeMode() const
{
    return value(QLatin1String(kThemeMode), QStringLiteral("auto")).toString();
}

void AppSettings::setThemeMode(const QString &v)
{
    if (themeMode() == v)
        return;
    setValue(QLatin1String(kThemeMode), v);
    emit themeModeChanged();
}

// ---------------------------------------------------------------- 浏览
QString AppSettings::sortKey() const
{
    return value(QLatin1String(kSortKey), QStringLiteral("name")).toString();
}

void AppSettings::setSortKey(const QString &v)
{
    if (sortKey() == v)
        return;
    setValue(QLatin1String(kSortKey), v);
    emit sortKeyChanged();
}

bool AppSettings::sortAscending() const
{
    return value(QLatin1String(kSortAscending), true).toBool();
}

void AppSettings::setSortAscending(bool v)
{
    if (sortAscending() == v)
        return;
    setValue(QLatin1String(kSortAscending), v);
    emit sortAscendingChanged();
}

QString AppSettings::viewMode() const
{
    return value(QLatin1String(kViewMode), QStringLiteral("grid")).toString();
}

void AppSettings::setViewMode(const QString &v)
{
    if (viewMode() == v)
        return;
    setValue(QLatin1String(kViewMode), v);
    emit viewModeChanged();
}

int AppSettings::fileNameLines() const
{
    return qBound(1, value(QLatin1String(kFileNameLines), 3).toInt(), 5);
}

void AppSettings::setFileNameLines(int v)
{
    v = qBound(1, v, 5);
    if (fileNameLines() == v)
        return;
    setValue(QLatin1String(kFileNameLines), v);
    emit fileNameLinesChanged();
}

bool AppSettings::openOnSingleClick() const
{
    return value(QLatin1String(kOpenOnSingleClick), false).toBool();
}

void AppSettings::setOpenOnSingleClick(bool v)
{
    if (openOnSingleClick() == v)
        return;
    setValue(QLatin1String(kOpenOnSingleClick), v);
    emit openOnSingleClickChanged();
}

// ---------------------------------------------------------------- 缓存
int AppSettings::cacheTotalLimitMB() const
{
    return value(QLatin1String(kCacheTotalLimitMB), 2048).toInt();
}

void AppSettings::setCacheTotalLimitMB(int v)
{
    v = qMax(128, v);
    if (cacheTotalLimitMB() == v)
        return;
    setValue(QLatin1String(kCacheTotalLimitMB), v);
    emit cacheTotalLimitMBChanged();
}

bool AppSettings::contentCachingEnabled() const
{
    return value(QLatin1String(kContentCaching), true).toBool();
}

void AppSettings::setContentCachingEnabled(bool v)
{
    if (contentCachingEnabled() == v)
        return;
    setValue(QLatin1String(kContentCaching), v);
    emit contentCachingEnabledChanged();
}

// ---------------------------------------------------------------- 回收站
int AppSettings::trashRetentionDays() const
{
    return qBound(1, value(QLatin1String(kTrashRetentionDays), 30).toInt(), 90);
}

void AppSettings::setTrashRetentionDays(int v)
{
    v = qBound(1, v, 90);
    if (trashRetentionDays() == v)
        return;
    setValue(QLatin1String(kTrashRetentionDays), v);
    emit trashRetentionDaysChanged();
}

// ------------------------------------------------- 每目录排序偏好
static QString sortPrefKey(const QString &connectionId, const QString &path)
{
    return connectionId + QLatin1Char('|') + path;
}

QVariantMap AppSettings::directorySortPreference(const QString &connectionId,
                                                 const QString &path) const
{
    const QVariantMap all = value(QLatin1String(kSortPreferences)).toMap();
    const QVariant entry = all.value(sortPrefKey(connectionId, path));
    if (!entry.isValid())
        return {}; // 无记录 → 调用方回落全局默认
    return entry.toMap();
}

void AppSettings::setDirectorySortPreference(const QString &connectionId, const QString &path,
                                             const QString &key, bool ascending)
{
    if (!m_settings)
        return;
    QVariantMap all = value(QLatin1String(kSortPreferences)).toMap();
    QVariantMap entry;
    entry.insert(QStringLiteral("key"), key);
    entry.insert(QStringLiteral("asc"), ascending);
    entry.insert(QStringLiteral("at"), QDateTime::currentSecsSinceEpoch());
    all.insert(sortPrefKey(connectionId, path), entry);
    m_settings->setValue(QLatin1String(kSortPreferences), all);
    pruneSortPreferences();
    emit settingChanged(QLatin1String(kSortPreferences));
}

void AppSettings::pruneSortPreferences()
{
    if (!m_settings)
        return;
    QVariantMap all = m_settings->value(QLatin1String(kSortPreferences)).toMap();
    if (all.size() <= kMaxSortPreferences)
        return;

    // 按访问时间升序淘汰最久未用者（LRU）
    QList<QPair<qint64, QString>> aged;
    aged.reserve(all.size());
    for (auto it = all.constBegin(); it != all.constEnd(); ++it)
        aged.append({it.value().toMap().value(QStringLiteral("at")).toLongLong(), it.key()});
    std::sort(aged.begin(), aged.end(),
              [](const auto &a, const auto &b) { return a.first < b.first; });

    int toRemove = all.size() - kMaxSortPreferences;
    for (int i = 0; i < toRemove && i < aged.size(); ++i)
        all.remove(aged.at(i).second);

    m_settings->setValue(QLatin1String(kSortPreferences), all);
}

// ------------------------------------------------- 连接测试状态
QVariantMap AppSettings::connectionTestState(const QString &connectionId) const
{
    const QVariantMap all = value(QLatin1String(kConnectionTestStates)).toMap();
    return all.value(connectionId).toMap();
}

void AppSettings::setConnectionTestState(const QString &connectionId, bool reachable,
                                         const QString &scope, const QString &message)
{
    if (!m_settings)
        return;
    QVariantMap all = value(QLatin1String(kConnectionTestStates)).toMap();
    QVariantMap entry;
    entry.insert(QStringLiteral("reachable"), reachable);
    entry.insert(QStringLiteral("scope"), scope); // internal / external / unknown
    entry.insert(QStringLiteral("message"), message);
    entry.insert(QStringLiteral("at"), QDateTime::currentSecsSinceEpoch());
    all.insert(connectionId, entry);
    m_settings->setValue(QLatin1String(kConnectionTestStates), all);
    emit settingChanged(QLatin1String(kConnectionTestStates));
}

void AppSettings::clearConnectionTestState(const QString &connectionId)
{
    if (!m_settings)
        return;
    QVariantMap all = value(QLatin1String(kConnectionTestStates)).toMap();
    if (all.remove(connectionId) > 0) {
        m_settings->setValue(QLatin1String(kConnectionTestStates), all);
        emit settingChanged(QLatin1String(kConnectionTestStates));
    }
}

// ---------------------------------------------------------------- 窗口
QRect AppSettings::windowBounds() const
{
    return value(QLatin1String(kWindowBounds)).toRect();
}

void AppSettings::setWindowBounds(const QRect &r)
{
    setValue(QLatin1String(kWindowBounds), r);
}

bool AppSettings::windowMaximized() const
{
    return value(QLatin1String(kWindowMaximized), false).toBool();
}

void AppSettings::setWindowMaximized(bool v)
{
    setValue(QLatin1String(kWindowMaximized), v);
}

bool AppSettings::sidebarCollapsed() const
{
    return value(QLatin1String(kSidebarCollapsed), false).toBool();
}

void AppSettings::setSidebarCollapsed(bool v)
{
    setValue(QLatin1String(kSidebarCollapsed), v);
}

} // namespace myhub
