#include "SettingsBridge.h"

#include "core/preferences/AppSettings.h"

namespace myhub {

SettingsBridge::SettingsBridge(QObject *parent)
    : QObject(parent)
{
    auto &s = AppSettings::instance();

    // 转发底层信号，保证 QML 绑定即时刷新（§14.16）
    connect(&s, &AppSettings::viewModeChanged, this, &SettingsBridge::viewModeChanged);
    connect(&s, &AppSettings::fileNameLinesChanged, this, &SettingsBridge::fileNameLinesChanged);
    connect(&s, &AppSettings::openOnSingleClickChanged, this,
            &SettingsBridge::openOnSingleClickChanged);
    connect(&s, &AppSettings::sortKeyChanged, this, &SettingsBridge::sortKeyChanged);
    connect(&s, &AppSettings::sortAscendingChanged, this, &SettingsBridge::sortAscendingChanged);
    connect(&s, &AppSettings::cacheTotalLimitMBChanged, this,
            &SettingsBridge::cacheTotalLimitMBChanged);
    connect(&s, &AppSettings::contentCachingEnabledChanged, this,
            &SettingsBridge::contentCachingEnabledChanged);
    connect(&s, &AppSettings::trashRetentionDaysChanged, this,
            &SettingsBridge::trashRetentionDaysChanged);
}

SettingsBridge *SettingsBridge::create(QQmlEngine *engine, QJSEngine *)
{
    // 由引擎持有生命周期
    return new SettingsBridge(engine);
}

QString SettingsBridge::viewMode() const
{
    return AppSettings::instance().viewMode();
}
void SettingsBridge::setViewMode(const QString &v)
{
    AppSettings::instance().setViewMode(v);
}

int SettingsBridge::fileNameLines() const
{
    return AppSettings::instance().fileNameLines();
}
void SettingsBridge::setFileNameLines(int v)
{
    AppSettings::instance().setFileNameLines(v);
}

bool SettingsBridge::openOnSingleClick() const
{
    return AppSettings::instance().openOnSingleClick();
}
void SettingsBridge::setOpenOnSingleClick(bool v)
{
    AppSettings::instance().setOpenOnSingleClick(v);
}

QString SettingsBridge::sortKey() const
{
    return AppSettings::instance().sortKey();
}
void SettingsBridge::setSortKey(const QString &v)
{
    AppSettings::instance().setSortKey(v);
}

bool SettingsBridge::sortAscending() const
{
    return AppSettings::instance().sortAscending();
}
void SettingsBridge::setSortAscending(bool v)
{
    AppSettings::instance().setSortAscending(v);
}

int SettingsBridge::cacheTotalLimitMB() const
{
    return AppSettings::instance().cacheTotalLimitMB();
}
void SettingsBridge::setCacheTotalLimitMB(int v)
{
    AppSettings::instance().setCacheTotalLimitMB(v);
}

bool SettingsBridge::contentCachingEnabled() const
{
    return AppSettings::instance().contentCachingEnabled();
}
void SettingsBridge::setContentCachingEnabled(bool v)
{
    AppSettings::instance().setContentCachingEnabled(v);
}

int SettingsBridge::trashRetentionDays() const
{
    return AppSettings::instance().trashRetentionDays();
}
void SettingsBridge::setTrashRetentionDays(int v)
{
    AppSettings::instance().setTrashRetentionDays(v);
}

QVariant SettingsBridge::value(const QString &key, const QVariant &defaultValue) const
{
    return AppSettings::instance().value(key, defaultValue);
}

void SettingsBridge::setValue(const QString &key, const QVariant &value)
{
    AppSettings::instance().setValue(key, value);
}

} // namespace myhub
