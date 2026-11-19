#pragma once

#include <QString>
#include <QStringList>

namespace myhub {

/// 漫画阅读方向（双页模式下左右两页谁先谁后的依据）
enum class ComicDirection
{
    Unknown,     ///< 看不出来：交给调用方沿用当前值
    LeftToRight, ///< 从左向右（美漫 / 国漫 / 韩漫 / 条漫）
    RightToLeft, ///< 从右向左（日漫）
};

/**
 * 从书名（或压缩包名）与页名里猜阅读方向（PC-208「方向自动判定」）。
 *
 * 没有元数据可读：cbz 就是「一堆图片 + 一个名字」，漫画也没有统一的方向字段。
 * 所以这里只做**高置信度的弱判定**，命中不了就返回 `Unknown` —— 让用户的手动选择
 * 生效，比猜错方向更好（猜错的表现是整本读反，用户得先意识到再改）。
 *
 * 判定顺序（先命中先返回）：
 *   1. 显式写法：「右→左」「right-to-left」「RTL」这类，用户/发布者已经写明了；
 *   2. 假名（平假名 / 片假名 / 半角片假名）—— 日文作品，日漫从右向左；
 *   3. 日系标记：巻 / 話 / 同人 / 成年向 / 同人展会的 `(C99)` 标签；
 *   4. 中韩条漫标记：条漫 / webtoon / 国漫 / 韩漫 / 第 N 话（简体「话」是中文写法）。
 *
 * **书名优先于页名**：页名多半是 `001.jpg`，只有日文包才会出现假名；
 * 页名只用来补一刀，且最多看首尾各三页，不会为了判定去遍历整本。
 */
ComicDirection detectComicDirection(const QString &title, const QStringList &pageNames = {});

} // namespace myhub
