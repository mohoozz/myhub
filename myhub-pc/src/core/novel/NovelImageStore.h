#pragma once

#include <QByteArray>
#include <QString>

namespace myhub {

/**
 * epub 正文插图的**本地快照**（§5 小说章节缓存的文件侧对应）。
 *
 * 为什么必须有它：插图只存在 zip 里，而 QML 的图片只能吃本地文件路径。
 * 所以「取图」与「缓存」是同一个动作 —— 抽出来落一份快照，渲染层直接读快照。
 * 落到盘上之后：同一张图不用再解一次包，离线时读过的插图也还在。
 *
 * 键的构成（三层，缺一层就会串书）：
 *   - 连接源 + 路径 → 书级 key：同名的两本书不会互相覆盖；
 *   - 文件指纹（size + modTime）→ 换了书就是另一套快照，旧的自生自灭；
 *   - 插图条目名（zip 里的完整路径）→ 一章里多张图各占一份。
 *
 * 生命周期：文件落在 `CacheDirs::NovelImages` 分区，由 `CacheStore` 按分区配额 + LRU
 * 清理。删除/改名源文件时**不主动清**——文件名里带着旧 key / 旧指纹，从此再也取不到，
 * 等 LRU 收走即可（与漫画页缓存同一套做法，见 `ComicBridge::purgeStalePages`）。
 */
class NovelImageStore
{
public:
    /// 快照文件路径（不保证已存在）
    static QString pathFor(const QString &connectionId, const QString &path, qint64 fileSize,
                           qint64 modTimeMs, const QString &entry);

    /// 原子写入；失败只记日志并返回 false（插图丢了不该影响阅读）
    static bool save(const QString &filePath, const QByteArray &bytes);

    /// 命中即刷新 mtime：淘汰按 mtime 走，不刷新的话常看的书会先被清掉
    static void touch(const QString &filePath);

    /// 图快照所在分区目录（测试与日志用）
    static QString partitionDir();
};

} // namespace myhub
