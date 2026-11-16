#pragma once

#include "core/storage/FileEntry.h"

#include <QString>

namespace myhub {

/**
 * 目录排序与「同目录下一个」（§3.1 排序偏好、§4.6 连续播放推荐）。
 *
 * 抽成纯逻辑而不是留在 `BrowseDirectoryModel` 里，是因为「下一个」必须与浏览页
 * **完全同一套顺序**：用户在目录里把顺序调成「按时间倒序」，播完后的推荐就得顺着
 * 那个顺序走。两份实现早晚漂移，所以只留一份。
 */
class DirectorySort
{
public:
    /**
     * 原地排序。
     *
     * 规则：目录恒在文件之前；`sortKey` 取 `name` / `size` / `time`，
     * 主键相同（或未知键）时回退自然排序（`第2集` 在 `第10集` 之前）。
     */
    static void sort(FileEntryList &entries, const QString &sortKey, bool ascending);

    /**
     * 播完该接哪个（§4.6）。
     *
     * - **只认同类型**：视频接视频、音频接音频；跨类型（视频播完推小说）不算「连续」
     * - **只往后找，不回绕**：目录末项播完就给出空结果，交回 UI 决定怎么收场
     * - `currentPath` 不在列表里 / 当前项不是音视频 → 返回无效条目
     *
     * @param entries     该目录的全部条目（顺序不限，内部按 `sortKey`/`ascending` 重排）
     * @param currentPath 当前播放条目的路径
     */
    static FileEntry nextSibling(const FileEntryList &entries, const QString &currentPath,
                                 const QString &sortKey, bool ascending);

    /**
     * 读完这本该接哪本（§5 阅读器的「下一本」推荐）。
     *
     * 规则与 `nextSibling` 同源（只往后找、不回绕、跟随目录排序偏好），
     * 但「同类」的判定不同：**书按内容归类，不按扩展名归类**。
     * 同一目录里 `第2卷.txt` 与 `第2卷.epub` 是同一本书的两种格式，
     * 夹在中间的封面图 / 字幕 / 视频都不该被推上来。
     *
     * @param entries     该目录的全部条目（顺序不限，内部按 `sortKey`/`ascending` 重排）
     * @param currentPath 当前正在读的路径
     */
    static FileEntry nextBook(const FileEntryList &entries, const QString &currentPath,
                              const QString &sortKey, bool ascending);
};

} // namespace myhub
