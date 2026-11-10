#pragma once

#include <QByteArray>
#include <QHash>
#include <QString>
#include <QVariantMap>

namespace myhub {

/**
 * 边下边播的分片磁盘缓存（§4.2）。
 *
 * 布局：`<rootDir>/<key>/<index>.seg` + `<rootDir>/<key>/meta.json`
 *
 * 纪律：
 *   - **缓存键含文件指纹**（size + modTime）：同名文件被替换后旧分片自动失效，
 *     不会把上一版文件的中段喂给播放器（表现为花屏 / 时间轴错乱）
 *   - 单文件上限为总量上限的 1/4；超限时**淘汰离播放点最远的分片**，
 *     而不是按写入时间淘汰——否则边看边缓存会把正在播的分片自己挤掉
 *   - 总量超限时先淘汰其它文件最旧的分片，**当前会话头部附近分片受保护**
 *   - 读操作会刷新 mtime（LRU 依据），写操作先写临时文件再改名，避免半截分片
 *   - `meta.json` 支持离线反查：stat 失败时可凭缓存身份继续起播
 */
class SegmentCache
{
public:
    struct Config
    {
        QString rootDir;
        qint64 totalLimitBytes = qint64(2) * 1024 * 1024 * 1024;
        int segmentBytes = 1024 * 1024;
    };

    explicit SegmentCache(Config config);
    ~SegmentCache();

    /// 缓存键：连接 + 路径 + 指纹 的 SHA1 前 16 位
    static QString keyFor(const QString &connectionId, const QString &path,
                          const QString &fingerprint);

    const Config &config() const { return m_config; }
    int segmentBytes() const { return m_config.segmentBytes; }
    int segmentIndex(qint64 offset) const;
    qint64 segmentStart(int index) const;

    bool contains(const QString &key, int index) const;
    /// 未命中返回空数组（分片不可能为空，因此空即未命中）
    QByteArray readSegment(const QString &key, int index) const;
    bool writeSegment(const QString &key, int index, const QByteArray &data);

    void writeMeta(const QString &key, const QVariantMap &meta);
    QVariantMap readMeta(const QString &key) const;
    /**
     * 离线反查：按 (connectionId, path) 找最近一次写入的缓存身份。
     * 命中时 meta 含 path/name/size/fingerprint/updatedAt。
     */
    bool findCachedIdentity(const QString &connectionId, const QString &path,
                            QVariantMap *meta) const;

    /// 播放点（字节偏移）：淘汰时据此计算「最远分片」
    void setPlayhead(const QString &key, qint64 byteOffset);

    void removeFile(const QString &key);
    qint64 fileBytes(const QString &key) const;
    /// 已缓存的分片数量（离线起播判断「缓存是否完整」用，只数目录不读内容）
    int segmentCount(const QString &key) const;
    qint64 totalBytes() const;
    qint64 fileLimitBytes() const;

    /**
     * 执行容量约束。
     * @param activeKey 当前播放的缓存键（其播放点附近分片受保护），可空
     * @return 被删除的分片数量
     */
    int enforceLimits(const QString &activeKey = QString());

    QVariantMap stats() const;
    void clear();

private:
    void ensureScanned() const;
    QString dirFor(const QString &key) const;
    QString pathFor(const QString &key, int index) const;
    qint64 playheadFor(const QString &key) const;
    int indexFromName(const QString &fileName) const;
    int evictFarthest(const QString &key, qint64 targetBytes);
    int evictOldest(qint64 targetBytes, const QString &activeKey);

    Config m_config;
    QHash<QString, qint64> m_playheads;

    mutable bool m_scanned = false;
    mutable qint64 m_totalBytes = 0;
    mutable QHash<QString, qint64> m_fileBytes;
};

} // namespace myhub
