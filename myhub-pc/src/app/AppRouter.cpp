#include "AppRouter.h"

namespace myhub {

AppRouter::AppRouter(QObject *parent)
    : QObject(parent)
{}

void AppRouter::setCurrentModule(Module m)
{
    if (m_currentModule == m)
        return;
    m_currentModule = m;
    emit currentModuleChanged();
}

void AppRouter::select(Module m)
{
    if (m_currentModule == m) {
        // 重复点击 → 回到该模块起始页（§2.2.1）
        emit reselected(m);
        return;
    }
    setCurrentModule(m);
}

void AppRouter::selectByIndex(int index)
{
    if (index < 0 || index > Settings)
        return;
    select(static_cast<Module>(index));
}

QString AppRouter::moduleName(Module m) const
{
    switch (m) {
    case Reading:
        return tr("阅读");
    case Favorites:
        return tr("收藏");
    case Feed:
        return tr("动态");
    case Browse:
        return tr("浏览");
    case Browser:
        return tr("浏览器");
    case Settings:
        return tr("设置");
    }
    return {};
}

} // namespace myhub
