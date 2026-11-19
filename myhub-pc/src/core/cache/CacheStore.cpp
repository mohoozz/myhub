#include "CacheStore.h"

#include "CachePartition.h"
#include "../utils/AppLogger.h"

#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QMutexLocker>

#include <algorithm>

namespace myhub {

namespace {
/// 压到配额的 90%：留出余量，否则每次写一个文件都要全扫一遍
constexpr double kTrimTarget = 0.9;

/// 递归删掉空子目录（分区根目录保留：`AppPaths::initializeAll` 按它建目录）
void pruneEmptyDirs(const QString &path)
{
    const QDir dir(path);
    const QStringList subs = dir.entryList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name);
    for (const QString &sub : subs) {
        const QString child = dir.filePath(sub);
        pruneEmptyDirs(child);
        // rmdir 只删空目录：还有内容时静默失败，正是我们要的
        QDir().rmdir(child);
    }
}
} // namespace

CacheStore::CacheStore(QString rootDir, qint64 totalLimitBytes, QList<CachePartition> partitions)
    : m_rootDir(std::move(rootDir))
    , m_totalLimitBytes(qMax<qint64>(0, totalLimitBytes))
    , m_partitions(std::move(partitions))
{}

QList<CacheStore::Bucket> CacheStore::collect() const
{
    QList<Bucket> buckets;
    const QDir root(m_rootDir);
    if (!root.exists()) {
        return buckets;
    }

    // 一级目录 = 分区。只认目录：根上散落的文件没有归属，不属于任何配额
    const QStringList dirs = root.entryList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name);
    for (const QString &name : dirs) {
        Bucket bucket;
        bucket.dir = name;

        // 显式分区表优先（测试用小配额），否则用全局定义
        const CachePartition *spec = nullptr;
        if (!m_partitions.isEmpty()) {
            for (const CachePartition &candidate : m_partitions) {
                if (candidate.dir == name) {
                    spec = &candidate;
                    break;
                }
            }
        } else {
            spec = CachePartitions::find(name);
        }

        if (spec != nullptr) {
            bucket.label = spec->label;
            bucket.limitBytes = CachePartitions::quotaBytes(*spec, m_totalLimitBytes);
            bucket.selfManaged = spec->selfManaged;
        } else {
            // 未登记的一级目录（历史版本留下的 `stream` / `comic` / `comic-packs`）：
            // 不给分区配额，但仍纳入全局兜底——否则旧缓存会成为永远清不掉的死角
            bucket.label = name;
        }

        // 递归：音视频分片是「一个文件一个子目录」，漫画整包也放在 `comicPages/packs` 下，
        // 淘汰单元始终是**文件**
        QDirIterator it(root.filePath(name), QDir::Files | QDir::NoSymLinks,
                        QDirIterator::Subdirectories);
        while (it.hasNext()) {
            const QString path = it.next();
            const QFileInfo info = it.fileInfo();
            Entry entry;
            entry.path = path;
            entry.bytes = info.size();
            entry.mtimeMs = info.lastModified().toMSecsSinceEpoch();
            entry.partial = path.endsWith(QLatin1String(".part"), Qt::CaseInsensitive);
            bucket.bytes += entry.bytes;
            bucket.files.append(entry);
        }
        buckets.append(bucket);
    }
    return buckets;
}

CacheStore::Scan CacheStore::summarize(const QList<Bucket> &buckets)
{
    Scan scan;
    for (const Bucket &bucket : buckets) {
        PartitionUsage usage;
        usage.dir = bucket.dir;
        usage.label = bucket.label;
        usage.limitBytes = bucket.limitBytes;
        usage.selfManaged = bucket.selfManaged;
        for (const Entry &entry : bucket.files) {
            if (entry.gone) {
                continue;
            }
            usage.bytes += entry.bytes;
            ++usage.files;
        }
        scan.partitions.append(usage);
        scan.totalBytes += usage.bytes;
        scan.totalFiles += usage.files;
    }
    return scan;
}

bool CacheStore::isProtected(const QString &path, const QSet<QString> &prefixes)
{
    if (prefixes.isEmpty()) {
        return false;
    }
    for (const QString &prefix : prefixes) {
        if (!prefix.isEmpty() && path.startsWith(prefix)) {
            return true;
        }
    }
    return false;
}

qint64 CacheStore::evictTo(Bucket &bucket, qint64 targetBytes, const QSet<QString> &prefixes,
                           int *removedFiles)
{
    if (bucket.bytes <= targetBytes) {
        return 0;
    }

    // 半截文件最优先（下载残骸），其次按 mtime 升序，同一时间按路径保证结果确定
    QList<int> order;
    order.reserve(bucket.files.size());
    for (int i = 0; i < bucket.files.size(); ++i) {
        order.append(i);
    }
    std::sort(order.begin(), order.end(), [&bucket](int lhs, int rhs) {
        const Entry &a = bucket.files.at(lhs);
        const Entry &b = bucket.files.at(rhs);
        if (a.partial != b.partial) {
            return a.partial;
        }
        if (a.mtimeMs != b.mtimeMs) {
            return a.mtimeMs < b.mtimeMs;
        }
        return a.path < b.path;
    });

    qint64 freed = 0;
    for (int index : order) {
        if (bucket.bytes - freed <= targetBytes) {
            break;
        }
        Entry &entry = bucket.files[index];
        if (entry.gone || isProtected(entry.path, prefixes)) {
            continue;
        }
        if (!QFile::remove(entry.path)) {
            // 被占用的不反复试：下一轮清理再说
            MH_DEBUG(Cache, QStringLiteral("缓存文件删除失败，跳过：%1").arg(entry.path));
            continue;
        }
        entry.gone = true;
        freed += entry.bytes;
        ++(*removedFiles);
    }
    return freed;
}

CacheStore::Scan CacheStore::scan() const
{
    QMutexLocker lock(&m_mutex);
    return summarize(collect());
}

void CacheStore::setTotalLimitBytes(qint64 bytes)
{
    QMutexLocker lock(&m_mutex);
    m_totalLimitBytes = qMax<qint64>(0, bytes);
}

CacheStore::Result CacheStore::purge(const QString &dir, const QSet<QString> &protectedPrefixes)
{
    QMutexLocker lock(&m_mutex);

    QList<Bucket> buckets = collect();
    Result result;
    result.before = summarize(buckets);

    const bool all = dir.isEmpty();
    for (Bucket &bucket : buckets) {
        if (!all && bucket.dir != dir) {
            continue;
        }
        for (Entry &entry : bucket.files) {
            if (entry.gone || isProtected(entry.path, protectedPrefixes)) {
                continue;
            }
            if (!QFile::remove(entry.path)) {
                // 正在被读 / 权限不足：不反复试，留到下一轮
                MH_DEBUG(Cache, QStringLiteral("缓存文件删除失败，跳过：%1").arg(entry.path));
                continue;
            }
            entry.gone = true;
            bucket.bytes -= entry.bytes;
            ++result.removedFiles;
            result.removedBytes += entry.bytes;
        }
        // 只清空壳子目录，分区根目录本身留给下一次写入
        pruneEmptyDirs(QDir(m_rootDir).filePath(bucket.dir));
    }

    // 重新扫一遍：删掉空目录后分区列表应与磁盘一致（设置页直接展示这份）
    result.after = summarize(collect());
    MH_INFO(Cache,
            QStringLiteral("清空缓存%1：删除 %2 个文件，%3 字节")
                .arg(all ? QStringLiteral("（全部）") : QStringLiteral("分区 ") + dir)
                .arg(result.removedFiles)
                .arg(result.removedBytes));
    return result;
}

CacheStore::Result CacheStore::enforce(const QSet<QString> &protectedPrefixes)
{
    QMutexLocker lock(&m_mutex);

    QList<Bucket> buckets = collect();
    Result result;
    result.before = summarize(buckets);

    // 1) 分区配额：先把单个分区压回自己的配额
    for (Bucket &bucket : buckets) {
        if (bucket.selfManaged || bucket.limitBytes <= 0 || bucket.bytes <= bucket.limitBytes) {
            continue;
        }
        const qint64 target = qint64(double(bucket.limitBytes) * kTrimTarget);
        int removed = 0;
        const qint64 freed = evictTo(bucket, target, protectedPrefixes, &removed);
        bucket.bytes -= freed;
        result.removedFiles += removed;
        result.removedBytes += freed;
        MH_INFO(Cache,
                QStringLiteral("分区 %1 超配额：释放 %2 字节（%3 个文件）")
                    .arg(bucket.dir)
                    .arg(freed)
                    .arg(removed));
    }

    // 2) 全局兜底：总和（含自管分区，它们同样占盘）超上限时跨分区删最旧的
    qint64 total = 0;
    for (const Bucket &bucket : buckets) {
        total += bucket.bytes;
    }
    if (total > m_totalLimitBytes && m_totalLimitBytes > 0) {
        const qint64 target = qint64(double(m_totalLimitBytes) * kTrimTarget);

        struct Candidate
        {
            int bucket;
            int index;
        };
        QList<Candidate> candidates;
        for (int b = 0; b < buckets.size(); ++b) {
            if (buckets.at(b).selfManaged) {
                continue;
            }
            for (int i = 0; i < buckets.at(b).files.size(); ++i) {
                candidates.append({b, i});
            }
        }
        std::sort(candidates.begin(), candidates.end(),
                  [&buckets](const Candidate &lhs, const Candidate &rhs) {
                      const Entry &a = buckets.at(lhs.bucket).files.at(lhs.index);
                      const Entry &b = buckets.at(rhs.bucket).files.at(rhs.index);
                      if (a.partial != b.partial) {
                          return a.partial;
                      }
                      if (a.mtimeMs != b.mtimeMs) {
                          return a.mtimeMs < b.mtimeMs;
                      }
                      return a.path < b.path;
                  });

        qint64 freed = 0;
        for (const Candidate &candidate : candidates) {
            if (total - freed <= target) {
                break;
            }
            Bucket &bucket = buckets[candidate.bucket];
            Entry &entry = bucket.files[candidate.index];
            if (entry.gone || isProtected(entry.path, protectedPrefixes)) {
                continue;
            }
            if (!QFile::remove(entry.path)) {
                continue;
            }
            entry.gone = true;
            bucket.bytes -= entry.bytes;
            freed += entry.bytes;
            ++result.removedFiles;
        }
        result.removedBytes += freed;
        MH_INFO(Cache,
                QStringLiteral("全局兜底：总量 %1 字节超上限 %2，释放 %3 字节")
                    .arg(total)
                    .arg(m_totalLimitBytes)
                    .arg(freed));
    }

    result.after = summarize(buckets);
    return result;
}

bool CacheStore::touch(const QString &filePath)
{
    if (filePath.isEmpty()) {
        return false;
    }
    // 用 mtime 当 LRU 时钟（与 SegmentCache 一致）：atime 在 Windows 上默认不实时落盘。
    // `ExistingOnly` 是必须的：光给 ReadWrite 时 Qt 会**创建**缺失的文件，
    // 于是「刷新一个已经被淘汰的页」会凭空写回 0 字节垃圾
    QFile file(filePath);
    if (!file.open(QIODevice::ReadWrite | QIODevice::ExistingOnly)) {
        return false;
    }
    const bool ok =
        file.setFileTime(QDateTime::currentDateTime(), QFileDevice::FileModificationTime);
    file.close();
    return ok;
}

} // namespace myhub
