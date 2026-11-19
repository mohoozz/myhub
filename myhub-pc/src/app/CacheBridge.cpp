#include "CacheBridge.h"

#include "core/cache/CacheCleaner.h"
#include "core/cache/CachePartition.h"
#include "core/utils/AppLogger.h"

#include <QtConcurrent/QtConcurrentRun>

namespace myhub {

namespace {

QString labelFor(const QString &dir)
{
    if (dir.isEmpty()) {
        return QStringLiteral("全部");
    }
    const CachePartition *spec = CachePartitions::find(dir);
    return spec != nullptr ? spec->label : dir;
}

} // namespace

CacheBridge::CacheBridge(QObject *parent)
    : QObject(parent)
{
    m_totalLimitBytes = CachePartitions::totalLimitBytes();
}

void CacheBridge::refresh()
{
    if (m_scanWatcher != nullptr) {
        // 正在扫：记一笔，结束后补跑，别把这次请求丢掉
        m_scanPending = true;
        return;
    }
    // 设置页可能先于启动预热被打开：这里兜底建引擎（幂等）
    if (!CacheCleaner::instance().ready()) {
        CacheCleaner::instance().initialize();
    }
    startScan();
}

void CacheBridge::startScan()
{
    m_scanPending = false;
    auto *watcher = new QFutureWatcher<CacheStore::Scan>(this);
    m_scanWatcher = watcher;

    connect(watcher, &QFutureWatcher<CacheStore::Scan>::finished, this, [this, watcher] {
        const CacheStore::Scan scan = watcher->result();
        watcher->deleteLater();
        m_scanWatcher = nullptr;

        applyScan(scan);
        emit loadingChanged();
        emit usageChanged();

        if (m_scanPending) {
            refresh();
        }
    });

    emit loadingChanged();
    watcher->setFuture(QtConcurrent::run([] { return CacheCleaner::instance().snapshot(); }));
}

void CacheBridge::applyScan(const CacheStore::Scan &scan)
{
    m_partitions.clear();
    m_partitions.reserve(scan.partitions.size());
    for (const CacheStore::PartitionUsage &usage : scan.partitions) {
        QVariantMap item;
        item.insert(QStringLiteral("dir"), usage.dir);
        item.insert(QStringLiteral("label"), usage.label);
        item.insert(QStringLiteral("bytes"), usage.bytes);
        item.insert(QStringLiteral("files"), usage.files);
        item.insert(QStringLiteral("limitBytes"), usage.limitBytes);
        item.insert(QStringLiteral("selfManaged"), usage.selfManaged);
        // 进度条比例；自管分区没有配额上限，按总上限给个参照
        const qint64 denominator = usage.limitBytes > 0 ? usage.limitBytes : m_totalLimitBytes;
        item.insert(QStringLiteral("ratio"),
                    denominator > 0 ? qBound(0.0, double(usage.bytes) / double(denominator), 1.0)
                                    : 0.0);
        m_partitions.append(item);
    }
    m_totalBytes = scan.totalBytes;
    m_totalFiles = scan.totalFiles;
    m_totalLimitBytes = CacheCleaner::instance().totalLimitBytes();
}

void CacheBridge::clearPartition(const QString &dir)
{
    if (m_purgeWatcher != nullptr) {
        return; // 正在清：忽略重复点击（按钮已禁用，这里只是兜底）
    }

    auto *watcher = new QFutureWatcher<CacheStore::Result>(this);
    m_purgeWatcher = watcher;
    const QString label = labelFor(dir);

    connect(watcher, &QFutureWatcher<CacheStore::Result>::finished, this, [this, watcher, label] {
        const CacheStore::Result result = watcher->result();
        watcher->deleteLater();
        m_purgeWatcher = nullptr;
        emit clearingChanged();
        MH_INFO(Cache,
                QStringLiteral("手工清理 %1：删除 %2 个文件，%3 字节")
                    .arg(label)
                    .arg(result.removedFiles)
                    .arg(result.removedBytes));
        emit cleared(label, result.removedFiles, result.removedBytes);
        // 清完立刻刷新占用（不必等下一次进页面）
        refresh();
    });

    emit clearingChanged();
    watcher->setFuture(
        QtConcurrent::run([this, dir] { return CacheCleaner::instance().purge(dir); }));
}

void CacheBridge::clearAll()
{
    clearPartition(QString());
}

} // namespace myhub
