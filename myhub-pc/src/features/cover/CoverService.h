#pragma once

#include "core/storage/FileEntry.h"

#include <QDateTime>
#include <QHash>
#include <QObject>
#include <QQmlEngine>
#include <QQueue>
#include <QSet>
#include <QString>
#include <QStringList>

namespace myhub {

class StorageAdapter;

/**
 * 统一封面服务（PC-702）—— 浏览页与「正在阅读」共用同一个组件、同一份缓存。
 *
 * 关键纪律（移植 iOS 端 CoverService 的取舍，适配 M0/M2 现状）：
 *   - **磁盘缓存按「连接 + 路径」稳定键命名**，指纹（size/modTime）只放进
 *     旁挂 meta 校验，这样 QML 侧不带指纹也能同步命中（§7「免 stat 秒出」）
 *   - **in-flight 去重**：同一文件在滚动中反复进入视野只跑一次
 *   - **全局并发上限**：避免远程源被封面请求打满
 *   - **失败 30s 冷却**：失败的请求不进入无限重试循环
 *   - **占位先行**：`cachedCover()` 同步返回，未命中时调用方先画占位再等信号
 *
 * 封面来源优先级：
 *   1. 图片文件自身
 *   2. 内嵌封面（MP3 ID3v2 APIC / FLAC PICTURE / MP4 covr）
 *   3. 音频同目录封面图（同名图 > cover > folder > front）
 *
 * 尚未支持（见 TODO PC-702）：epub 封面、漫画首页、视频抽帧。
 */
class CoverService : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
public:
    static CoverService *create(QQmlEngine *, QJSEngine *);
    static CoverService &instance();

    /// 封面键（贯穿内存 / 磁盘 / 信号）
    Q_INVOKABLE QString coverKey(const QString &connectionId, const QString &path) const;

    /// 同步查缓存：命中返回 file:// URL，未命中返回空串（**不触发 IO 请求**）
    Q_INVOKABLE QString cachedCover(const QString &connectionId, const QString &path);

    /**
     * 异步请求封面。命中缓存时直接发 `coverReady`；
     * 同一键的重复请求只会执行一次（结果广播给所有调用方）。
     *
     * @param size 文件大小（未知传 -1）；用于校验磁盘缓存是否过期
     * @param modSecs 文件修改时间（秒，未知传 -1）
     */
    Q_INVOKABLE void requestCover(const QString &connectionId, const QString &path,
                                  qint64 size = -1, qint64 modSecs = -1);

signals:
    void coverReady(const QString &key, const QString &url);
    void coverFailed(const QString &key);

private:
    struct Job
    {
        QString key;
        QString connectionId;
        QString path;
        qint64 size = -1;
        qint64 modSecs = -1;
    };

    explicit CoverService(QObject *parent = nullptr);
    ~CoverService() override;
    Q_DISABLE_COPY_MOVE(CoverService)

    void dispatch();
    void produce(const Job &job);
    void readImageFile(const Job &job, StorageAdapter *adapter, const QString &path,
                       qint64 knownSize);
    void readEmbeddedCover(const Job &job, StorageAdapter *adapter);
    void readSiblingCover(const Job &job, StorageAdapter *adapter);
    void submitImageBytes(const Job &job, const QByteArray &raw);
    void completeFailure(const Job &job);

    bool lookupCached(const QString &key, qint64 size, qint64 modSecs, QString *url);
    void rememberMemory(const QString &key, const QString &url);

    QString coverFile(const QString &key) const;
    QString metaFile(const QString &key) const;

    QHash<QString, QString> m_memory;
    QStringList m_memoryOrder;
    QHash<QString, QDateTime> m_failedAt;
    QSet<QString> m_inflight;
    QQueue<Job> m_queue;
    int m_running = 0;

    /// 目录列表短缓存：音频同目录封面查找时避免每个文件都 list 一次
    QHash<QString, FileEntryList> m_dirCache;
    QHash<QString, QDateTime> m_dirCacheAt;
};

} // namespace myhub
