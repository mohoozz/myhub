#pragma once

#include <QList>
#include <QObject>
#include <QString>
#include <QStringList>

namespace myhub {

/**
 * 一条收藏（`favorite` 表的一行，与 iOS 端同构）。
 *
 * 表里只存「定位信息 + 收藏当时的类型/大小」：名称由路径推导，
 * 封面由 `CoverService` 按 `(connectionId, filePath)` 现取 ——
 * 收藏页与浏览页于是天然显示同一张封面。
 */
struct FavoriteRecord
{
    QString connectionId;
    QString filePath;
    QString
        mediaType; ///< MediaType::badgeId：folder / video / audio / novel / comic / image / text / file
    qint64 size = 0; ///< 收藏当时的大小（未知为 0）
    qint64 createdAt = 0;

    bool isDir() const { return mediaType == QStringLiteral("folder"); }
    bool isValid() const { return !connectionId.isEmpty() && !filePath.isEmpty(); }
};

/**
 * 收藏仓库（PC-107）。
 *
 * 唯一数据源就是 `favorite` 表：**不做内存镜像**（多写入点 + 多窗口会让镜像过期）。
 * 唯一例外是 `FavoritesBridge` 里的键集缓存 —— 它只缓存「是否收藏」这一个布尔，
 * 且由本类的 `favoriteChanged` 驱动增删，不会出现内容层面的过期。
 *
 * 写入语义：`(connectionID, filePath)` 唯一，重复收藏只更新同一行（不刷新收藏时间）。
 */
class FavoriteRepository : public QObject
{
    Q_OBJECT
public:
    static FavoriteRepository &instance();

    /// 全部收藏，按收藏时间倒序（收藏页直接消费）
    QList<FavoriteRecord> list() const;

    /// 全部键（`connectionId\nfilePath`），供启动时一次性预载
    QStringList keys() const;

    bool contains(const QString &connectionId, const QString &filePath) const;

    /// 新增收藏；已存在时只刷新类型/大小，保留原收藏时间
    bool add(const FavoriteRecord &record);

    /// 取消收藏
    bool remove(const QString &connectionId, const QString &filePath);

    /**
     * 切换收藏状态（浏览页星标）。
     * @param nowFavorite 输出切换后的状态
     */
    bool toggle(const FavoriteRecord &record, bool *nowFavorite = nullptr);

    /**
     * 删除文件/目录后清理收藏（连同子树的收藏一起清掉）。
     * @return 受影响的条数
     */
    int removeSubtree(const QString &connectionId, const QString &path);

    /**
     * 重命名 / 移动后同步收藏路径（目录则连同子树前缀一起改写）。
     * @return 受影响的条数
     */
    int renamePath(const QString &connectionId, const QString &oldPath, const QString &newPath);

    int count() const;

signals:
    /// 某条收藏变化：favorite = true 收藏 / false 取消
    void favoriteChanged(const QString &connectionId, const QString &filePath, bool favorite);

private:
    explicit FavoriteRepository(QObject *parent = nullptr);
    ~FavoriteRepository() override;
    Q_DISABLE_COPY_MOVE(FavoriteRepository)
};

} // namespace myhub
