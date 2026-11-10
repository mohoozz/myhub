#pragma once

#include <QHash>
#include <QList>
#include <QObject>
#include <QString>
#include <QVariantMap>

namespace myhub {

/**
 * 一条阅读/播放进度（`readingProgress` 表的一行）。
 *
 * `progress` 是类型专属负载，视频/音频用 `positionMs` + `durationMs`，
 * 小说用锚点/章节索引，漫画用页码 —— 各模块只管自己那几个键，
 * 通用列（percent / finished / updatedAt）由「正在阅读」首页统一消费（PC-209）。
 */
struct ProgressRecord
{
    QString connectionId;
    QString path;
    QString mediaType; ///< video / audio / novel / comic
    QString title;
    QString cover;
    QVariantMap progress;
    double percent = 0.0;
    bool finished = false;
    qint64 updatedAt = 0; ///< epoch ms

    qint64 positionMs() const { return progress.value(QStringLiteral("positionMs")).toLongLong(); }
    qint64 durationMs() const { return progress.value(QStringLiteral("durationMs")).toLongLong(); }
    bool isValid() const { return !connectionId.isEmpty() && !path.isEmpty(); }
};

/**
 * 状态角标用的进度摘要（只有画环需要的两个字段）。
 *
 * 与完整 `ProgressRecord` 分开：浏览页一次要问几百上千行，
 * 不需要 mediaType / title / cover / 锚点负载。
 */
struct ProgressBrief
{
    double percent = 0.0;
    bool finished = false;
};

/**
 * 阅读进度仓库（PC-209）。
 *
 * 唯一数据源就是数据库表 `readingProgress`，**不做内存镜像**：
 * 消费方（首页列表 / 续播查询）都是按需读写，一次索引查询的开销远小于
 * 维护缓存一致性的代价（多窗口、多写入点都会让镜像过期）。
 *
 * 写入语义：`(connectionID, filePath)` 唯一，重复上报只更新同一行，
 * 因此「从 A 切到 B 再切回 A」不会产生多条记录。
 */
class ProgressRepository : public QObject
{
    Q_OBJECT
public:
    static ProgressRepository &instance();

    /// 按连接源 + 路径查一条；无记录返回 false（out 不改动）
    bool find(const QString &connectionId, const QString &path, ProgressRecord *out) const;

    /// 最近更新的一批，供「正在阅读」首页
    QList<ProgressRecord> recent(int limit = 60) const;

    /**
     * 某连接源下**全部**记录的轻量摘要（一次查询，key = filePath）。
     *
     * 浏览页的「阅读进度」状态角标用它：目录里可能上万条，
     * 逐行 `find()` 就是上万次 SQL，不可接受；这里改成一次全量取回后本地查表。
     */
    QHash<QString, ProgressBrief> briefs(const QString &connectionId) const;

    /// 新增或覆盖同 (connectionId, path) 的记录；updatedAt 由本方法填当前时间
    bool upsert(ProgressRecord record);

    /// 删除一条记录（不影响源文件）
    bool remove(const QString &connectionId, const QString &path);

    /**
     * 删除某个路径**及其子树**的记录（删除目录时子孙记录一并清掉）。
     *
     * 文件操作联动阅读记录（§3.2）：删除成功后必须调用，
     * 否则「正在阅读」里会留下点开即失败的幽灵条目。
     * @return 受影响的记录条数
     */
    int removeSubtree(const QString &connectionId, const QString &path);

    /**
     * 重命名 / 移动后同步记录路径（目录则连同子孙记录的前缀一起改写）。
     *
     * 标题若仍是「原文件名推导值」（用户没改过），同步改成新文件名；
     * 否则（如 epub 元数据标题）保持不动。
     * @return 受影响的记录条数
     */
    int renamePath(const QString &connectionId, const QString &oldPath, const QString &newPath);

    /// 记录总数（诊断 / 空态判断）
    int count() const;

    /**
     * 续播起点：已完成或几乎播完的记录一律从头开始。
     *
     * 「几乎播完」的判定集中在本类（`isNearEnd`），写入侧与读取侧共用同一套阈值，
     * 不会出现「播放器认为没看完、首页显示已看完」的不一致。
     */
    static qint64 resumePositionMs(const ProgressRecord &record);

    /// 距结尾不足 3s 视为已看完（避免续播落在片尾、一进去就结束）
    static bool isNearEnd(qint64 positionMs, qint64 durationMs);

signals:
    /// 某条记录变化（写入或删除）—— 首页/收藏页据此刷新
    void progressChanged(const QString &connectionId, const QString &path);
    void progressRemoved(const QString &connectionId, const QString &path);

private:
    explicit ProgressRepository(QObject *parent = nullptr);
    ~ProgressRepository() override;
    Q_DISABLE_COPY_MOVE(ProgressRepository)
};

} // namespace myhub
