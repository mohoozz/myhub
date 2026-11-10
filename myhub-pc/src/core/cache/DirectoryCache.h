#pragma once

#include "../storage/FileEntry.h"

#include <QObject>
#include <QString>

namespace myhub {

/**
 * 目录列表本地缓存（§3.1）。
 *
 * 策略 stale-while-revalidate：先出缓存秒开，后台刷新覆盖。
 *
 * 纪律（iOS 实战经验）：
 *   - **刷新前不预删缓存**；刷新失败保留旧内容，不得清空列表
 *   - 异常响应**严禁**当作「空目录」写入缓存（PC-708）
 */
class DirectoryCache : public QObject
{
    Q_OBJECT
public:
    static DirectoryCache &instance();

    /// 读取缓存；miss 返回 false
    bool load(const QString &connectionId, const QString &path, FileEntryList *out) const;

    /// 写入缓存。entries 为空时需显式声明该目录确为空目录，避免异常响应写入假空
    void store(const QString &connectionId, const QString &path, const FileEntryList &entries,
               bool verifiedEmpty = false);

    /// 单个目录失效（仅在确认目录已变更时调用，如删除/移动成功后）
    void invalidate(const QString &connectionId, const QString &path);

    /// 某连接源的全部缓存失效（删除连接源时）
    void invalidateConnection(const QString &connectionId);

    void clearAll();

    /// 当前占用字节数（设置页缓存分区展示用）
    qint64 totalBytes() const;

    bool contains(const QString &connectionId, const QString &path) const;

private:
    explicit DirectoryCache(QObject *parent = nullptr);
    ~DirectoryCache() override;
    Q_DISABLE_COPY_MOVE(DirectoryCache)

    QString cacheFilePath(const QString &connectionId, const QString &path) const;

    struct Private;
    Private *d;
};

} // namespace myhub
