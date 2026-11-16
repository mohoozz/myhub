#pragma once

#include "core/storage/StorageError.h"

#include <QByteArray>
#include <QString>
#include <QVector>

namespace myhub {

/// libarchive 里的一个条目（列目录时拿到；只有名字与尺寸是稳定的）
struct ArchiveEntry
{
    QString name;    ///< 条目全名（含子目录）
    qint64 size = 0; ///< 解压后大小；0 表示未知

    bool isDirectory() const { return name.endsWith(QLatin1Char('/')); }
};

/**
 * 用 libarchive 读 rar / cbr（PC-207）。
 *
 * 为什么不能用 `RangeZipReader`：rar 没有 zip 那样的「尾部署引 + 任意条目定位」，
 * 条目只能顺序解压到达（solid 包更是必须从头解到目标页），因此**必然要整个文件在手**。
 * 所以这一层的定位是「本地文件读取器」，远程 rar 由上层先整包落地再交给它。
 *
 * 纪律：
 *   - 本类方法都是**同步阻塞**的（本地磁盘 IO + 解压），调用方负责放到后台线程；
 *   - 单条目解压上限 64MB、条目数上限 20 万，超出报错而不是把内存打爆；
 *   - 加密包明确报「加密」，不做静默降级；
 *   - 页序规则与 zip 完全一致（`pageorder`），换格式不会翻页错乱。
 */
class ArchiveReader
{
public:
    static constexpr qint64 kMaxEntryBytes = 64 * 1024 * 1024;
    static constexpr int kMaxEntries = 200000;

    /// 列出全部条目；`entries` 顺序即归档内顺序
    static StorageError listEntries(const QString &filePath, QVector<ArchiveEntry> *entries);

    /// 读一个条目的原始字节（按全名精确匹配）
    static StorageError readEntry(const QString &filePath, const QString &entryName,
                                  QByteArray *out);

    /// 图片条目下标（按页名自然排序），规则与 `RangeZipReader::imageEntryIndexes` 同一套
    static QVector<int> pageIndexes(const QVector<ArchiveEntry> &entries);

    /// 该路径是否该走本类（rar / cbr）
    static bool isRarPath(const QString &path);
};

} // namespace myhub
