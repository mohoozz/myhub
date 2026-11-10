#include "features/cover/CoverService.h"

#include "core/cover/EmbeddedCoverExtractor.h"
#include "core/storage/StorageAdapter.h"
#include "core/storage/StoragePath.h"
#include "core/utils/AppPaths.h"
#include "core/utils/MediaType.h"
#include "features/connections/ConnectionStore.h"

#include <QBuffer>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QImage>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPointer>
#include <QSaveFile>
#include <QUrl>
#include <QtConcurrent>

namespace myhub {
namespace {

constexpr int kMaxEdge = 512;
constexpr int kJpegQuality = 82;
constexpr qint64 kMaxImageBytes = 24LL * 1024 * 1024;
constexpr int kMaxConcurrent = 4;
constexpr qint64 kFailureCooldownMs = 30LL * 1000;
constexpr int kMaxMemoryEntries = 512;
constexpr qint64 kDirCacheTtlMs = 60LL * 1000;

/// 后台线程：解码 → 缩放 → 落盘（jpg + 旁挂 meta）
bool writeCoverFile(const QString &jpgPath, const QString &metaPath, const QByteArray &raw,
                    qint64 size, qint64 modSecs)
{
    QImage image;
    if (!image.loadFromData(raw)) {
        return false;
    }
    if (image.width() > kMaxEdge || image.height() > kMaxEdge) {
        image = image.scaled(kMaxEdge, kMaxEdge, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    }

    QByteArray encoded;
    QBuffer buffer(&encoded);
    if (!buffer.open(QIODevice::WriteOnly)) {
        return false;
    }
    if (!image.save(&buffer, "JPG", kJpegQuality)) {
        return false;
    }
    buffer.close();

    QDir().mkpath(QFileInfo(jpgPath).absolutePath());
    QSaveFile jpgFile(jpgPath);
    if (!jpgFile.open(QIODevice::WriteOnly) || jpgFile.write(encoded) != encoded.size()
        || !jpgFile.commit()) {
        return false;
    }

    QJsonObject meta;
    meta.insert(QStringLiteral("size"), static_cast<double>(size));
    meta.insert(QStringLiteral("modSecs"), static_cast<double>(modSecs));
    meta.insert(QStringLiteral("savedAt"), static_cast<double>(QDateTime::currentSecsSinceEpoch()));
    QSaveFile metaHandle(metaPath);
    if (!metaHandle.open(QIODevice::WriteOnly)) {
        return false;
    }
    metaHandle.write(QJsonDocument(meta).toJson(QJsonDocument::Compact));
    return metaHandle.commit();
}

QJsonObject readMeta(const QString &path)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) {
        return {};
    }
    return QJsonDocument::fromJson(file.readAll()).object();
}

bool isAudioPath(const QString &path)
{
    return MediaType::isAudio(StoragePath::extension(path));
}

/// 同目录封面图挑选：同名图 > cover > folder > front
QString pickSiblingCover(const QString &targetPath, const FileEntryList &entries, qint64 *size)
{
    const QString stem = StoragePath::baseName(targetPath).toLower();
    QString best;
    int bestScore = 99;
    qint64 bestSize = -1;
    for (const FileEntry &entry : entries) {
        if (entry.isDir || !MediaType::isImage(entry.ext)) {
            continue;
        }
        const QString base = StoragePath::baseName(entry.name).toLower();
        int score = 99;
        if (!stem.isEmpty() && base == stem) {
            score = 0;
        } else if (base == QLatin1String("cover")) {
            score = 1;
        } else if (base == QLatin1String("folder")) {
            score = 2;
        } else if (base == QLatin1String("front")) {
            score = 3;
        }
        if (score < bestScore) {
            bestScore = score;
            best = entry.path;
            bestSize = entry.size;
        }
    }
    if (size != nullptr) {
        *size = bestSize;
    }
    return best;
}

} // namespace

CoverService::CoverService(QObject *parent)
    : QObject(parent)
{}

CoverService::~CoverService() = default;

CoverService &CoverService::instance()
{
    static CoverService s_instance;
    return s_instance;
}

CoverService *CoverService::create(QQmlEngine *, QJSEngine *)
{
    QJSEngine::setObjectOwnership(&instance(), QJSEngine::CppOwnership);
    return &instance();
}

QString CoverService::coverKey(const QString &connectionId, const QString &path) const
{
    return connectionId + QLatin1Char('|') + StoragePath::normalize(path);
}

QString CoverService::coverFile(const QString &key) const
{
    const QString hash = QString::fromLatin1(
        QCryptographicHash::hash(key.toUtf8(), QCryptographicHash::Sha1).toHex());
    return AppPaths::cachePartition(QStringLiteral("thumbnails")) + QLatin1Char('/') + hash
        + QStringLiteral(".jpg");
}

QString CoverService::metaFile(const QString &key) const
{
    QString path = coverFile(key);
    path.chop(4);
    return path + QStringLiteral(".json");
}

void CoverService::rememberMemory(const QString &key, const QString &url)
{
    if (m_memory.contains(key)) {
        m_memoryOrder.removeAll(key);
    }
    m_memory.insert(key, url);
    m_memoryOrder.append(key);
    while (m_memoryOrder.size() > kMaxMemoryEntries) {
        const QString evicted = m_memoryOrder.takeFirst();
        m_memory.remove(evicted);
    }
}

bool CoverService::lookupCached(const QString &key, qint64 size, qint64 modSecs, QString *url)
{
    const auto memIt = m_memory.constFind(key);
    if (memIt != m_memory.constEnd()) {
        if (url != nullptr) {
            *url = *memIt;
        }
        return true;
    }

    const QString jpg = coverFile(key);
    if (!QFile::exists(jpg)) {
        return false;
    }
    // 调用方给了指纹就校验，没给就按「磁盘上有就能用」处理
    if (size >= 0 || modSecs >= 0) {
        const QJsonObject meta = readMeta(metaFile(key));
        if (meta.isEmpty()) {
            return false;
        }
        if (size >= 0
            && static_cast<qint64>(meta.value(QStringLiteral("size")).toDouble(-1)) != size) {
            return false;
        }
        if (modSecs >= 0
            && static_cast<qint64>(meta.value(QStringLiteral("modSecs")).toDouble(-1)) != modSecs) {
            return false;
        }
    }

    const QString fileUrl = QUrl::fromLocalFile(jpg).toString();
    rememberMemory(key, fileUrl);
    if (url != nullptr) {
        *url = fileUrl;
    }
    return true;
}

QString CoverService::cachedCover(const QString &connectionId, const QString &path)
{
    if (connectionId.isEmpty() || path.isEmpty()) {
        return {};
    }
    QString url;
    if (lookupCached(coverKey(connectionId, path), -1, -1, &url)) {
        return url;
    }
    return {};
}

void CoverService::requestCover(const QString &connectionId, const QString &path, qint64 size,
                                qint64 modSecs)
{
    if (connectionId.isEmpty() || path.isEmpty()) {
        return;
    }
    const QString normalized = StoragePath::normalize(path);
    const QString key = coverKey(connectionId, normalized);

    QString url;
    if (lookupCached(key, size, modSecs, &url)) {
        emit coverReady(key, url);
        return;
    }
    if (m_inflight.contains(key)) {
        return; // 已在队列或执行中，完成后统一广播
    }
    const auto failedIt = m_failedAt.constFind(key);
    if (failedIt != m_failedAt.constEnd()
        && failedIt->msecsTo(QDateTime::currentDateTimeUtc()) < kFailureCooldownMs) {
        QMetaObject::invokeMethod(
            this, [this, key]() { emit coverFailed(key); }, Qt::QueuedConnection);
        return;
    }

    m_inflight.insert(key);
    Job job;
    job.key = key;
    job.connectionId = connectionId;
    job.path = normalized;
    job.size = size;
    job.modSecs = modSecs;
    m_queue.enqueue(job);
    dispatch();
}

void CoverService::dispatch()
{
    while (m_running < kMaxConcurrent && !m_queue.isEmpty()) {
        const Job job = m_queue.dequeue();
        ++m_running;
        produce(job);
    }
}

void CoverService::produce(const Job &job)
{
    StorageError error;
    StorageAdapter *adapter = ConnectionStore::instance().adapterFor(job.connectionId, &error);
    if (adapter == nullptr) {
        completeFailure(job);
        return;
    }

    const QString ext = StoragePath::extension(job.path);
    if (MediaType::isImage(ext)) {
        readImageFile(job, adapter, job.path, job.size);
        return;
    }
    if (isAudioPath(job.path) || EmbeddedCoverExtractor::supports(ext)) {
        readEmbeddedCover(job, adapter);
        return;
    }
    completeFailure(job);
}

void CoverService::readImageFile(const Job &job, StorageAdapter *adapter, const QString &path,
                                 qint64 knownSize)
{
    if (knownSize > kMaxImageBytes) {
        completeFailure(job);
        return;
    }
    QPointer<StorageAdapter> guard(adapter);
    adapter->readRange(path, std::nullopt, std::nullopt, [this, job, guard](DataResult result) {
        if (!guard || !result.ok() || result.value.isEmpty()
            || result.value.size() > kMaxImageBytes) {
            completeFailure(job);
            return;
        }
        submitImageBytes(job, result.value);
    });
}

void CoverService::readSiblingCover(const Job &job, StorageAdapter *adapter)
{
    const QString dir = StoragePath::parent(job.path);
    const QString dirKey = job.connectionId + QLatin1Char('|') + dir;

    const auto atIt = m_dirCacheAt.constFind(dirKey);
    if (atIt != m_dirCacheAt.constEnd()
        && atIt->msecsTo(QDateTime::currentDateTimeUtc()) < kDirCacheTtlMs
        && m_dirCache.contains(dirKey)) {
        qint64 size = -1;
        const QString sibling = pickSiblingCover(job.path, m_dirCache.value(dirKey), &size);
        if (sibling.isEmpty()) {
            completeFailure(job);
            return;
        }
        readImageFile(job, adapter, sibling, size);
        return;
    }

    QPointer<StorageAdapter> guard(adapter);
    adapter->list(dir, [this, job, guard, dirKey](ListResult result) {
        if (!guard || !result.ok()) {
            completeFailure(job);
            return;
        }
        m_dirCache.insert(dirKey, result.value);
        m_dirCacheAt.insert(dirKey, QDateTime::currentDateTimeUtc());

        qint64 size = -1;
        const QString sibling = pickSiblingCover(job.path, result.value, &size);
        if (sibling.isEmpty()) {
            completeFailure(job);
            return;
        }
        readImageFile(job, guard, sibling, size);
    });
}

void CoverService::readEmbeddedCover(const Job &job, StorageAdapter *adapter)
{
    QPointer<StorageAdapter> guard(adapter);
    const QString ext = StoragePath::extension(job.path);

    // 内嵌封面拿不到时：音频还有「同目录封面图」这一条路，其余直接失败
    auto fallback = [this, job, guard]() {
        if (!guard) {
            completeFailure(job);
            return;
        }
        if (isAudioPath(job.path)) {
            readSiblingCover(job, guard);
        } else {
            completeFailure(job);
        }
    };

    // job.size 已确定后调用；回调复用带指纹的 job，落盘 meta 才有 size/modSecs
    auto fetch = [this, guard, ext, fallback](const Job &sized) {
        const qint64 fileSize = sized.size;
        const qint64 headLen = EmbeddedCoverExtractor::headLength(fileSize);
        if (!guard || fileSize <= 0 || headLen <= 0) {
            completeFailure(sized);
            return;
        }
        guard->readRange(
            sized.path, 0, headLen - 1,
            [this, sized, guard, ext, fileSize, fallback](DataResult head) {
                if (!guard) {
                    completeFailure(sized);
                    return;
                }
                if (!head.ok() || head.value.isEmpty()) {
                    completeFailure(sized);
                    return;
                }
                const qint64 tailOffset = EmbeddedCoverExtractor::tailOffset(fileSize);
                if (tailOffset <= head.value.size() || tailOffset >= fileSize) {
                    const QByteArray image =
                        EmbeddedCoverExtractor::extract(ext, fileSize, head.value);
                    if (image.isEmpty()) {
                        fallback();
                        return;
                    }
                    submitImageBytes(sized, image);
                    return;
                }
                guard->readRange(
                    sized.path, tailOffset, fileSize - 1,
                    [this, sized, guard, ext, fileSize, head, fallback](DataResult tail) {
                        if (!guard) {
                            completeFailure(sized);
                            return;
                        }
                        const QByteArray image = EmbeddedCoverExtractor::extract(
                            ext, fileSize, head.value, tail.ok() ? tail.value : QByteArray());
                        if (image.isEmpty()) {
                            fallback();
                            return;
                        }
                        submitImageBytes(sized, image);
                    });
            });
    };

    if (!EmbeddedCoverExtractor::supports(ext)) {
        fallback();
        return;
    }
    if (job.size > 0) {
        fetch(job);
        return;
    }

    adapter->stat(job.path, [this, job, guard, fetch](StatResult result) {
        if (!guard) {
            completeFailure(job);
            return;
        }
        if (!result.ok() || result.value.size <= 0) {
            completeFailure(job);
            return;
        }
        Job sized = job;
        sized.size = result.value.size;
        sized.modSecs = result.value.modTime.toSecsSinceEpoch();
        fetch(sized);
    });
}

void CoverService::submitImageBytes(const Job &job, const QByteArray &raw)
{
    const QString jpgPath = coverFile(job.key);
    const QString jsonPath = metaFile(job.key);

    auto *watcher = new QFutureWatcher<bool>(this);
    connect(watcher, &QFutureWatcher<bool>::finished, this, [this, watcher, job]() {
        const bool ok = watcher->result();
        watcher->deleteLater();

        m_inflight.remove(job.key);
        if (m_running > 0) {
            --m_running;
        }
        if (!ok) {
            m_failedAt.insert(job.key, QDateTime::currentDateTimeUtc());
            emit coverFailed(job.key);
            dispatch();
            return;
        }
        const QString url = QUrl::fromLocalFile(coverFile(job.key)).toString();
        rememberMemory(job.key, url);
        m_failedAt.remove(job.key);
        emit coverReady(job.key, url);
        dispatch();
    });
    watcher->setFuture(
        QtConcurrent::run(&writeCoverFile, jpgPath, jsonPath, raw, job.size, job.modSecs));
}

void CoverService::completeFailure(const Job &job)
{
    m_inflight.remove(job.key);
    if (m_running > 0) {
        --m_running;
    }
    m_failedAt.insert(job.key, QDateTime::currentDateTimeUtc());
    emit coverFailed(job.key);
    dispatch();
}

} // namespace myhub
