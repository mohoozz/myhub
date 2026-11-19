#include "CachePartition.h"

#include "../preferences/AppSettings.h"
#include "../utils/AppPaths.h"

namespace myhub {

namespace {
constexpr qint64 kMB = 1024LL * 1024;
constexpr int kMinTotalMB = 128;
} // namespace

const QList<CachePartition> &CachePartitions::all()
{
    // 配额与需求文档 §5.5 一致：T=2048MB 时为 2048 / max(256,512) / max(64,256)
    // / max(16,32) MB
    static const QList<CachePartition> kList{
        {QString::fromLatin1(CacheDirs::MediaSegments), QStringLiteral("音视频分片"), 0, 1, true},
        {QString::fromLatin1(CacheDirs::ComicPages), QStringLiteral("漫画页与整包"), 256, 4, false},
        {QString::fromLatin1(CacheDirs::Thumbnails), QStringLiteral("封面缩略图"), 64, 8, false},
        // 插图与封面同级：都是「小图」，按张数增长，配额不必给大
        {QString::fromLatin1(CacheDirs::NovelImages), QStringLiteral("小说插图"), 48, 16, false},
        {QString::fromLatin1(CacheDirs::DirectoryListings), QStringLiteral("目录列表"), 16, 64,
         false},
    };
    return kList;
}

const CachePartition *CachePartitions::find(const QString &dir)
{
    for (const CachePartition &partition : all()) {
        if (partition.dir == dir) {
            return &partition;
        }
    }
    return nullptr;
}

qint64 CachePartitions::quotaBytes(const CachePartition &partition, qint64 totalLimitBytes)
{
    const qint64 base = qint64(partition.quotaBaseMB) * kMB;
    const qint64 scaled =
        partition.quotaDivisor > 0 ? totalLimitBytes / partition.quotaDivisor : totalLimitBytes;
    return qMax(base, scaled);
}

qint64 CachePartitions::totalLimitBytes()
{
    const int mb = qMax(kMinTotalMB, AppSettings::instance().cacheTotalLimitMB());
    return qint64(mb) * kMB;
}

QString CachePartitions::path(const QString &dir)
{
    return AppPaths::cachePartition(dir);
}

} // namespace myhub
