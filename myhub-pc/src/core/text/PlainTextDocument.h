#pragma once

#include "core/storage/StorageError.h"
#include "core/stream/RangeSource.h"
#include "core/text/TextCodec.h"

#include <QByteArray>
#include <QString>

#include <functional>
#include <memory>

namespace myhub {

/**
 * 纯文本阅读器的取文器（PC-210，第 4 条阅读路由）。
 *
 * 只负责一件事：把一个可能几十 MB 的文本文件切成**整行对齐**的块，按需向后读。
 * 不建索引、不落库、不记进度 —— 需要章节与进度时走小说阅读器（NovelBridge）。
 *
 * 分块规则（保证不丢行、不重行）：
 *   第 k 块起点 = 第 k-1 块终点；终点 = 从「起点 + chunkBytes」起**第一个换行符之后**。
 * 于是每块都以整行开头、以整行结尾，块与块首尾相接。换行符本身是完整字符，
 * 所以任何一块单独解码都不会劈开多字节字符 —— 不需要逐块跑编码检测（那会抖，见
 * `TextCodec::decodeAs` 的注释），整本沿用第一次探测出的编码。
 *
 * 换行符按编码取字节序列：UTF-16 的 `\n` 是 2 字节，按单字节 0x0A 扫会把
 * 汉字高位字节误当换行（U+4E0A 的 LE 编码里就有 0x0A）。GB18030 / Big5 的
 * 尾字节区间不含 0x0A，单字节扫是安全的。
 *
 * 生命周期：`source` 由调用方持有，必须活得比本文档长；异步回调可能在本对象析构后
 * 才回来，故内部用 `m_alive` 判活（与 TxtIndexer 同一套纪律）。
 */
class PlainTextDocument
{
public:
    struct Result
    {
        /// 这一块的全部整行；到文件尾时为空
        QString text;
        StorageError error;

        bool ok() const { return error.isNull(); }
    };

    using ChunkCallback = std::function<void(const Result &)>;
    using ProbeCallback = std::function<void(const StorageError &)>;

    explicit PlainTextDocument(RangeSource *source);
    ~PlainTextDocument();

    PlainTextDocument(const PlainTextDocument &) = delete;
    PlainTextDocument &operator=(const PlainTextDocument &) = delete;

    /// 探测编码用的头块大小（默认 64KB，够 GB18030/Big5 打分用）
    void setProbeBytes(qint64 bytes);
    /// 分块目标大小（默认 64KB；测试里调到很小以验证跨块边界）
    void setChunkBytes(qint64 bytes);

    /**
     * 读头块探编码。成功后 `encoding()` 才有意义。
     * 空文件直接成功（阅读器显示空页，不当错误）。
     */
    void probe(qint64 fileSize, ProbeCallback callback);

    TextCodec::Encoding encoding() const { return m_encoding; }
    QString encodingName() const { return TextCodec::name(m_encoding); }
    qint64 fileSize() const { return m_size; }
    /// 已读到的字节位置（下一块的起点）
    qint64 loadedBytes() const { return m_next; }
    bool atEnd() const { return m_next >= m_size; }
    int loadedCount() const { return m_loaded; }

    /// 读下一块。未 `probe()` 成功前调用会回调 InvalidConfig
    void readNext(ChunkCallback callback);

private:
    /// 换行符在该编码下占的字节数
    static QByteArray newlineNeedle(TextCodec::Encoding encoding);

    RangeSource *m_source = nullptr;

    qint64 m_probeBytes = 64 * 1024;
    qint64 m_chunkBytes = 64 * 1024;
    qint64 m_size = 0;
    qint64 m_next = 0;

    TextCodec::Encoding m_encoding = TextCodec::Unknown;
    bool m_ready = false;
    int m_loaded = 0;

    /// 在途回调可能在析构之后才回来：用它判活
    std::shared_ptr<bool> m_alive = std::make_shared<bool>(true);
};

} // namespace myhub
