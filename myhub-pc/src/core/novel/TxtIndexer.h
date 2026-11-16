#pragma once

#include "core/novel/NovelIndex.h"
#include "core/storage/StorageError.h"
#include "core/stream/RangeSource.h"

#include <QElapsedTimer>
#include <QHash>

#include <functional>
#include <memory>

namespace myhub {

class ChapterLineScanner;
class ChapterMatcher;

/**
 * txt 流式分章索引（§5.1 PC-201、PC-202）。
 *
 * 流程：读头块探编码 → 顺序分块读全文 → 字节级切行 → 候选行跑规则 → 择优出一条规则。
 *
 * 三条纪律：
 *   1. **不整本读入内存**：一次只持有一个分块（默认 512KB），20MB 的小说也不会
 *      让内存曲线起峰；边读边算，读完就能给出目录。
 *   2. **偏移是原始字节偏移**：见 `ChapterLineScanner`。
 *   3. **编码只探测一次**：整本用同一个编码解码，绝不逐块探测（见 `TextCodec::decodeAs`）。
 *
 * 生命周期：`source` 由调用方持有，必须活得比索引过程长；`cancel()` 只停自己，
 * 不会去注销共享的 source（同一本书可能还有别的读取方）。
 */
class TxtIndexer
{
public:
    struct Result
    {
        NovelIndex index;
        StorageError error;

        bool ok() const { return error.isNull(); }
    };

    using FinishCallback = std::function<void(const Result &)>;
    using ProgressCallback = std::function<void(double ratio)>;

    explicit TxtIndexer(RangeSource *source);
    ~TxtIndexer();

    TxtIndexer(const TxtIndexer &) = delete;
    TxtIndexer &operator=(const TxtIndexer &) = delete;

    /// 探测编码用的头块大小（默认 64KB，够 GB18030/Big5 打分用）
    void setProbeBytes(qint64 bytes);
    /// 扫描分块大小（默认 512KB；测试里调到很小以验证跨块不漂移）
    void setChunkBytes(qint64 bytes);

    /// 文件修改时间（ms）：只用于填充索引指纹，RangeSource 拿不到这个信息
    void setModTime(qint64 modTimeMs) { m_modTime = modTimeMs; }

    void start(FinishCallback onFinish, ProgressCallback onProgress = {});
    void cancel();

    bool running() const { return m_running; }
    /// 探测到的编码；`start()` 之后、回调触发之前就有值
    TextCodec::Encoding encoding() const { return m_encoding; }

private:
    void probe();
    void readNext();
    void consume(const QByteArray &chunk);
    void handleLine(const char *data, qint64 start, qint64 end);
    void complete();
    void finish(Result result);

    RangeSource *m_source = nullptr;
    FinishCallback m_onFinish;
    ProgressCallback m_onProgress;

    qint64 m_probeBytes = 64 * 1024;
    qint64 m_chunkBytes = 512 * 1024;
    qint64 m_offset = 0;
    qint64 m_totalSize = -1;
    qint64 m_modTime = 0;

    TextCodec::Encoding m_encoding = TextCodec::Unknown;
    std::unique_ptr<ChapterLineScanner> m_scanner;
    std::unique_ptr<ChapterMatcher> m_matcher;
    QVector<QVector<NovelChapter>> m_byRule; ///< 下标与 ChapterRules::rules() 对齐
    QHash<QString, int> m_ruleIndex;

    bool m_running = false;
    /// 在途读取回调可能在对象析构之后才回来：用它判活，避免 use-after-free
    std::shared_ptr<bool> m_alive = std::make_shared<bool>(true);
    QElapsedTimer m_clock;
};

} // namespace myhub
