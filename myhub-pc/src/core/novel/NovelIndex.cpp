#include "NovelIndex.h"

namespace myhub {

NovelIndex NovelIndex::singleChapter(qint64 fileSize, TextCodec::Encoding encoding)
{
    NovelIndex index;
    index.encoding = encoding;
    index.fileSize = fileSize;
    NovelChapter whole;
    whole.title = QStringLiteral("全文");
    whole.startOffset = 0;
    index.chapters.append(whole);
    return index;
}

int NovelIndex::chapterAt(qint64 byteOffset) const
{
    if (chapters.isEmpty()) {
        return -1;
    }
    if (byteOffset <= chapters.constFirst().startOffset) {
        return 0;
    }
    // 二分最后一个 startOffset <= byteOffset
    int low = 0;
    int high = chapters.size() - 1;
    while (low < high) {
        const int mid = (low + high + 1) / 2;
        if (chapters.at(mid).startOffset <= byteOffset) {
            low = mid;
        } else {
            high = mid - 1;
        }
    }
    return low;
}

qint64 NovelIndex::chapterStart(int index) const
{
    if (index < 0 || index >= chapters.size()) {
        return -1;
    }
    return chapters.at(index).startOffset;
}

qint64 NovelIndex::chapterEnd(int index) const
{
    if (index < 0 || index >= chapters.size()) {
        return -1;
    }
    if (index + 1 < chapters.size()) {
        return chapters.at(index + 1).startOffset;
    }
    // 末章：到文件尾。缓存里的 fileSize 可能比真实文件小（上次索引后被追加），取大值
    return qMax(fileSize, chapters.at(index).startOffset);
}

QString NovelIndex::chapterTitle(int index) const
{
    if (index < 0 || index >= chapters.size()) {
        return {};
    }
    return chapters.at(index).title;
}

bool NovelIndex::matchesFile(qint64 size, qint64 modTimeMs) const
{
    if (!isValid() || fileSize <= 0) {
        return false;
    }
    if (fileSize != size) {
        return false;
    }
    // 修改时间精度在不同文件系统上差异很大（FAT 2 秒、SMB 甚至丢秒），
    // 只认「都拿到且相差不超过 2 秒」，避免每次打开都重扫一遍
    if (modTime <= 0 || modTimeMs <= 0) {
        return true;
    }
    return qAbs(modTime - modTimeMs) <= 2000;
}

double NovelIndex::percentAt(qint64 byteOffset) const
{
    if (fileSize <= 0) {
        return 0.0;
    }
    const double ratio = static_cast<double>(byteOffset) / static_cast<double>(fileSize);
    return qBound(0.0, ratio, 1.0);
}

} // namespace myhub
