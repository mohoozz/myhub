#include "RangeZipReader.h"

#include "core/archive/PageOrder.h"

#include <QFileInfo>
#include <QStringList>

#include <algorithm>
#include <zlib.h>

namespace myhub {

namespace {

// ZIP 里所有多字节整数都是小端（PKWARE APPNOTE 4.3.1）
constexpr quint32 kEocdSignature = 0x06054b50;         // PK\x05\x06
constexpr quint32 kZip64LocatorSignature = 0x07064b50; // PK\x06\x07
constexpr quint32 kZip64EocdSignature = 0x06064b50;    // PK\x06\x06
constexpr quint32 kCentralSignature = 0x02014b50;      // PK\x01\x02
constexpr quint32 kLocalSignature = 0x04034b50;        // PK\x03\x04

constexpr int kEocdSize = 22;
constexpr int kCentralHeaderSize = 46;
constexpr int kLocalHeaderSize = 30;

constexpr quint32 kZip64Marker32 = 0xFFFFFFFFu;
constexpr quint16 kZip64Marker16 = 0xFFFFu;
constexpr quint16 kZip64ExtraId = 0x0001;
constexpr quint16 kUtf8Flag = 1u << 11;

StorageError corrupt(const QString &reason)
{
    return StorageError(StorageError::InvalidResponse, reason);
}

quint16 readU16(const QByteArray &data, int pos)
{
    const auto *p = reinterpret_cast<const uchar *>(data.constData()) + pos;
    return static_cast<quint16>(p[0] | (p[1] << 8));
}

quint32 readU32(const QByteArray &data, int pos)
{
    const auto *p = reinterpret_cast<const uchar *>(data.constData()) + pos;
    return static_cast<quint32>(p[0]) | (static_cast<quint32>(p[1]) << 8)
        | (static_cast<quint32>(p[2]) << 16) | (static_cast<quint32>(p[3]) << 24);
}

quint64 readU64(const QByteArray &data, int pos)
{
    return static_cast<quint64>(readU32(data, pos))
        | (static_cast<quint64>(readU32(data, pos + 4)) << 32);
}

/// 从尾部缓冲区找出 EOCD 位置；`strictComment` 要求注释长度与缓冲区严丝合缝
int findEocd(const QByteArray &tail, bool strictComment)
{
    // 从最靠后的位置往前找：注释里可能恰好出现签名字节，最后那个才是真的
    for (int pos = tail.size() - kEocdSize; pos >= 0; --pos) {
        if (readU32(tail, pos) != kEocdSignature) {
            continue;
        }
        const int commentLength = readU16(tail, pos + 20);
        if (pos + kEocdSize + commentLength == tail.size()) {
            return pos;
        }
        if (!strictComment && pos + kEocdSize + commentLength <= tail.size()) {
            return pos;
        }
    }
    return -1;
}

/**
 * 条目名解码。
 *
 * zip 只在「通用标志位 11」置位时保证是 UTF-8；老工具写的 GBK 名在 Windows 上
 * 会被误当 UTF-8 解成一片替换符，所以退一步用 Latin-1 保持字节可比对 —— 反正
 * epub 内部 href 是 UTF-8，漫画页名是 ASCII，真正需要中文名的场景很少。
 */
QString decodeEntryName(const QByteArray &raw, bool utf8Flag)
{
    if (utf8Flag) {
        return QString::fromUtf8(raw);
    }
    QString asUtf8 = QString::fromUtf8(raw);
    if (!asUtf8.contains(QChar(QChar::ReplacementCharacter))) {
        return asUtf8;
    }
    return QString::fromLatin1(raw);
}

/// 解析中央目录；遇到不认识的签名就停（末尾可能跟数字签名块）
QVector<ZipEntry> parseCentralDirectory(const QByteArray &data, QString *error)
{
    QVector<ZipEntry> entries;
    int pos = 0;
    while (pos + kCentralHeaderSize <= data.size()) {
        if (readU32(data, pos) != kCentralSignature) {
            break;
        }
        const quint16 flags = readU16(data, pos + 8);
        const quint16 method = readU16(data, pos + 10);
        const int nameLength = readU16(data, pos + 28);
        const int extraLength = readU16(data, pos + 30);
        const int commentLength = readU16(data, pos + 32);
        const int next = pos + kCentralHeaderSize + nameLength + extraLength + commentLength;
        if (pos + kCentralHeaderSize + nameLength > data.size()) {
            *error = QStringLiteral("中央目录条目越界（文件可能被截断）");
            return {};
        }

        ZipEntry entry;
        entry.name = decodeEntryName(data.mid(pos + kCentralHeaderSize, nameLength),
                                     (flags & kUtf8Flag) != 0);
        entry.utf8Name = (flags & kUtf8Flag) != 0;
        entry.method = method;
        entry.crc = readU32(data, pos + 16);
        entry.compressedSize = readU32(data, pos + 20);
        entry.uncompressedSize = readU32(data, pos + 24);
        entry.localHeaderOffset = readU32(data, pos + 42);

        // ZIP64：字段被写成 0xFFFFFFFF 时，真值在 extra id 0x0001 里，按 usize → csize → lho 顺序
        if (entry.uncompressedSize == kZip64Marker32 || entry.compressedSize == kZip64Marker32
            || entry.localHeaderOffset == kZip64Marker32) {
            int extraPos = pos + kCentralHeaderSize + nameLength;
            const int extraEnd = extraPos + extraLength;
            while (extraPos + 4 <= extraEnd) {
                const quint16 id = readU16(data, extraPos);
                const quint16 size = readU16(data, extraPos + 2);
                if (id == kZip64ExtraId) {
                    int cursor = extraPos + 4;
                    const int limit = cursor + size;
                    if (entry.uncompressedSize == kZip64Marker32 && cursor + 8 <= limit) {
                        entry.uncompressedSize = static_cast<qint64>(readU64(data, cursor));
                        cursor += 8;
                    }
                    if (entry.compressedSize == kZip64Marker32 && cursor + 8 <= limit) {
                        entry.compressedSize = static_cast<qint64>(readU64(data, cursor));
                        cursor += 8;
                    }
                    if (entry.localHeaderOffset == kZip64Marker32 && cursor + 8 <= limit) {
                        entry.localHeaderOffset = static_cast<qint64>(readU64(data, cursor));
                    }
                    break;
                }
                extraPos += 4 + size;
            }
        }

        if (entry.localHeaderOffset < 0 || entry.compressedSize < 0 || entry.uncompressedSize < 0) {
            *error = QStringLiteral("中央目录条目字段非法（ZIP64 扩展缺失）");
            return {};
        }

        entries.append(entry);
        pos = next;
    }

    if (entries.isEmpty()) {
        *error = QStringLiteral("中央目录为空（不是有效的 zip）");
    }
    return entries;
}

} // namespace

QByteArray inflateRawDeflate(const QByteArray &input, qint64 expectedSize, QString *error)
{
    const auto fail = [error](const QString &reason) {
        if (error) {
            *error = reason;
        }
        return QByteArray();
    };

    if (expectedSize < 0 || expectedSize > RangeZipReader::kMaxEntryBytes) {
        return fail(QStringLiteral("条目解压后长度非法"));
    }

    z_stream stream{};
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) {
        return fail(QStringLiteral("初始化解压器失败"));
    }

    // 目录里给了确切长度就直接按它分配；给了 0（少见）才边解边扩
    QByteArray out;
    out.resize(static_cast<int>(expectedSize > 0 ? expectedSize
                                                 : qMin<qint64>(input.size() * 4 + 4096, 1 << 20)));
    // zlib 的 next_in 是 Bytef*（老式 API 不认 const），但 inflate 只读它 —— 契约如此
    stream.next_in = reinterpret_cast<Bytef *>(const_cast<char *>(input.constData())); // NOLINT
    stream.avail_in = static_cast<uInt>(input.size());

    int produced = 0;
    int result = Z_OK;
    for (;;) {
        if (produced == out.size()) {
            const qint64 grown = qMin<qint64>(static_cast<qint64>(out.size()) * 2 + 4096,
                                              RangeZipReader::kMaxEntryBytes);
            if (grown <= out.size()) {
                result = Z_MEM_ERROR;
                break;
            }
            out.resize(static_cast<int>(grown));
        }
        stream.next_out = reinterpret_cast<Bytef *>(out.data() + produced);
        stream.avail_out = static_cast<uInt>(out.size() - produced);
        result = inflate(&stream, Z_NO_FLUSH);
        produced = out.size() - static_cast<int>(stream.avail_out);
        if (result == Z_STREAM_END) {
            break;
        }
        if (result == Z_OK) {
            continue;
        }
        if (result == Z_BUF_ERROR && stream.avail_out == 0) {
            continue; // 输出缓冲用完了，回到上面扩容
        }
        break;
    }
    inflateEnd(&stream);

    if (result != Z_STREAM_END) {
        // 短读（Range 少给了几十字节）在这里暴露，比 CRC 更早、更好定位
        return fail(QStringLiteral("压缩数据不完整或已损坏（可能是传输截断）"));
    }
    out.resize(produced);
    if (expectedSize > 0 && produced != expectedSize) {
        return fail(QStringLiteral("解压后长度与目录不一致"));
    }
    return out;
}

RangeZipReader::RangeZipReader(RangeSource *source)
    : m_source(source)
{
    Q_ASSERT(m_source);
}

RangeZipReader::~RangeZipReader()
{
    *m_alive = false;
    m_source = nullptr;
    m_openCallback = nullptr;
}

void RangeZipReader::cancel()
{
    ++m_serial;
    m_openCallback = nullptr;
}

void RangeZipReader::open(EntryCallback cb)
{
    m_openCallback = std::move(cb);
    const quint64 serial = ++m_serial;

    if (!m_source) {
        finish({}, StorageError(StorageError::InvalidPath, QStringLiteral("未绑定数据源")));
        return;
    }
    const qint64 total = m_source->size();
    if (total < 0) {
        finish({}, corrupt(QStringLiteral("无法获取文件长度，不能解析 zip")));
        return;
    }
    if (total < kEocdSize) {
        finish({}, corrupt(QStringLiteral("不是 zip 文件：文件太小")));
        return;
    }
    m_totalSize = total;

    // 只有尾部可能藏着 EOCD（22 字节定长头 + 最多 65535 字节注释）
    const qint64 tailLength = qMin<qint64>(total, kEocdSize + 65535);
    const qint64 tailStart = total - tailLength;
    const auto alive = m_alive;
    m_source->readRange(
        tailStart, tailLength,
        [this, alive, serial, tailLength](QByteArray tail, StorageError error) {
            if (!*alive || serial != m_serial) {
                return;
            }
            if (!error.isNull()) {
                finish({}, error);
                return;
            }
            if (tail.size() != tailLength) {
                finish({}, corrupt(QStringLiteral("读取文件尾部失败（可能是传输截断）")));
                return;
            }

            int pos = findEocd(tail, true);
            if (pos < 0) {
                pos = findEocd(tail, false);
            }
            if (pos < 0) {
                finish({}, corrupt(QStringLiteral("不是 zip 文件：找不到目录结尾记录")));
                return;
            }

            const quint16 entriesOnDisk = readU16(tail, pos + 8);
            const quint16 totalEntries = readU16(tail, pos + 10);
            const quint32 cdSize = readU32(tail, pos + 12);
            const quint32 cdOffset = readU32(tail, pos + 16);

            const bool needsZip64 = entriesOnDisk == kZip64Marker16
                || totalEntries == kZip64Marker16 || cdSize == kZip64Marker32
                || cdOffset == kZip64Marker32;
            if (needsZip64) {
                locateZip64End(tail, pos);
                return;
            }
            readCentralDirectory(cdOffset, cdSize, totalEntries);
        });
}

void RangeZipReader::locateZip64End(const QByteArray &tail, int eocdPos)
{
    const int locatorPos = eocdPos - 20;
    if (locatorPos < 0 || readU32(tail, locatorPos) != kZip64LocatorSignature) {
        finish({}, corrupt(QStringLiteral("ZIP64 目录定位记录缺失")));
        return;
    }
    const quint64 zip64Offset = readU64(tail, locatorPos + 8);
    if (zip64Offset < 0 || static_cast<qint64>(zip64Offset) >= m_totalSize) {
        finish({}, corrupt(QStringLiteral("ZIP64 目录偏移越界")));
        return;
    }

    const auto alive = m_alive;
    const quint64 serial = m_serial;
    // 56 字节足够覆盖到「中央目录偏移」字段（固定头 56 字节，扩展数据在后面）
    m_source->readRange(static_cast<qint64>(zip64Offset), 56,
                        [this, alive, serial](QByteArray record, StorageError error) {
                            if (!*alive || serial != m_serial) {
                                return;
                            }
                            if (!error.isNull()) {
                                finish({}, error);
                                return;
                            }
                            if (record.size() < 56 || readU32(record, 0) != kZip64EocdSignature) {
                                finish({}, corrupt(QStringLiteral("ZIP64 目录结尾记录损坏")));
                                return;
                            }
                            const quint64 totalEntries = readU64(record, 32);
                            const quint64 cdSize = readU64(record, 40);
                            const quint64 cdOffset = readU64(record, 48);
                            readCentralDirectory(static_cast<qint64>(cdOffset),
                                                 static_cast<qint64>(cdSize),
                                                 static_cast<qint64>(totalEntries));
                        });
}

void RangeZipReader::readCentralDirectory(qint64 cdOffset, qint64 cdSize, qint64 totalEntries)
{
    if (cdOffset < 0 || cdSize <= 0 || cdOffset + cdSize > m_totalSize) {
        finish({}, corrupt(QStringLiteral("中央目录位置非法（文件可能被截断）")));
        return;
    }
    if (cdSize > kMaxCentralDirectoryBytes) {
        finish({}, corrupt(QStringLiteral("中央目录过大（%1 字节）").arg(cdSize)));
        return;
    }
    if (totalEntries > kMaxEntries) {
        finish({}, corrupt(QStringLiteral("条目数异常（%1）").arg(totalEntries)));
        return;
    }

    const auto alive = m_alive;
    const quint64 serial = m_serial;
    m_source->readRange(
        cdOffset, cdSize, [this, alive, serial](QByteArray data, StorageError error) {
            if (!*alive || serial != m_serial) {
                return;
            }
            if (!error.isNull()) {
                finish({}, error);
                return;
            }
            QString parseError;
            QVector<ZipEntry> entries = parseCentralDirectory(data, &parseError);
            finish(entries, parseError.isEmpty() ? StorageError() : corrupt(parseError));
        });
}

void RangeZipReader::finish(QVector<ZipEntry> entries, const StorageError &error)
{
    EntryCallback callback = std::move(m_openCallback);
    m_openCallback = nullptr;
    if (callback) {
        callback(std::move(entries), error);
    }
}

void RangeZipReader::readEntry(const ZipEntry &entry, DataCallback cb)
{
    if (!m_source || m_totalSize <= 0) {
        cb(QByteArray(), StorageError(StorageError::InvalidPath, QStringLiteral("未打开 zip")));
        return;
    }
    if (entry.isDirectory()) {
        cb(QByteArray(), corrupt(QStringLiteral("这是目录条目，不是文件")));
        return;
    }
    if (!entry.supported()) {
        cb(QByteArray(),
           StorageError(StorageError::UnsupportedProtocol,
                        QStringLiteral("暂不支持该压缩方式（仅 stored / deflate）")));
        return;
    }
    if (entry.compressedSize <= 0 || entry.compressedSize > kMaxEntryBytes) {
        cb(QByteArray(),
           corrupt(QStringLiteral("条目压缩长度非法（%1）").arg(entry.compressedSize)));
        return;
    }

    const auto alive = m_alive;
    // 先读本地文件头：数据起点 = 本地头 + 30 + 文件名 + 扩展字段
    // （中央目录里的 extra 长度和本地头的不一定相同，只能以本地头为准）
    m_source->readRange(
        entry.localHeaderOffset, kLocalHeaderSize,
        [this, alive, entry, cb](QByteArray header, StorageError error) {
            if (!*alive) {
                return;
            }
            if (!error.isNull()) {
                cb(QByteArray(), error);
                return;
            }
            if (header.size() < kLocalHeaderSize || readU32(header, 0) != kLocalSignature) {
                cb(QByteArray(), corrupt(QStringLiteral("本地文件头损坏")));
                return;
            }
            const int nameLength = readU16(header, 26);
            const int extraLength = readU16(header, 28);
            const qint64 dataOffset =
                entry.localHeaderOffset + kLocalHeaderSize + nameLength + extraLength;
            if (dataOffset + entry.compressedSize > m_totalSize) {
                cb(QByteArray(), corrupt(QStringLiteral("条目数据越界（文件可能被截断）")));
                return;
            }
            m_source->readRange(
                dataOffset, entry.compressedSize,
                [this, alive, entry, cb](QByteArray raw, StorageError readError) {
                    if (!*alive) {
                        return;
                    }
                    if (!readError.isNull()) {
                        cb(QByteArray(), readError);
                        return;
                    }
                    if (raw.size() != entry.compressedSize) {
                        cb(QByteArray(),
                           corrupt(QStringLiteral("条目读取不完整（可能是传输截断）")));
                        return;
                    }

                    QByteArray out = raw;
                    if (entry.method == 8) {
                        QString inflateError;
                        out = inflateRawDeflate(raw, entry.uncompressedSize, &inflateError);
                        if (!inflateError.isEmpty()) {
                            cb(QByteArray(), corrupt(inflateError));
                            return;
                        }
                    } else if (out.size() != entry.uncompressedSize) {
                        cb(QByteArray(), corrupt(QStringLiteral("stored 条目长度不符")));
                        return;
                    }

                    const uLong check = crc32(crc32(0L, Z_NULL, 0),
                                              reinterpret_cast<const Bytef *>(out.constData()),
                                              static_cast<uInt>(out.size()));
                    if (static_cast<quint32>(check) != entry.crc) {
                        cb(QByteArray(),
                           corrupt(QStringLiteral("条目 CRC 校验失败（数据已损坏）")));
                        return;
                    }
                    cb(out, StorageError());
                });
        });
}

int RangeZipReader::firstImageEntry(const QVector<ZipEntry> &entries)
{
    const QVector<int> pages = imageEntryIndexes(entries);
    return pages.isEmpty() ? -1 : pages.constFirst();
}

QVector<int> RangeZipReader::imageEntryIndexes(const QVector<ZipEntry> &entries)
{
    // 页序规则与 rar 侧（`ArchiveReader::pageIndexes`）共用 `pageorder`：
    // 同一本书换个压缩格式，页序与第一页必须完全一致
    QStringList names;
    names.reserve(entries.size());
    for (const ZipEntry &entry : entries) {
        names.append(entry.name);
    }
    return pageorder::sortedPageIndexes(names);
}

int RangeZipReader::indexOf(const QVector<ZipEntry> &entries, const QString &name)
{
    for (int i = 0; i < entries.size(); ++i) {
        if (entries.at(i).name == name) {
            return i;
        }
    }
    return -1;
}

} // namespace myhub
