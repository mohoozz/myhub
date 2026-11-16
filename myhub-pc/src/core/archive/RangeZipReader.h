#pragma once

#include "core/storage/StorageError.h"
#include "core/stream/RangeSource.h"

#include <QByteArray>
#include <QString>
#include <QVector>

#include <functional>
#include <memory>

namespace myhub {

/// ZIP 中央目录里的一个条目（解包前就能拿到全部元数据）
struct ZipEntry
{
    QString name; ///< 条目全名；'/' 结尾表示目录
    quint32 crc = 0;
    qint64 compressedSize = 0;
    qint64 uncompressedSize = 0;
    quint16 method = 0; ///< 0 = stored，8 = deflate
    qint64 localHeaderOffset = 0;
    bool utf8Name = false;

    bool isDirectory() const { return name.endsWith(QLatin1Char('/')); }
    /// deflate / stored 之外（bzip2、lzma、加密）本类一律不支持
    bool supported() const { return method == 0 || method == 8; }
};

/**
 * 按 Range 读 ZIP / epub / cbz 的只读解包器（PC-205 epub、PC-207 漫画的共同底座）。
 *
 * 核心纪律：**不整包下载**。zip 的目录信息全在文件尾部的中央目录里，
 * 因此「列章节 / 列漫画页」只需要两次小 Range（尾部找 EOCD + 读中央目录），
 * 打开某一章 / 某一页时才去读它自己的那一段压缩数据。
 *
 * 覆盖范围：stored / deflate / ZIP64 / UTF-8 名 / 数据描述符（长度以中央目录为准）。
 * 不覆盖：加密、bzip2、lzma、分卷 —— 遇到时报明确错误，不做静默降级。
 *
 * 回调风格与 `TxtIndexer` 一致：`source` 由调用方持有且必须活得更久；
 * 回调在调用者线程执行；析构后到达的响应由内部活体标记丢弃。
 */
class RangeZipReader
{
public:
    using EntryCallback = std::function<void(QVector<ZipEntry> entries, StorageError error)>;
    using DataCallback = std::function<void(QByteArray data, StorageError error)>;

    /// 单条目解压上限：超过就报错，而不是把内存打爆（漫画单页 / 章节 XHTML 远小于此）
    static constexpr qint64 kMaxEntryBytes = 64 * 1024 * 1024;
    /// 中央目录整体上限：10 万条目也就几 MB，超过这个数说明读到了错误的位置
    static constexpr qint64 kMaxCentralDirectoryBytes = 32 * 1024 * 1024;
    /// 中央目录条目数上限，防「伪造 EOCD」把解析拖死
    static constexpr int kMaxEntries = 200000;

    explicit RangeZipReader(RangeSource *source);
    ~RangeZipReader();

    RangeZipReader(const RangeZipReader &) = delete;
    RangeZipReader &operator=(const RangeZipReader &) = delete;

    /// 解析 EOCD（含 ZIP64）并读出整个中央目录
    void open(EntryCallback cb);
    /// 读一个条目并解压（stored 直取、deflate 用 raw inflate），带 CRC 校验
    void readEntry(const ZipEntry &entry, DataCallback cb);
    void cancel();

    /// 第一个图片条目（按页名自然排序，忽略目录、`__MACOSX/` 与隐藏文件）；没有返回 -1
    static int firstImageEntry(const QVector<ZipEntry> &entries);
    /**
     * 全部图片条目的下标，**已按页名自然排序**（漫画的页序就是它）。
     *
     * 过滤规则与 `firstImageEntry` 完全一致（非图片 / 目录 / `__MACOSX/` /
     * 隐藏的 `._xxx` 资源叉都不算页），因此两者不会对「第一页是哪张」产生分歧。
     */
    static QVector<int> imageEntryIndexes(const QVector<ZipEntry> &entries);
    /// 按全名精确查找（epub 的 href 区分大小写）；没有返回 -1
    static int indexOf(const QVector<ZipEntry> &entries, const QString &name);

private:
    /// `tail` 是含 EOCD 的尾部缓冲，`eocdPos` 是 EOCD 在其内的偏移
    void locateZip64End(const QByteArray &tail, int eocdPos);
    void readCentralDirectory(qint64 cdOffset, qint64 cdSize, qint64 totalEntries);
    void finish(QVector<ZipEntry> entries, const StorageError &error);

    RangeSource *m_source = nullptr;
    EntryCallback m_openCallback;
    quint64 m_serial = 0;
    /// 文件总长度：解包时要拿它做越界校验（RangeSource::size 不会变，缓存一份省得反复问）
    qint64 m_totalSize = -1;

    /// 在途回调可能在对象析构之后才回来：用它判活，避免 use-after-free
    std::shared_ptr<bool> m_alive = std::make_shared<bool>(true);
};

/// 解压 raw deflate（zip 用的无 zlib 头格式）；失败返回空 + error
QByteArray inflateRawDeflate(const QByteArray &input, qint64 expectedSize, QString *error);

} // namespace myhub
