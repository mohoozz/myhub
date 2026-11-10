#include "BrowseController.h"

#include "core/preferences/AppSettings.h"
#include "core/storage/StorageAdapter.h"
#include "core/storage/StoragePath.h"
#include "features/connections/ConnectionStore.h"

namespace myhub {

namespace {
constexpr auto kLastPathPrefix = "browse.lastPath.";
}

BrowseController::BrowseController(QObject *parent)
    : QObject(parent)
{}

void BrowseController::openConnection(const QString &id)
{
    if (id.isEmpty())
        return;

    // 先取上次路径：下面的 connectionIdChanged 会让目录页重置到根目录并回写路径，
    // 之后再读就只剩 "/" 了（§3.1 进入连接源恢复上次路径）
    const QString restorePath = lastPath(id);

    m_connectionId = id;
    emit connectionIdChanged();

    emit navigationRequested(id, restorePath);
}

void BrowseController::backToConnections()
{
    if (m_connectionId.isEmpty())
        return;
    m_connectionId.clear();
    emit connectionIdChanged();
}

void BrowseController::navigateTo(const QString &id, const QString &path)
{
    if (id.isEmpty())
        return;

    const QString target = path.isEmpty() ? QStringLiteral("/") : path;
    if (m_connectionId != id) {
        m_connectionId = id;
        emit connectionIdChanged();
    }
    emit navigationRequested(id, target);
}

void BrowseController::reveal(const QString &id, const QString &filePath, bool isDir)
{
    if (id.isEmpty() || filePath.isEmpty())
        return;

    const QString target = StoragePath::normalize(filePath);
    if (target.isEmpty() || StoragePath::isRoot(target))
        return;

    // 目录定位到自己，文件定位到父目录（PC-109）
    const QString dirPath = isDir ? target : StoragePath::parent(target);

    m_reveal.insert(QStringLiteral("connectionId"), id);
    m_reveal.insert(QStringLiteral("filePath"), target);
    m_reveal.insert(QStringLiteral("dirPath"), dirPath);
    // 唯一 token：同一文件重复定位也要能重新触发（滚动 + 呼吸灯重来）
    m_reveal.insert(QStringLiteral("token"), QVariant::fromValue(++m_revealToken));
    emit revealChanged();
}

void BrowseController::clearReveal()
{
    if (m_reveal.isEmpty())
        return;
    m_reveal.clear();
    emit revealChanged();
}

void BrowseController::rememberPath(const QString &id, const QString &path)
{
    if (id.isEmpty())
        return;
    AppSettings::instance().setValue(QLatin1String(kLastPathPrefix) + id, path);
}

QString BrowseController::lastPath(const QString &id) const
{
    if (id.isEmpty())
        return QStringLiteral("/");
    return AppSettings::instance()
        .value(QLatin1String(kLastPathPrefix) + id, QStringLiteral("/"))
        .toString();
}

bool BrowseController::isCurrentConnectionLocal() const
{
    if (m_connectionId.isEmpty())
        return false;
    StorageError err;
    StorageAdapter *adapter = ConnectionStore::instance().adapterFor(m_connectionId, &err);
    return adapter && adapter->typeName() == QStringLiteral("local");
}

} // namespace myhub
