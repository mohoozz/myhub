#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QSet>
#include <QString>

class QQmlEngine;
class QJSEngine;

namespace myhub {

/**
 * 收藏的全局入口（PC-107 星标 / 双向同步）。
 *
 * 职责边界：
 *   - 写：转给 `FavoriteRepository`（唯一数据源仍是 `favorite` 表）
 *   - 读：`isFavorite` 走内存键集，供列表委托逐格绑定（不会每行一次 SQL）
 *   - 广播：任何来源（浏览页星标、收藏页取消、文件被删/改名）都会让 `revision` 自增，
 *     所有绑定在 `revision` 上的 UI 立刻重算 —— 这是「浏览页与收藏页双向实时同步」的实现方式
 *
 * 启动预载：`AppState` 在数据库就绪后调 `preload()`（冷启动时浏览页的首批行就有正确星标）。
 */
class FavoritesBridge : public QObject
{
    Q_OBJECT
    QML_NAMED_ELEMENT(Favorites)
    QML_SINGLETON

    /// 收藏集合的版本号：UI 把它写进绑定表达式即可获得刷新
    Q_PROPERTY(int revision READ revision NOTIFY revisionChanged)
    /// 收藏总数（侧边栏/页头计数）
    Q_PROPERTY(int count READ count NOTIFY revisionChanged)

public:
    static FavoritesBridge *create(QQmlEngine *, QJSEngine *);
    static FavoritesBridge &instance();

    int revision() const { return m_revision; }
    int count() const { return int(m_keys.size()); }

    /// 数据库就绪后调用一次；重复调用等价于重建键集
    void preload();

    Q_INVOKABLE bool isFavorite(const QString &connectionId, const QString &filePath) const;

    /**
     * 切换收藏（浏览页星标 / 收藏页取消）。
     * @param mediaType MediaType::badgeId（folder / video / …），收藏页据此选图标
     * @return 切换后的状态
     */
    Q_INVOKABLE bool toggle(const QString &connectionId, const QString &filePath,
                            const QString &mediaType = QString(), qint64 size = 0);

    /// 取消收藏（收藏页右键「取消收藏」）：不存在的键直接返回 false
    Q_INVOKABLE bool remove(const QString &connectionId, const QString &filePath);

signals:
    void revisionChanged();

private:
    explicit FavoritesBridge(QObject *parent = nullptr);
    ~FavoritesBridge() override;
    Q_DISABLE_COPY_MOVE(FavoritesBridge)

    void onFavoriteChanged(const QString &connectionId, const QString &filePath, bool favorite);

    QSet<QString> m_keys;
    int m_revision = 0;
};

} // namespace myhub
