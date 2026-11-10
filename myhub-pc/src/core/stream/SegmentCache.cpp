#include "SegmentCache.h"

#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>

#include <algorithm>

namespace myhub {

namespace {

constexpr int kSegmentNameWidth = 8;
constexpr auto kMetaName = "meta.json";

int segmentDistance(int a, int b)
{
    return qAbs(a - b);
}

} // namespace

SegmentCache::SegmentCache(Config config)
    : m_config(std::move(config))
{
    if (m_config.segmentBytes <= 0)
        m_config.segmentBytes = 1024 * 1024;
    if (m_config.totalLimitBytes <= 0)
        m_config.totalLimitBytes = qint64(2) * 1024 * 1024 * 1024;
}

SegmentCache::~SegmentCache() = default;

QString SegmentCache::keyFor(const QString &connectionId, const QString &path,
                             const QString &fingerprint)
{
    const QString raw = QStringLiteral("%1|%2|%3").arg(connectionId, path, fingerprint);
    return QString::fromLatin1(
        QCryptographicHash::hash(raw.toUtf8(), QCryptographicHash::Sha1).toHex().left(16));
}

int SegmentCache::segmentIndex(qint64 offset) const
{
    if (offset <= 0)
        return 0;
    return static_cast<int>(offset / m_config.segmentBytes);
}

qint64 SegmentCache::segmentStart(int index) const
{
    return static_cast<qint64>(index) * m_config.segmentBytes;
}

QString SegmentCache::dirFor(const QString &key) const
{
    return QDir(m_config.rootDir).filePath(key);
}

QString SegmentCache::pathFor(const QString &key, int index) const
{
    return QDir(dirFor(key))
        .filePath(QStringLiteral("%1.seg").arg(index, kSegmentNameWidth, 10, QLatin1Char('0')));
}

int SegmentCache::indexFromName(const QString &fileName) const
{
    if (!fileName.endsWith(QLatin1String(".seg"), Qt::CaseInsensitive))
        return -1;
    bool ok = false;
    const int index = fileName.chopped(4).toInt(&ok);
    return ok ? index : -1;
}

void SegmentCache::ensureScanned() const
{
    if (m_scanned)
        return;
    m_scanned = true;
    m_totalBytes = 0;
    m_fileBytes.clear();

    const QDir root(m_config.rootDir);
    if (!root.exists())
        return;

    const QStringList dirs = root.entryList(QDir::Dirs | QDir::NoDotAndDotDot);
    for (const QString &key : dirs) {
        qint64 bytes = 0;
        const QDir dir(root.filePath(key));
        const QStringList files = dir.entryList({QStringLiteral("*.seg")}, QDir::Files);
        for (const QString &file : files)
            bytes += QFileInfo(dir.filePath(file)).size();
        if (bytes > 0) {
            m_fileBytes.insert(key, bytes);
            m_totalBytes += bytes;
        }
    }
}

bool SegmentCache::contains(const QString &key, int index) const
{
    if (key.isEmpty() || index < 0)
        return false;
    return QFileInfo::exists(pathFor(key, index));
}

QByteArray SegmentCache::readSegment(const QString &key, int index) const
{
    if (key.isEmpty() || index < 0)
        return {};

    const QString path = pathFor(key, index);
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        return {};

    const QByteArray data = file.readAll();
    file.close();

    // 刷新 mtime：LRU 淘汰依据（读命中说明这段还有用）
    if (!data.isEmpty()) {
        QFile touch(path);
        if (touch.open(QIODevice::ReadWrite))
            touch.setFileTime(QDateTime::currentDateTime(), QFileDevice::FileModificationTime);
    }
    return data;
}

bool SegmentCache::writeSegment(const QString &key, int index, const QByteArray &data)
{
    if (key.isEmpty() || index < 0 || data.isEmpty())
        return false;

    ensureScanned();

    QDir dir(dirFor(key));
    if (!dir.exists() && !QDir().mkpath(dir.absolutePath()))
        return false;

    const QString path = pathFor(key, index);
    const qint64 previous = QFileInfo(path).size();

    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly))
        return false;
    if (file.write(data) != data.size()) {
        file.cancelWriting();
        return false;
    }
    if (!file.commit())
        return false;

    const qint64 delta = data.size() - previous;
    m_fileBytes[key] = m_fileBytes.value(key) + delta;
    m_totalBytes += delta;

    enforceLimits(key);
    return true;
}

void SegmentCache::writeMeta(const QString &key, const QVariantMap &meta)
{
    if (key.isEmpty())
        return;

    QDir dir(dirFor(key));
    if (!dir.exists() && !QDir().mkpath(dir.absolutePath()))
        return;

    QVariantMap payload = meta;
    payload.insert(QStringLiteral("updatedAt"), QDateTime::currentMSecsSinceEpoch());

    QSaveFile file(dir.filePath(QLatin1String(kMetaName)));
    if (!file.open(QIODevice::WriteOnly))
        return;
    file.write(QJsonDocument(QJsonObject::fromVariantMap(payload)).toJson(QJsonDocument::Compact));
    file.commit();
}

QVariantMap SegmentCache::readMeta(const QString &key) const
{
    if (key.isEmpty())
        return {};

    QFile file(QDir(dirFor(key)).filePath(QLatin1String(kMetaName)));
    if (!file.open(QIODevice::ReadOnly))
        return {};
    const QJsonDocument doc = QJsonDocument::fromJson(file.readAll());
    return doc.isObject() ? doc.object().toVariantMap() : QVariantMap();
}

bool SegmentCache::findCachedIdentity(const QString &connectionId, const QString &path,
                                      QVariantMap *meta) const
{
    const QDir root(m_config.rootDir);
    if (!root.exists())
        return false;

    const QStringList dirs = root.entryList(QDir::Dirs | QDir::NoDotAndDotDot);
    QVariantMap best;
    for (const QString &key : dirs) {
        const QVariantMap candidate = readMeta(key);
        if (candidate.isEmpty())
            continue;
        if (candidate.value(QStringLiteral("connectionId")).toString() != connectionId)
            continue;
        if (candidate.value(QStringLiteral("path")).toString() != path)
            continue;
        if (candidate.value(QStringLiteral("size")).toLongLong() <= 0)
            continue;
        if (best.isEmpty()
            || candidate.value(QStringLiteral("updatedAt")).toLongLong()
                > best.value(QStringLiteral("updatedAt")).toLongLong()) {
            best = candidate;
            best.insert(QStringLiteral("key"), key);
        }
    }

    if (best.isEmpty())
        return false;
    if (meta)
        *meta = best;
    return true;
}

void SegmentCache::setPlayhead(const QString &key, qint64 byteOffset)
{
    if (key.isEmpty())
        return;
    m_playheads.insert(key, qMax<qint64>(0, byteOffset));
}

qint64 SegmentCache::playheadFor(const QString &key) const
{
    return m_playheads.value(key, 0);
}

qint64 SegmentCache::fileBytes(const QString &key) const
{
    ensureScanned();
    return m_fileBytes.value(key, 0);
}

qint64 SegmentCache::totalBytes() const
{
    ensureScanned();
    return m_totalBytes;
}

int SegmentCache::segmentCount(const QString &key) const
{
    if (key.isEmpty())
        return 0;
    const QDir dir(dirFor(key));
    if (!dir.exists())
        return 0;
    return dir.entryList({QStringLiteral("*.seg")}, QDir::Files).size();
}

qint64 SegmentCache::fileLimitBytes() const
{
    return qMax<qint64>(m_config.segmentBytes, m_config.totalLimitBytes / 4);
}

void SegmentCache::removeFile(const QString &key)
{
    if (key.isEmpty())
        return;

    ensureScanned();
    const qint64 freed = m_fileBytes.take(key);
    m_totalBytes = qMax<qint64>(0, m_totalBytes - freed);
    m_playheads.remove(key);
    QDir(dirFor(key)).removeRecursively();
}

int SegmentCache::evictFarthest(const QString &key, qint64 targetBytes)
{
    QDir dir(dirFor(key));
    if (!dir.exists())
        return 0;

    const QStringList files = dir.entryList({QStringLiteral("*.seg")}, QDir::Files);
    if (files.isEmpty())
        return 0;

    const int playhead = segmentIndex(playheadFor(key));

    QList<QPair<int, QString>> segments; // index, fileName
    segments.reserve(files.size());
    for (const QString &file : files) {
        const int index = indexFromName(file);
        if (index >= 0)
            segments.append({index, file});
    }

    // 最远的分片先走；同距离时索引小的先走（更可能是已经播过的旧数据）
    std::sort(segments.begin(), segments.end(), [playhead](const auto &a, const auto &b) {
        const int da = segmentDistance(a.first, playhead);
        const int db = segmentDistance(b.first, playhead);
        if (da != db)
            return da > db;
        return a.first < b.first;
    });

    int removed = 0;
    qint64 bytes = fileBytes(key);
    for (const auto &segment : segments) {
        if (bytes <= targetBytes)
            break;
        const QString path = dir.filePath(segment.second);
        const qint64 size = QFileInfo(path).size();
        if (!QFile::remove(path))
            continue;
        bytes -= size;
        m_totalBytes -= size;
        ++removed;
    }

    m_fileBytes[key] = qMax<qint64>(0, bytes);
    return removed;
}

int SegmentCache::evictOldest(qint64 targetBytes, const QString &activeKey)
{
    ensureScanned();

    struct Entry
    {
        QString key;
        int index;
        QString path;
        qint64 size;
        QDateTime modified;
    };

    QList<Entry> entries;
    const QDir root(m_config.rootDir);
    const QStringList dirs = root.entryList(QDir::Dirs | QDir::NoDotAndDotDot);
    for (const QString &key : dirs) {
        const QDir dir(root.filePath(key));
        const QStringList files = dir.entryList({QStringLiteral("*.seg")}, QDir::Files);
        for (const QString &file : files) {
            const int index = indexFromName(file);
            if (index < 0)
                continue;
            const QFileInfo info(dir.filePath(file));
            entries.append({key, index, info.absoluteFilePath(), info.size(), info.lastModified()});
        }
    }

    std::sort(entries.begin(), entries.end(),
              [](const Entry &a, const Entry &b) { return a.modified < b.modified; });

    const int protectedIndex = activeKey.isEmpty() ? -1 : segmentIndex(playheadFor(activeKey));

    int removed = 0;
    for (const Entry &entry : entries) {
        if (m_totalBytes <= targetBytes)
            break;
        // 当前会话播放点附近（前后各 2 个分片）受保护，否则会把正在播的分片挤掉
        if (entry.key == activeKey && protectedIndex >= 0
            && segmentDistance(entry.index, protectedIndex) <= 2)
            continue;
        if (!QFile::remove(entry.path))
            continue;
        m_totalBytes = qMax<qint64>(0, m_totalBytes - entry.size);
        m_fileBytes[entry.key] = qMax<qint64>(0, m_fileBytes.value(entry.key) - entry.size);
        ++removed;
    }
    return removed;
}

int SegmentCache::enforceLimits(const QString &activeKey)
{
    ensureScanned();

    int removed = 0;
    const qint64 fileLimit = fileLimitBytes();
    const QStringList keys = m_fileBytes.keys();
    for (const QString &key : keys) {
        if (fileBytes(key) > fileLimit) {
            removed += evictFarthest(key, fileLimit);
            // 目录已空则整份删除，避免留下空目录污染统计
            if (fileBytes(key) == 0)
                QDir(dirFor(key)).removeRecursively();
        }
    }

    if (m_totalBytes > m_config.totalLimitBytes) {
        // 压到 90%，避免每次写入都触发一次淘汰扫描
        removed += evictOldest(m_config.totalLimitBytes * 9 / 10, activeKey);
    }
    return removed;
}

QVariantMap SegmentCache::stats() const
{
    ensureScanned();
    int files = 0;
    for (auto it = m_fileBytes.constBegin(); it != m_fileBytes.constEnd(); ++it) {
        if (it.value() > 0)
            ++files;
    }
    return QVariantMap{
        {QStringLiteral("rootDir"), m_config.rootDir},
        {QStringLiteral("files"), files},
        {QStringLiteral("totalBytes"), m_totalBytes},
        {QStringLiteral("totalLimitBytes"), m_config.totalLimitBytes},
        {QStringLiteral("fileLimitBytes"), fileLimitBytes()},
        {QStringLiteral("segmentBytes"), m_config.segmentBytes},
    };
}

void SegmentCache::clear()
{
    QDir(m_config.rootDir).removeRecursively();
    m_playheads.clear();
    m_fileBytes.clear();
    m_totalBytes = 0;
    m_scanned = true;
}

} // namespace myhub
