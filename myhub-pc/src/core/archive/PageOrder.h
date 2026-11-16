#pragma once

#include <QString>
#include <QStringList>
#include <QVector>

namespace myhub {

/**
 * 漫画页序规则（zip / rar 共用，PC-207）。
 *
 * 为什么单独抽出来：cbz 走 `RangeZipReader`（中央目录），cbr 走 `ArchiveReader`
 * （libarchive），两条解包路径的底层结构完全不同，但**哪些条目算一页、页与页的先后**
 * 必须完全一致 —— 否则同一本书换个压缩格式就翻页错乱，或者封面和第一页对不上。
 *
 * 规则：
 *   - 目录条目不算页；
 *   - `__MACOSX/` 下的资源叉、`._xxx` 隐藏文件不算页；
 *   - 只认图片后缀（jpg/jpeg/png/webp/gif/bmp/avif/jxl）；
 *   - 页序按**页名自然排序**（page2 在 page10 之前），不看打包顺序。
 */
namespace pageorder {

/// 该条目算不算一页（`name` 是包含子目录的全名）
bool isPageName(const QString &name);

/// 从全部条目名里挑出页并按自然排序返回下标；`names` 的顺序即底层条目顺序
QVector<int> sortedPageIndexes(const QStringList &names);

} // namespace pageorder

} // namespace myhub
