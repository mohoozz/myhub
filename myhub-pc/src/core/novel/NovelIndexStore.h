#pragma once

#include "core/novel/NovelIndex.h"

#include <QString>
#include <QVector>

namespace myhub {

/**
 * 分章索引缓存（`novelIndex` 表，§5.1 PC-202）。
 *
 * 索引是**可重建缓存**，不是权威数据：丢了顶多重扫一次，绝不能因此打不开书。
 * 因此这里没有「加载失败」这一说 —— 任何异常都退化成「缓存未命中」，
 * 上层重新走 `TxtIndexer`。
 *
 * 指纹命中判定复用 `NovelIndex::matchesFile`（大小相等 + 修改时间差 ≤2s），
 * 不用 hash：20MB 的书算一遍 CRC 的耗时和重扫章节差不多，白忙。
 *
 * `chaptersJSON` 与 iOS 端同构：元素 key 为 `title` / `startOffset` / `ruleID`，
 * 且**只有首章**带 `ruleID`（iOS 侧约定），规则漂移排查时按首章记录的规则复核。
 */
class NovelIndexStore
{
public:
    NovelIndexStore() = delete;

    /// 指纹命中则取出缓存并返回 true；未命中 / 文件已变 / 无记录一律 false
    static bool load(const QString &connectionId, const QString &path, qint64 fileSize,
                     qint64 modTimeMs, NovelIndex *out);

    /**
     * 不看指纹直接取（「先展示上次的目录，后台再重扫」）。
     *
     * 弱网下重扫可能要几十秒，有了这条路用户至少能立刻翻到上次那一章；
     * 重扫完成后再 `save()` 覆盖。
     */
    static bool find(const QString &connectionId, const QString &path, NovelIndex *out);

    /// 写入或覆盖同 (connectionId, path) 的索引
    static bool save(const QString &connectionId, const QString &path, const NovelIndex &index);

    static bool remove(const QString &connectionId, const QString &path);

    /// 删除目录时连同子孙索引一并清掉（否则重命名的旧路径会留下孤儿行）
    static int removeSubtree(const QString &connectionId, const QString &path);

    /// 重命名 / 移动后同步缓存路径（目录则连同子孙前缀一起改写）
    static int renamePath(const QString &connectionId, const QString &oldPath,
                          const QString &newPath);

    static int count();

    /// 章节数组 → JSON（与 iOS `ChapterInfo` 同 key、同语义）
    static QString encodeChapters(const NovelIndex &index);

    /// JSON → 章节数组；格式不对返回 false（调用方按「未命中」处理）
    static bool decodeChapters(const QString &json, QVector<NovelChapter> *out);
};

} // namespace myhub
