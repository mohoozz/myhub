#pragma once

#include "core/storage/FileEntry.h"

#include <QString>

namespace myhub {

/**
 * 「这个文件是不是漫画」的判定与结论缓存（需求文档 §6 `ComicDetector` ③）。
 *
 * 判定分两路，**代价差着几个数量级**，所以要分开对待：
 *
 *   · 扩展名：cbz / zip / cbr / rar 直接算漫画包，一次字符串比较就能定；
 *   · 内容：epub 到底是图集还是文字书，要看 OPF 的 spine（`EpubBook::imageOnly()`）——
 *     远程文件要先 stat 到长度，再读 zip 尾部 → 中央目录 → container.xml → OPF，
 *     大约 4 次 Range 请求。
 *
 * 本类**绝不自己去开文件**。原因很直接：列目录时 QML 每一行都会问一次类型，
 * 一个目录里十几个 epub 各跑一遍 `EpubBook::load()`，滚动会直接卡死。
 *
 * 结论由真正读过 OPF 的地方回写（`CoverService` 取封面跑过同一个 `load()`、
 * `NovelBridge` 打开 epub、`ComicBridge` 探测图集），这里只负责收下并记住。
 * 于是「第二次列目录」起徽标是零成本的。
 *
 * 未命中一律回答「不知道」，不猜：猜错要么让文字书顶着漫画徽标，
 * 要么把图集推进小说阅读器开出空白页。
 *
 * 缓存以「连接源 + 路径」为键、**指纹（fileSize + modTime，秒）一并存下**。
 * 与 `ComicPageStore` / `EpubMetaStore` 同一套约定：文件被换过，旧结论自然失效。
 */
class ComicDetector
{
public:
    /// 扩展名判定：cbz / zip / cbr / rar（`zip`/`rar` 是同一话的另一种打包）
    static bool isComicArchivePath(const QString &path);

    /// 有没有「可能是漫画」：扩展名合集再加上 `.epub`（要查缓存才知道）
    static bool couldBeComic(const QString &path);

    /**
     * 查结论。**只读内存**，O(1)，不发请求、不查库，可以放心在 `data()` 里调用。
     *
     * 扩展名能定的（cbz/zip/cbr/rar）直接返回 true，不必进缓存。
     * epub 只有命中缓存**且指纹一致**才算数；否则返回 false（= 还不知道）。
     *
     * @param isComic 出参：返回 true 时给出结论
     * @return 是否**已经知道**结论
     */
    static bool known(const QString &connectionId, const FileEntry &entry, bool *isComic);

    /**
     * 列目录后预热：把该目录里 epub 的结论一次搬进内存。
     *
     * 语义上是「查库」，所以只在 `applyEntries` 这种每目录一次的地方调用，
     * 不要放进 `data()`。
     */
    static void prime(const QString &connectionId, const FileEntryList &entries);

    /**
     * 记录结论。由真正读过 OPF 的调用方使用。
     *
     * 内存与库都写：进程内的下一次列目录立刻生效，重启后靠库。
     * 数据库没就绪时只写内存，不影响本次会话。
     *
     * @param modTimeSecs **秒**级 mtime（与 `FileEntry::fingerprint()` 同一口径）
     */
    static bool remember(const QString &connectionId, const QString &path, bool isComic,
                         qint64 fileSize, qint64 modTimeSecs);

    /// 毫秒 → 秒的口径换算（`NovelBridge` / `ComicBridge` 的 `m_modTime` 是毫秒）
    static qint64 secondsFromMillis(qint64 millis);

    static void forget(const QString &connectionId, const QString &path);
    static int count();

    /// 测试用：只清内存镜像，不动库（模拟「重启后再列目录」）
    static void resetMemory();
};

} // namespace myhub
