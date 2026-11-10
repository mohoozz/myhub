#include "core/cover/EmbeddedCoverExtractor.h"

#include <QtGlobal>

#include <algorithm>
#include <cstring>

namespace myhub {
namespace {

/// 单张封面的硬上限：超过视为异常数据，直接放弃
constexpr int kMaxCoverBytes = 16 * 1024 * 1024;

quint32 be24(const char *p)
{
    return (static_cast<quint32>(static_cast<quint8>(p[0])) << 16)
        | (static_cast<quint32>(static_cast<quint8>(p[1])) << 8)
        | static_cast<quint32>(static_cast<quint8>(p[2]));
}

quint32 be32(const char *p)
{
    return (static_cast<quint32>(static_cast<quint8>(p[0])) << 24)
        | (static_cast<quint32>(static_cast<quint8>(p[1])) << 16)
        | (static_cast<quint32>(static_cast<quint8>(p[2])) << 8)
        | static_cast<quint32>(static_cast<quint8>(p[3]));
}

quint64 be64(const char *p)
{
    return (static_cast<quint64>(be32(p)) << 32) | static_cast<quint64>(be32(p + 4));
}

/// ID3v2 的 7-bit「syncsafe」整数（v2.4 的帧长度与标签长度都用它）
quint32 syncSafe32(const char *p)
{
    return (static_cast<quint32>(static_cast<quint8>(p[0]) & 0x7f) << 21)
        | (static_cast<quint32>(static_cast<quint8>(p[1]) & 0x7f) << 14)
        | (static_cast<quint32>(static_cast<quint8>(p[2]) & 0x7f) << 7)
        | static_cast<quint32>(static_cast<quint8>(p[3]) & 0x7f);
}

/// 是否像一张真实图片（封面标签里也可能塞进垃圾数据）
bool looksLikeImage(const QByteArray &data)
{
    if (data.size() < 4 || data.size() > kMaxCoverBytes) {
        return false;
    }
    const char *p = data.constData();
    if (static_cast<quint8>(p[0]) == 0xff && static_cast<quint8>(p[1]) == 0xd8
        && static_cast<quint8>(p[2]) == 0xff) {
        return true; // JPEG
    }
    if (std::memcmp(p, "\x89PNG", 4) == 0) {
        return true;
    }
    if (std::memcmp(p, "GIF8", 4) == 0) {
        return true;
    }
    if (std::memcmp(p, "RIFF", 4) == 0 && data.size() >= 12 && std::memcmp(p + 8, "WEBP", 4) == 0) {
        return true;
    }
    if (std::memcmp(p, "BM", 2) == 0) {
        return true;
    }
    return false;
}

// ---------------------------------------------------------------- ID3v2 ----

/// 从 APIC/PIC 帧体里切出图片字节
QByteArray apicPayload(const QByteArray &frame, bool v22)
{
    if (frame.size() < 4) {
        return {};
    }
    const quint8 encoding = static_cast<quint8>(frame.at(0));
    int pos = 1;
    if (v22) {
        pos += 3; // 3 字节图片格式（"JPG"/"PNG"），不是 MIME
    } else {
        const int mimeEnd = frame.indexOf('\0', pos);
        if (mimeEnd < 0) {
            return {};
        }
        pos = mimeEnd + 1;
    }
    if (pos >= frame.size()) {
        return {};
    }
    ++pos; // 图片类型（3 = front cover）

    // 描述文本按 encoding 决定终止符宽度：UTF-16 为双字节 0
    const int termWidth = (encoding == 1 || encoding == 2) ? 2 : 1;
    int descEnd = -1;
    for (int i = pos; i + termWidth <= frame.size(); ++i) {
        bool terminator = true;
        for (int k = 0; k < termWidth; ++k) {
            if (frame.at(i + k) != '\0') {
                terminator = false;
                break;
            }
        }
        if (terminator) {
            descEnd = i;
            break;
        }
    }
    if (descEnd < 0) {
        return {};
    }
    const int dataPos = descEnd + termWidth;
    if (dataPos >= frame.size()) {
        return {};
    }
    return frame.mid(dataPos);
}

QByteArray coverFromId3(const QByteArray &head)
{
    if (head.size() < 10 || head.left(3) != "ID3") {
        return {};
    }
    const int version = static_cast<int>(static_cast<quint8>(head.at(3)));
    if (version < 2 || version > 4) {
        return {};
    }
    const quint8 flags = static_cast<quint8>(head.at(5));
    const qint64 tagEnd = 10 + static_cast<qint64>(syncSafe32(head.constData() + 6));
    if (tagEnd <= 10 || tagEnd > head.size()) {
        return {}; // 标签体不完整（头部片段不够）
    }

    qint64 pos = 10;
    if ((flags & 0x10) != 0) { // 扩展头
        if (pos + 4 > tagEnd) {
            return {};
        }
        const qint64 extSize = (version == 4)
            ? static_cast<qint64>(syncSafe32(head.constData() + pos))
            : static_cast<qint64>(be32(head.constData() + pos)) + 4;
        pos += extSize;
    }

    const bool v22 = (version == 2);
    const int headerLen = v22 ? 6 : 10;
    while (pos + headerLen <= tagEnd) {
        const QByteArray id = head.mid(static_cast<int>(pos), v22 ? 3 : 4);
        if (id.isEmpty() || id.at(0) == '\0') {
            break; // padding 区
        }
        qint64 frameSize = 0;
        if (v22) {
            frameSize = static_cast<qint64>(be24(head.constData() + pos + 3));
        } else if (version == 4) {
            frameSize = static_cast<qint64>(syncSafe32(head.constData() + pos + 4));
        } else {
            frameSize = static_cast<qint64>(be32(head.constData() + pos + 4));
        }
        if (frameSize <= 0) {
            break;
        }
        const qint64 dataStart = pos + headerLen;
        if (dataStart + frameSize > tagEnd) {
            break;
        }
        if (id == "APIC" || (v22 && id == "PIC")) {
            const QByteArray image = apicPayload(
                head.mid(static_cast<int>(dataStart), static_cast<int>(frameSize)), v22);
            if (looksLikeImage(image)) {
                return image;
            }
        }
        pos = dataStart + frameSize;
    }
    return {};
}

// ------------------------------------------------------------------ FLAC ----

QByteArray pictureBlockPayload(const QByteArray &block)
{
    const int size = block.size();
    if (size < 8) {
        return {};
    }
    const char *p = block.constData();
    int pos = 4; // picture type
    if (pos + 4 > size) {
        return {};
    }
    const quint32 mimeLen = be32(p + pos);
    pos += 4;
    if (mimeLen > static_cast<quint32>(size - pos)) {
        return {};
    }
    pos += static_cast<int>(mimeLen);

    if (pos + 4 > size) {
        return {};
    }
    const quint32 descLen = be32(p + pos);
    pos += 4;
    if (descLen > static_cast<quint32>(size - pos)) {
        return {};
    }
    pos += static_cast<int>(descLen);
    pos += 16; // width / height / depth / colors

    if (pos + 4 > size) {
        return {};
    }
    const quint32 dataLen = be32(p + pos);
    pos += 4;
    if (dataLen == 0 || dataLen > static_cast<quint32>(size - pos)) {
        return {};
    }
    return block.mid(pos, static_cast<int>(dataLen));
}

QByteArray coverFromFlac(const QByteArray &head)
{
    if (head.size() < 8 || head.left(4) != "fLaC") {
        return {};
    }
    int pos = 4;
    while (pos + 4 <= head.size()) {
        const quint8 typeByte = static_cast<quint8>(head.at(pos));
        const int type = typeByte & 0x7f;
        const qint64 len = static_cast<qint64>(be24(head.constData() + pos + 1));
        const qint64 dataPos = pos + 4;
        if (dataPos + len > head.size()) {
            return {}; // 元数据块超出片段
        }
        if (type == 6) {
            const QByteArray image =
                pictureBlockPayload(head.mid(static_cast<int>(dataPos), static_cast<int>(len)));
            if (looksLikeImage(image)) {
                return image;
            }
        }
        if ((typeByte & 0x80) != 0) {
            break; // 最后一个块
        }
        pos = static_cast<int>(dataPos + len);
    }
    return {};
}

// ------------------------------------------------------------------- MP4 ----

/**
 * 在父盒子的子盒子列表里找指定类型，返回**内容**（去掉盒子头）。
 * @param scanOffset 子盒子列表的起点（`meta` 是 FullBox，要跳过 4 字节 version/flags）
 */
QByteArray findChildBox(const QByteArray &parent, const char *name, int scanOffset = 0)
{
    const int size = parent.size();
    int pos = scanOffset;
    while (pos + 8 <= size) {
        quint64 boxSize = be32(parent.constData() + pos);
        const QByteArray type = parent.mid(pos + 4, 4);
        int headerLen = 8;
        if (boxSize == 1) { // 64 位长度
            if (pos + 16 > size) {
                return {};
            }
            boxSize = be64(parent.constData() + pos + 8);
            headerLen = 16;
        } else if (boxSize == 0) { // 延伸到父盒子末尾
            boxSize = static_cast<quint64>(size - pos);
        }
        if (boxSize < static_cast<quint64>(headerLen)
            || static_cast<qint64>(boxSize) > static_cast<qint64>(size - pos)) {
            return {};
        }
        if (type == name) {
            return parent.mid(pos + headerLen, static_cast<int>(boxSize) - headerLen);
        }
        pos += static_cast<int>(boxSize);
    }
    return {};
}

/// 头部片段里按顶层盒子跳读找 `moov`
QByteArray moovFromHead(const QByteArray &head)
{
    const int size = head.size();
    int pos = 0;
    while (pos + 8 <= size) {
        quint64 boxSize = be32(head.constData() + pos);
        const QByteArray type = head.mid(pos + 4, 4);
        int headerLen = 8;
        if (boxSize == 1) {
            if (pos + 16 > size) {
                return {};
            }
            boxSize = be64(head.constData() + pos + 8);
            headerLen = 16;
        } else if (boxSize == 0) {
            boxSize = static_cast<quint64>(size - pos);
        }
        if (boxSize < static_cast<quint64>(headerLen)) {
            return {};
        }
        if (type == "moov") {
            if (static_cast<qint64>(boxSize) > static_cast<qint64>(size - pos)) {
                return {}; // moov 尾部被截断
            }
            return head.mid(pos, static_cast<int>(boxSize));
        }
        pos += static_cast<int>(boxSize);
    }
    return {};
}

/**
 * moov 常被写在文件末尾（非 faststart 文件）：在尾部片段里**倒序**搜索
 * "moov" 签名，并用其前 4 字节长度做校验，命中即取该盒子。
 */
QByteArray moovFromTail(const QByteArray &tail)
{
    if (tail.size() < 16) {
        return {};
    }
    const char *data = tail.constData();
    for (int i = tail.size() - 4; i >= 4; --i) {
        if (std::memcmp(data + i, "moov", 4) != 0) {
            continue;
        }
        const int boxStart = i - 4;
        quint64 boxSize = be32(data + boxStart);
        int headerLen = 8;
        if (boxSize == 1) {
            if (boxStart + 16 > tail.size()) {
                continue;
            }
            boxSize = be64(data + boxStart + 8);
            headerLen = 16;
        }
        if (boxSize < static_cast<quint64>(headerLen)
            || static_cast<qint64>(boxSize) > static_cast<qint64>(tail.size() - boxStart)) {
            continue;
        }
        return tail.mid(boxStart, static_cast<int>(boxSize));
    }
    return {};
}

QByteArray coverFromMoov(const QByteArray &moov)
{
    if (moov.isEmpty()) {
        return {};
    }
    // 传入的是完整 moov 盒子，子盒子列表从 8 字节头之后开始
    const QByteArray udta = findChildBox(moov, "udta", 8);
    if (udta.isEmpty()) {
        return {};
    }
    const QByteArray meta = findChildBox(udta, "meta");
    if (meta.isEmpty() || meta.size() < 8) {
        return {};
    }
    const QByteArray ilst = findChildBox(meta, "ilst", 4);
    if (ilst.isEmpty()) {
        return {};
    }
    const QByteArray covr = findChildBox(ilst, "covr");
    if (covr.isEmpty()) {
        return {};
    }
    // covr 内可以有多个 data 盒子（JPEG/PNG 各一），逐个尝试
    int pos = 0;
    while (pos + 8 <= covr.size()) {
        const quint64 boxSize = be32(covr.constData() + pos);
        if (boxSize < 16 || static_cast<qint64>(boxSize) > static_cast<qint64>(covr.size() - pos)) {
            break;
        }
        const QByteArray content = covr.mid(pos + 8, static_cast<int>(boxSize) - 8);
        // data 内容是 [4 字节类型][4 字节 locale][图片字节]
        if (content.size() > 8) {
            const QByteArray image = content.mid(8);
            if (looksLikeImage(image)) {
                return image;
            }
        }
        pos += static_cast<int>(boxSize);
    }
    return {};
}

} // namespace

qint64 EmbeddedCoverExtractor::headLength(qint64 fileSize)
{
    if (fileSize <= 0) {
        return kHeadBytes;
    }
    return std::min(fileSize, kHeadBytes);
}

qint64 EmbeddedCoverExtractor::tailOffset(qint64 fileSize)
{
    if (fileSize <= kHeadBytes) {
        return 0;
    }
    return fileSize - std::min(fileSize, kTailBytes);
}

bool EmbeddedCoverExtractor::supports(const QString &ext)
{
    return ext == QLatin1String("mp3") || ext == QLatin1String("flac")
        || ext == QLatin1String("m4a") || ext == QLatin1String("mp4") || ext == QLatin1String("m4v")
        || ext == QLatin1String("mov") || ext == QLatin1String("aac");
}

QByteArray EmbeddedCoverExtractor::extract(const QString &ext, qint64 fileSize,
                                           const QByteArray &head, const QByteArray &tail)
{
    Q_UNUSED(fileSize)
    if (head.isEmpty() || !supports(ext)) {
        return {};
    }
    if (ext == QLatin1String("mp3") || ext == QLatin1String("aac")) {
        return coverFromId3(head);
    }
    if (ext == QLatin1String("flac")) {
        return coverFromFlac(head);
    }
    QByteArray moov = moovFromHead(head);
    if (moov.isEmpty()) {
        if (!tail.isEmpty()) {
            moov = moovFromTail(tail);
        }
    }
    QByteArray image = coverFromMoov(moov);
    if (!image.isEmpty()) {
        return image;
    }
    // 少数文件把封面塞在 ID3 头里（如带 ID3 的 aac/m4a），再兜一次
    return coverFromId3(head);
}

} // namespace myhub
