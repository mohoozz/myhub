#include "core/text/PlainTextDocument.h"

#include "core/novel/ChapterScan.h"

#include <QString>

namespace myhub {

PlainTextDocument::PlainTextDocument(RangeSource *source)
    : m_source(source)
{}

PlainTextDocument::~PlainTextDocument()
{
    // 只让自己失活，不 cancel 共享的 source（同一本书可能还有别的读取方）
    *m_alive = false;
}

void PlainTextDocument::setProbeBytes(qint64 bytes)
{
    m_probeBytes = qMax<qint64>(4, bytes);
}

void PlainTextDocument::setChunkBytes(qint64 bytes)
{
    m_chunkBytes = qMax<qint64>(4, bytes);
}

QByteArray PlainTextDocument::newlineNeedle(TextCodec::Encoding encoding)
{
    switch (encoding) {
    case TextCodec::Utf16LE:
        return QByteArray("\n\0", 2);
    case TextCodec::Utf16BE:
        return QByteArray("\0\n", 2);
    default:
        return QByteArray(1, '\n');
    }
}

void PlainTextDocument::probe(qint64 fileSize, ProbeCallback callback)
{
    m_size = qMax<qint64>(0, fileSize);
    m_next = 0;
    m_loaded = 0;
    m_ready = false;

    // 空文件也是一篇「空文章」，不是错误
    if (m_size == 0) {
        m_encoding = TextCodec::Utf8;
        m_ready = true;
        callback(StorageError());
        return;
    }

    const qint64 want = qMin(m_probeBytes, m_size);
    const auto alive = m_alive;
    m_source->readRange(0, want, [this, alive, callback](QByteArray data, StorageError error) {
        if (!*alive) {
            return;
        }
        if (!error.isNull()) {
            callback(error);
            return;
        }
        if (data.isEmpty()) {
            callback(StorageError(StorageError::Underlying, QStringLiteral("文件头读取为空")));
            return;
        }

        // 头块按固定大小切，可能切在三字节汉字中间：先修掉不完整 UTF-8 尾巴，
        // 否则严格校验失败会把 UTF-8 误判成 GB18030（然后整本乱码）
        m_encoding = TextCodec::decode(ChapterTextAlign::trimIncompleteUtf8Tail(data)).encoding;
        if (m_encoding == TextCodec::Unknown) {
            m_encoding = TextCodec::Utf8;
        }
        m_ready = true;
        callback(StorageError());
    });
}

void PlainTextDocument::readNext(ChunkCallback callback)
{
    if (!m_ready) {
        callback(Result{
            QString(),
            StorageError(StorageError::InvalidConfig, QStringLiteral("未探测编码，无法分块读取"))});
        return;
    }
    if (atEnd()) {
        callback(Result{QString(), StorageError()});
        return;
    }

    const qint64 start = m_next;
    // 多读一小段，用来把块尾对齐到「下一个换行符之后」。
    // 余量按块大小的 1/8 取：固定加几 KB 会让小块（测试里几十字节）一口气吞下整个文件，
    // 分块就名存实亡了
    const qint64 slack = qMax<qint64>(64, m_chunkBytes / 8);
    const qint64 want = qMin(m_size - start, m_chunkBytes + slack);
    const auto alive = m_alive;
    m_source->readRange(
        start, want, [this, alive, start, callback](QByteArray data, StorageError error) {
            if (!*alive) {
                return;
            }
            if (!error.isNull()) {
                callback(Result{QString(), error});
                return;
            }
            if (data.isEmpty()) {
                // 长度是 stat 来的，读不到内容只能是文件被截短了
                callback(Result{
                    QString(),
                    StorageError(StorageError::Underlying, QStringLiteral("文件内容比预期短"))});
                return;
            }

            const bool last = start + data.size() >= m_size;
            qint64 cut = data.size();
            if (!last) {
                const QByteArray needle = newlineNeedle(m_encoding);
                // 对齐到代码单元：UTF-16 的 0x0A 可能出现在汉字的字节里，奇数位匹配是假换行
                const int unit = ChapterTextAlign::unitSize(m_encoding);
                qint64 from = qMin(m_chunkBytes, data.size() - 1);
                if (unit > 1) {
                    from -= from % unit;
                }
                const qsizetype pos = data.indexOf(needle, static_cast<qsizetype>(from));
                if (pos >= 0) {
                    cut = pos + needle.size();
                } else {
                    // 一整行比「块大小 + 余量」还长：硬切在字符中间会劈开多字节字符，
                    // 先扣掉不完整的尾巴，剩下的交给下一块
                    cut = data.size() - ChapterTextAlign::tailDrop(data, m_encoding);
                    if (cut <= 0) {
                        cut = data.size();
                    }
                }
            }

            const QByteArray piece = data.left(static_cast<qsizetype>(cut));
            m_next = start + cut;
            m_loaded += 1;

            // 块首是上一块换行符之后、块尾是换行符之后，两头都在字符边界上
            const TextCodec::Decoded decoded = TextCodec::decodeAs(piece, m_encoding);
            callback(Result{decoded.text, StorageError()});
        });
}

} // namespace myhub
