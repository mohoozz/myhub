#include "TxtIndexer.h"

#include "core/novel/ChapterScan.h"
#include "core/utils/AppLogger.h"

namespace myhub {

namespace {

StorageError shortReadError()
{
    return StorageError(StorageError::InvalidResponse,
                        QStringLiteral("读取中断：文件长度与内容不一致"));
}

} // namespace

TxtIndexer::TxtIndexer(RangeSource *source)
    : m_source(source)
{
    Q_ASSERT(m_source);
    for (int i = 0; i < ChapterRules::rules().size(); ++i) {
        m_ruleIndex.insert(ChapterRules::rules().at(i).id, i);
    }
}

TxtIndexer::~TxtIndexer()
{
    m_running = false;
    *m_alive = false;
    m_source = nullptr;
}

void TxtIndexer::setProbeBytes(qint64 bytes)
{
    m_probeBytes = qMax<qint64>(4, bytes);
}

void TxtIndexer::setChunkBytes(qint64 bytes)
{
    m_chunkBytes = qMax<qint64>(4, bytes);
}

void TxtIndexer::start(FinishCallback onFinish, ProgressCallback onProgress)
{
    if (m_running || !m_source) {
        return;
    }
    m_onFinish = std::move(onFinish);
    m_onProgress = std::move(onProgress);
    m_running = true;
    m_offset = 0;
    m_byRule.clear();
    m_byRule.resize(ChapterRules::rules().size());
    m_totalSize = m_source->size();
    m_clock.start();
    probe();
}

void TxtIndexer::cancel()
{
    m_running = false;
    m_onFinish = nullptr;
    m_onProgress = nullptr;
}

void TxtIndexer::probe()
{
    if (!m_running) {
        return;
    }
    // 空文件：没有内容也就没有章节，直接给一个空索引（上层按「整本单章」处理）
    if (m_totalSize == 0) {
        m_encoding = TextCodec::Utf8;
        complete();
        return;
    }

    const qint64 want = m_totalSize > 0 ? qMin(m_probeBytes, m_totalSize) : m_probeBytes;
    const auto alive = m_alive;
    m_source->readRange(0, want, [this, alive](QByteArray data, StorageError error) {
        if (!*alive || !m_running) {
            return;
        }
        if (!error.isNull()) {
            finish(Result{NovelIndex(), error});
            return;
        }
        if (data.isEmpty()) {
            finish(Result{NovelIndex(), shortReadError()});
            return;
        }

        // 头块按固定大小切，很可能切在一个三字节汉字中间：先修掉不完整的 UTF-8 尾巴，
        // 否则「严格 UTF-8 校验」会失败，把 UTF-8 文件误判成 GB18030（然后整本乱码）
        m_encoding = TextCodec::decode(ChapterTextAlign::trimIncompleteUtf8Tail(data)).encoding;
        if (m_encoding == TextCodec::Unknown) {
            m_encoding = TextCodec::Utf8;
        }
        m_scanner = std::make_unique<ChapterLineScanner>(m_encoding);
        m_matcher = std::make_unique<ChapterMatcher>(m_encoding);

        m_offset = data.size();
        consume(data);
        readNext();
    });
}

void TxtIndexer::readNext()
{
    if (!m_running) {
        return;
    }
    if (m_totalSize >= 0 && m_offset >= m_totalSize) {
        complete();
        return;
    }

    const qint64 want =
        m_totalSize >= 0 ? qMin(m_chunkBytes, m_totalSize - m_offset) : m_chunkBytes;
    if (want <= 0) {
        complete();
        return;
    }

    const auto alive = m_alive;
    const qint64 start = m_offset;
    m_source->readRange(start, want, [this, alive, want](QByteArray data, StorageError error) {
        if (!*alive || !m_running) {
            return;
        }
        if (!error.isNull()) {
            finish(Result{NovelIndex(), error});
            return;
        }
        if (data.isEmpty()) {
            if (m_totalSize < 0) {
                complete(); // 长度未知：空读即 EOF
                return;
            }
            finish(Result{NovelIndex(), shortReadError()});
            return;
        }

        m_offset += data.size();
        consume(data);

        if (data.size() < want) {
            complete(); // 短读 = 到文件尾（Range 语义允许）
            return;
        }
        readNext();
    });
}

void TxtIndexer::consume(const QByteArray &chunk)
{
    m_scanner->append(chunk, [this](const char *data, qint64 lineStart, qint64 lineEnd) {
        handleLine(data, lineStart, lineEnd);
    });

    if (m_onProgress) {
        const double ratio = m_totalSize > 0
            ? static_cast<double>(qMin(m_offset, m_totalSize)) / static_cast<double>(m_totalSize)
            : -1.0;
        m_onProgress(ratio);
    }
}

void TxtIndexer::handleLine(const char *data, qint64 lineStart, qint64 lineEnd)
{
    const std::optional<ChapterMatcher::Hit> hit = m_matcher->match(data, lineEnd - lineStart);
    if (!hit) {
        return;
    }
    const int ruleIndex = m_ruleIndex.value(hit->ruleId, -1);
    if (ruleIndex < 0) {
        return;
    }
    QVector<NovelChapter> &bucket = m_byRule[ruleIndex];
    // 异常规则（纯数字行）可能命中十万行：超上限就不再收，避免把书切成一堆碎片
    if (bucket.size() >= ChapterRules::maxCandidates()) {
        return;
    }
    NovelChapter chapter;
    chapter.title = hit->title;
    chapter.startOffset = lineStart;
    chapter.ruleId = hit->ruleId;
    bucket.append(chapter);
}

void TxtIndexer::complete()
{
    if (m_scanner) {
        m_scanner->finish([this](const char *data, qint64 lineStart, qint64 lineEnd) {
            handleLine(data, lineStart, lineEnd);
        });
    }

    NovelIndex index;
    index.encoding = m_encoding;
    index.fileSize = m_totalSize >= 0 ? m_totalSize : m_offset;
    index.modTime = m_modTime;

    QString rejected;
    const ChapterRule *rule = ChapterRules::selectBest(m_byRule, index.fileSize, &rejected);
    index.rejectedRuleId = rejected;
    if (rule) {
        index.ruleId = rule->id;
        index.chapters = m_byRule.at(m_ruleIndex.value(rule->id, 0));
    }

    MH_INFO(NovelIndex,
            QStringLiteral("分章完成：%1 章 / %2 / 规则=%3 / 用时 %4ms / %5 字节")
                .arg(index.chapters.size())
                .arg(TextCodec::name(index.encoding))
                .arg(index.ruleId.isEmpty() ? QStringLiteral("无") : index.ruleId)
                .arg(m_clock.elapsed())
                .arg(index.fileSize));

    // 自检：「第一章」必须识别。首章既不在文件开头、又不像开头标记时，
    // 说明真正的第一章被漏掉了（正文里零星提到「第一章」的假命中）
    if (index.chapters.size() >= 2) {
        const NovelChapter &first = index.chapters.constFirst();
        const bool numbered = ChapterRules::isNumberedHeading(first.title);
        const bool opening = ChapterRules::isOpeningHeading(first.title);
        if (!numbered && !opening && first.startOffset > 4096) {
            MH_WARN(NovelIndex,
                    QStringLiteral("首章可疑：「%1」偏移 %2，可能漏掉了真正第一章")
                        .arg(first.title)
                        .arg(first.startOffset));
        }
    } else if (!index.chapters.isEmpty()) {
        MH_WARN(NovelIndex, QStringLiteral("只识别出 1 章，按整本单章处理"));
    } else {
        MH_INFO(NovelIndex,
                QStringLiteral("未识别出章节，按整本单章处理（候选最多规则=%1）")
                    .arg(rejected.isEmpty() ? QStringLiteral("无") : rejected));
    }

    finish(Result{index, StorageError()});
}

void TxtIndexer::finish(Result result)
{
    m_running = false;
    FinishCallback callback = std::move(m_onFinish);
    m_onFinish = nullptr;
    m_onProgress = nullptr;
    if (callback) {
        callback(result);
    }
}

} // namespace myhub
