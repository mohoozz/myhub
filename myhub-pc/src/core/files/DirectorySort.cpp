#include "core/files/DirectorySort.h"

#include "core/storage/StoragePath.h"
#include "core/utils/MediaType.h"
#include "core/utils/NaturalSort.h"

#include <algorithm>
#include <functional>

namespace myhub {
namespace {

/// 「书」的判定：txt 与 epub 视为同类，换格式不该把连续阅读打断
bool isBookPath(const QString &path)
{
    const QString ext = StoragePath::extension(path);
    return ext == QLatin1String("txt") || ext == QLatin1String("epub");
}

/// 「漫画」的判定：cbz/cbr 只是 zip/rar 的别名，同一话两种打包算同类
bool isComicPath(const QString &path)
{
    return MediaType::isComicArchive(StoragePath::extension(path));
}

/**
 * 「下一个」的公共骨架：排序 → 定位当前项 → 只往后扫第一个匹配项。
 *
 * 当前项本身也得匹配：否则「在视频目录里点开一本 txt」会把后面的视频当成下一本。
 */
FileEntry nextMatching(const FileEntryList &entries, const QString &currentPath,
                       const QString &sortKey, bool ascending,
                       const std::function<bool(const FileEntry &)> &matches)
{
    if (currentPath.isEmpty())
        return {};

    FileEntryList sorted = entries;
    DirectorySort::sort(sorted, sortKey, ascending);

    int index = -1;
    for (int i = 0; i < sorted.size(); ++i) {
        if (sorted.at(i).path == currentPath) {
            index = i;
            break;
        }
    }
    if (index < 0 || !matches(sorted.at(index)))
        return {};

    for (int i = index + 1; i < sorted.size(); ++i) {
        const FileEntry &entry = sorted.at(i);
        if (entry.isDir)
            continue;
        if (matches(entry))
            return entry;
    }
    return {};
}

} // namespace

void DirectorySort::sort(FileEntryList &entries, const QString &sortKey, bool ascending)
{
    std::sort(entries.begin(), entries.end(),
              [sortKey, ascending](const FileEntry &a, const FileEntry &b) {
                  if (a.isDir != b.isDir)
                      return a.isDir;

                  int cmp = 0;
                  if (sortKey == QLatin1String("size")) {
                      cmp = (a.size < b.size) ? -1 : (a.size > b.size ? 1 : 0);
                  } else if (sortKey == QLatin1String("time")) {
                      if (a.modTime != b.modTime)
                          cmp = (a.modTime < b.modTime) ? -1 : 1;
                  }
                  if (cmp == 0)
                      cmp = NaturalSort::compare(a.name, b.name);
                  return ascending ? (cmp < 0) : (cmp > 0);
              });
}

FileEntry DirectorySort::nextSibling(const FileEntryList &entries, const QString &currentPath,
                                     const QString &sortKey, bool ascending)
{
    // 只推荐「可播放的同一类」：视频推视频、音频推音频。
    // 类型由当前项自己决定，调用方不需要（也不该）再传一遍
    const MediaType::Kind kind = MediaType::fromPath(currentPath, false);
    if (kind != MediaType::Video && kind != MediaType::Audio)
        return {};

    return nextMatching(entries, currentPath, sortKey, ascending, [kind](const FileEntry &entry) {
        return MediaType::fromPath(entry.path, false) == kind;
    });
}

FileEntry DirectorySort::nextBook(const FileEntryList &entries, const QString &currentPath,
                                  const QString &sortKey, bool ascending)
{
    return nextMatching(entries, currentPath, sortKey, ascending,
                        [](const FileEntry &entry) { return isBookPath(entry.path); });
}

FileEntry DirectorySort::nextComic(const FileEntryList &entries, const QString &currentPath,
                                   const QString &sortKey, bool ascending)
{
    return nextMatching(entries, currentPath, sortKey, ascending,
                        [](const FileEntry &entry) { return isComicPath(entry.path); });
}

} // namespace myhub
