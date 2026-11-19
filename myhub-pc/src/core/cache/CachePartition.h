#pragma once

#include <QList>
#include <QString>

namespace myhub {

/**
 * 缓存分区定义与配额（需求文档 §5.5）。
 *
 * 每个分区在 `AppPaths::cacheDir()` 下占一个一级目录，配额按总上限 `T` 换算成
 * `max(quotaBaseMB, T / quotaDivisor)`。分区各自设限防的是「单个分区吃光整块盘」，
 * 总和仍由 `CacheStore` 的跨分区兜底压回 `T`。
 *
 * 纪律：分区名与配额**只在这里定义一份**。以前 `"stream"` / `"comic"` / `"comic-packs"`
 * 散落在各服务里，而 `AppPaths::initializeAll()` 又按另一套名字建了 4 个永远为空的目录，
 * 两边长期对不上。
 */
struct CachePartition
{
    QString dir;      ///< 物理目录名（`cacheDir()` 下一级）
    QString label;    ///< 展示名（日志 / 设置页）
    int quotaBaseMB;  ///< 配额下限（MB）
    int quotaDivisor; ///< 配额 = max(quotaBaseMB, T / quotaDivisor)
    /// 分区自己管淘汰：只统计占用，不代删。音视频分片要看播放点淘汰（SegmentCache），
    /// 按 mtime 删会把正在播的分片挤掉
    bool selfManaged;
};

/// 分区名常量：服务端引用这里，别再写字面量
namespace CacheDirs {
inline constexpr auto MediaSegments = "mediaSegments";
inline constexpr auto ComicPages = "comicPages";
inline constexpr auto Thumbnails = "thumbnails";
/// epub 正文插图的本地快照（`NovelImageStore`）：图片只能以文件形式交给 QML
inline constexpr auto NovelImages = "novelImages";
inline constexpr auto DirectoryListings = "directoryListings";
} // namespace CacheDirs

class CachePartitions
{
public:
    /**
     * 全部分区（顺序即展示顺序）。
     *
     * 小说章节与索引不在表里：桌面端它们落在 sqlite（`novelChapter` / `novelIndex`），
     * 不占文件缓存，按行数修剪，跟文件配额是两套机制。
     */
    static const QList<CachePartition> &all();
    static const CachePartition *find(const QString &dir);
    /// 分区配额字节数：`max(quotaBaseMB, T / quotaDivisor)`
    static qint64 quotaBytes(const CachePartition &partition, qint64 totalLimitBytes);
    /// 总上限（字节），来自设置 `cache.totalLimitMB`，下限 128MB
    static qint64 totalLimitBytes();
    /// 分区物理目录（`AppPaths::cachePartition(dir)`）
    static QString path(const QString &dir);
};

} // namespace myhub
