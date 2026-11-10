#include "FavoritesBridge.h"

#include <QJSEngine>

#include "features/connections/ConnectionStore.h"

#include "core/favorites/FavoriteRepository.h"
#include "core/storage/StoragePath.h"

namespace myhub {
namespace {

QString encodeKey(const QString &connectionId, const QString &filePath)
{
    return connectionId + QLatin1Char('\n') + filePath;
}

} // namespace

FavoritesBridge &FavoritesBridge::instance()
{
    static FavoritesBridge s_instance;
    return s_instance;
}

FavoritesBridge *FavoritesBridge::create(QQmlEngine *, QJSEngine *)
{
    QJSEngine::setObjectOwnership(&instance(), QJSEngine::CppOwnership);
    return &instance();
}

// 构造函数私有且无默认参数：QML 侧只能拿到 create() 返回的那一个实例
// （否则 instance() 与 QML 隐式 new 出来的对象会是两个，键集不同步）
FavoritesBridge::FavoritesBridge(QObject *parent)
    : QObject(parent)
{
    connect(&FavoriteRepository::instance(), &FavoriteRepository::favoriteChanged, this,
            &FavoritesBridge::onFavoriteChanged);

    // 删除连接源时数据库按外键 CASCADE 清掉它的收藏，这类删除不会走仓库的信号；
    // 连接源变动后重建键集即可与表对齐（收藏量在几十条量级，代价可忽略）
    connect(&ConnectionStore::instance(), &ConnectionStore::connectionsChanged, this,
            &FavoritesBridge::preload);
}

FavoritesBridge::~FavoritesBridge() = default;

void FavoritesBridge::preload()
{
    m_keys.clear();
    const QStringList keys = FavoriteRepository::instance().keys();
    for (const QString &key : keys) {
        m_keys.insert(key);
    }
    ++m_revision;
    emit revisionChanged();
}

bool FavoritesBridge::isFavorite(const QString &connectionId, const QString &filePath) const
{
    if (connectionId.isEmpty() || filePath.isEmpty()) {
        return false;
    }
    return m_keys.contains(encodeKey(connectionId, filePath));
}

bool FavoritesBridge::toggle(const QString &connectionId, const QString &filePath,
                             const QString &mediaType, qint64 size)
{
    if (connectionId.isEmpty() || filePath.isEmpty()) {
        return false;
    }

    FavoriteRecord record;
    record.connectionId = connectionId;
    record.filePath = StoragePath::normalize(filePath);
    record.mediaType = mediaType.isEmpty() ? QStringLiteral("file") : mediaType;
    record.size = size;

    bool nowFavorite = false;
    // 仓库的 favoriteChanged 会回到 onFavoriteChanged 更新键集并广播 revision
    FavoriteRepository::instance().toggle(record, &nowFavorite);
    return nowFavorite;
}

bool FavoritesBridge::remove(const QString &connectionId, const QString &filePath)
{
    if (connectionId.isEmpty() || filePath.isEmpty()) {
        return false;
    }
    return FavoriteRepository::instance().remove(connectionId, StoragePath::normalize(filePath));
}

void FavoritesBridge::onFavoriteChanged(const QString &connectionId, const QString &filePath,
                                        bool favorite)
{
    const QString key = encodeKey(connectionId, filePath);
    const bool had = m_keys.contains(key);
    if (favorite == had) {
        // 已收藏又报「收藏」：内容没变，但仍是有效事件（例如重复 add），不广播
        return;
    }

    if (favorite) {
        m_keys.insert(key);
    } else {
        m_keys.remove(key);
    }

    ++m_revision;
    emit revisionChanged();
}

} // namespace myhub
