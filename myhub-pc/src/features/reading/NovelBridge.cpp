#include "NovelBridge.h"

#include "core/files/DirectorySort.h"
#include "core/history/ProgressRepository.h"
#include "core/novel/EpubBook.h"
#include "core/novel/NovelIndexStore.h"
#include "core/novel/TxtIndexer.h"
#include "core/preferences/AppSettings.h"
#include "core/storage/StorageAdapter.h"
#include "core/storage/StoragePath.h"
#include "core/stream/AdapterRangeSource.h"
#include "core/utils/AppLogger.h"
#include "features/connections/ConnectionStore.h"

#include <QDateTime>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QPointer>

#include <utility>

namespace myhub {
namespace {

// 排版偏好键名与 iOS `AppSettings.Reader` 一致，配置互导时无需重新映射
constexpr auto kFontSizeKey = "reader.fontSize";
constexpr auto kLineSpacingKey = "reader.lineSpacing";
constexpr auto kThemeKey = "reader.theme";
constexpr auto kBrightnessKey = "reader.brightness";

constexpr int kMinFontSize = 12;
constexpr int kMaxFontSize = 32;
constexpr double kMinLineSpacing = 1.2;
constexpr double kMaxLineSpacing = 2.4;

/// 滚动上报节流：SQLite 写入 + 首页刷新都不该跟着滚动条跑
constexpr qint64 kReportIntervalMs = 1000;

QString displayName(const QString &path, const QString &fallback)
{
    if (!fallback.isEmpty()) {
        return fallback;
    }
    const QString name = QFileInfo(path).fileName();
    return name.isEmpty() ? path : name;
}

/**
 * 这个错误是「文件暂时够不着」还是「用户得去改配置」？
 *
 * 前者可以用缓存顶一阵（离线、超时、5xx、文件被移走），后者顶了只会把真正的
 * 问题藏起来：路径写错、协议不支持、鉴权失败时，进阅读器看到的是一片空目录，
 * 用户反而更不知道该去改哪里。
 */
bool isAvailabilityFailure(const StorageError &error)
{
    switch (error.kind()) {
    case StorageError::Cancelled:
    case StorageError::InvalidConfig:
    case StorageError::InvalidPath:
    case StorageError::UnsupportedProtocol:
    case StorageError::AuthenticationFailed:
        return false;
    default:
        return true;
    }
}

/// 缓存章里离 `chapter` 最近的那个（离线打开时续读章恰好没缓存）
int nearestCached(const QList<int> &cached, int chapter)
{
    int best = cached.constFirst();
    for (const int candidate : cached) {
        if (qAbs(candidate - chapter) < qAbs(best - chapter)) {
            best = candidate;
        }
    }
    return best;
}

} // namespace

NovelBridge *NovelBridge::instance()
{
    static NovelBridge *bridge = nullptr;
    if (!bridge) {
        bridge = new NovelBridge(nullptr);
    }
    return bridge;
}

NovelBridge *NovelBridge::create(QQmlEngine *, QJSEngine *)
{
    // 与 PlayerBridge 同理：单例工厂会被调用多次，必须幂等；
    // 返回新实例会让 QML 持有的门面与真正的实例错位
    return instance();
}

NovelBridge::NovelBridge(QObject *parent)
    : QObject(parent)
{
    loadPreferences();
}

NovelBridge::~NovelBridge() = default;

// ---------------------------------------------------------------- 打开

void NovelBridge::open(QString connectionId, QString path, const QString &title)
{
    if (connectionId.isEmpty() || path.isEmpty()) {
        fail(QStringLiteral("缺少连接源或文件路径"));
        return;
    }

    // 从阅读首页直接换一本：先把上一本攒着的位置落库，再拆现场
    commitPendingPosition();
    teardown();

    m_connectionId = connectionId;
    m_path = path;
    m_title = displayName(path, title);
    m_loading = true;
    m_errorText.clear();
    emit errorTextChanged();
    emit loadingChanged();
    setStatus(QStringLiteral("准备打开…"));

    StorageError error;
    StorageAdapter *adapter = ConnectionStore::instance().adapterFor(connectionId, &error);
    if (!adapter) {
        fail(error.isNull() ? QStringLiteral("连接源不可用") : error.message());
        return;
    }

    adapter->stat(path, [this, adapter](StatResult result) {
        if (!result.ok()) {
            // 文件不可用但手上有索引 + 缓存正文：进降级阅读，读过的章一本也不会少
            if (openOffline(adapter, result.error)) {
                return;
            }
            fail(result.error.message().isEmpty() ? QStringLiteral("读取文件信息失败")
                                                  : result.error.message());
            return;
        }
        if (result.value.isDir) {
            fail(QStringLiteral("这是目录，不是可以阅读的文件"));
            return;
        }
        if (result.value.size <= 0) {
            fail(QStringLiteral("文件是空的"));
            return;
        }

        const qint64 size = result.value.size;
        const qint64 modTime =
            result.value.modTime.isValid() ? result.value.modTime.toMSecsSinceEpoch() : 0;
        m_fileSize = size;
        m_modTime = modTime;
        // 文件指纹变了就把这本书的旧章节缓存丢掉；顺带按最后访问时间修剪超量行
        NovelChapterCache::dropStale(m_connectionId, m_path, fingerprint());
        NovelChapterCache::trim();

        auto source = std::make_unique<AdapterRangeSource>(adapter, m_path, size);
        m_sourceOwner = std::move(source);
        m_source = m_sourceOwner.get();

        // epub 走独立数据路径：目录在 OPF 里，没有字节索引可言
        if (m_path.endsWith(QLatin1String(".epub"), Qt::CaseInsensitive)) {
            openEpub();
            return;
        }

        // 续读起点：锚点是**全局字节偏移**，落在哪一章由索引自己算
        qint64 resumeByte = 0;
        ProgressRecord record;
        if (ProgressRepository::instance().find(m_connectionId, m_path, &record)
            && !record.finished) {
            resumeByte = record.progress.value(QStringLiteral("offset")).toLongLong();
        }
        m_lastReportedByte = resumeByte;

        if (NovelIndexStore::load(m_connectionId, m_path, size, modTime, &m_index)) {
            MH_INFO(NovelIndex,
                    QStringLiteral("索引命中缓存：%1（%2 章）").arg(m_path).arg(m_index.count()));
            rebuildChapters();
            m_opened = true;
            emit openedChanged();
            emit bookChanged();
            loadChapter(m_index.chapterAt(resumeByte), resumeByte);
            return;
        }

        m_pendingModTime = modTime;
        startIndexing();
    });
}

bool NovelBridge::openOffline(StorageAdapter *adapter, const StorageError &cause)
{
    if (!adapter || !isAvailabilityFailure(cause)) {
        return false;
    }
    // epub 的目录藏在 OPF 里：stat 都失败了，连「有几章」都答不上来，
    // 打开只会是一个没有目录的空壳。这条线等「epub 元数据快照」落地再补
    if (m_path.endsWith(QLatin1String(".epub"), Qt::CaseInsensitive)) {
        return false;
    }

    NovelIndex cached;
    if (!NovelIndexStore::find(m_connectionId, m_path, &cached) || !cached.isValid()) {
        return false; // 目录都没有，进阅读器只能对着空白屏
    }
    const QList<int> cachedChapters = NovelChapterCache::cachedChapters(m_connectionId, m_path);
    if (cachedChapters.isEmpty()) {
        return false;
    }

    m_offline = true;
    emit offlineChanged();
    m_index = cached;

    // 源长度取索引记下的那个：离线 stat 不到，但章节区间换算（末章到文件尾）离不开它
    auto source = std::make_unique<AdapterRangeSource>(adapter, m_path, cached.fileSize);
    m_sourceOwner = std::move(source);
    m_source = m_sourceOwner.get();

    qint64 resumeByte = 0;
    ProgressRecord record;
    if (ProgressRepository::instance().find(m_connectionId, m_path, &record) && !record.finished) {
        resumeByte = record.progress.value(QStringLiteral("offset")).toLongLong();
    }
    m_lastReportedByte = resumeByte;

    rebuildChapters();
    m_opened = true;
    emit openedChanged();
    emit bookChanged();

    int chapter = m_index.chapterAt(resumeByte);
    qint64 anchor = resumeByte;
    if (!cachedChapters.contains(chapter)) {
        // 续读章没缓存：退到最近的缓存章。偏一章的代价远小于「打开是一片空白」
        const int fallback = nearestCached(cachedChapters, chapter);
        MH_INFO(NovelIndex,
                QStringLiteral("离线打开：第 %1 章未缓存，改从第 %2 章读（%3）")
                    .arg(chapter)
                    .arg(fallback)
                    .arg(m_path));
        chapter = fallback;
        anchor = m_index.chapterStart(fallback);
    }
    MH_INFO(NovelIndex,
            QStringLiteral("离线打开：%1（%2 章，已缓存 %3 章）")
                .arg(m_path)
                .arg(m_index.count())
                .arg(cachedChapters.size()));
    loadChapter(chapter, anchor);
    return true;
}

void NovelBridge::showOfflineGap(int chapter)
{
    const int index = qBound(0, chapter, qMax(0, m_index.count() - 1));
    m_chapter = TxtChapterText();
    m_paragraphs.clear();
    m_anchorParagraph = -1;
    m_chapterIndex = index;
    m_chapterTitle = m_index.chapterTitle(index);
    // 刻意不写进度：这一章根本没读到，把续读点挪过来等于篡改阅读记录
    setStatus(QStringLiteral("离线 · 本章未缓存"));
    setPercent(m_index.percentAt(m_index.chapterStart(index)));
    emit chapterChanged();
}

void NovelBridge::startIndexing()
{
    m_indexer = std::make_unique<TxtIndexer>(m_source);
    m_indexer->setModTime(m_pendingModTime);
    setStatus(QStringLiteral("正在分章…"));

    m_indexer->start(
        [this](const TxtIndexer::Result &result) {
            // finish() 已把回调移出成员，这里析构索引器是安全的
            m_indexer.reset();

            if (!result.ok()) {
                fail(result.error.message().isEmpty() ? QStringLiteral("分章失败")
                                                      : result.error.message());
                return;
            }

            if (result.index.count() == 0) {
                // 识别不出一章：按「整本单章」兜底，阅读器只处理「有目录」一种情况。
                // 这种兜底不写缓存 —— 下次规则升级后应该能识别出来
                m_index = NovelIndex::singleChapter(result.index.fileSize, result.index.encoding);
                setStatus(QStringLiteral("未识别到章节，按全文阅读"));
            } else {
                m_index = result.index;
                NovelIndexStore::save(m_connectionId, m_path, m_index);
                setStatus(QString());
            }

            rebuildChapters();
            m_opened = true;
            emit openedChanged();
            emit bookChanged();
            loadChapter(m_index.chapterAt(m_lastReportedByte), m_lastReportedByte);
        },
        [this](double ratio) { setStatus(QStringLiteral("正在分章… %1%").arg(int(ratio * 100))); });
}

// ---------------------------------------------------------------- epub

void NovelBridge::openEpub()
{
    if (!m_source) {
        fail(QStringLiteral("未绑定数据源"));
        return;
    }
    m_epub = std::make_unique<EpubBook>(m_source);
    setStatus(QStringLiteral("正在解析 epub…"));

    // 续读锚点是「章号 + 段落下标」：见头文件里为什么 epub 不能沿用字节偏移
    int resumeChapter = 0;
    int resumeParagraph = -1;
    ProgressRecord record;
    if (ProgressRepository::instance().find(m_connectionId, m_path, &record) && !record.finished) {
        resumeChapter = record.progress.value(QStringLiteral("chapter")).toInt();
        resumeParagraph = record.progress.value(QStringLiteral("paragraph"), -1).toInt();
    }

    m_epub->load([this, resumeChapter, resumeParagraph](EpubMetadata metadata, StorageError error) {
        // teardown() 会析构 EpubBook，回调随 m_alive 一起失效；这里只是兜底
        if (!m_epub) {
            return;
        }
        if (!error.isNull()) {
            fail(error.message().isEmpty() ? QStringLiteral("epub 解析失败") : error.message());
            return;
        }
        if (metadata.chapters.isEmpty()) {
            fail(QStringLiteral("epub 里没有可读的章节"));
            return;
        }

        // OPF 里的书名比文件名可信；作者暂不展示，先不进 UI
        if (!metadata.title.isEmpty()) {
            m_title = metadata.title;
        }
        m_epubChapterCount = static_cast<int>(metadata.chapters.size());
        m_epubTitles.clear();
        m_epubTitles.reserve(m_epubChapterCount);
        for (const EpubChapterRef &chapter : std::as_const(metadata.chapters)) {
            m_epubTitles.append(chapter.title);
        }

        rebuildChapters();
        m_opened = true;
        emit openedChanged();
        emit bookChanged();
        setStatus(QString());

        const int chapter = qBound(0, resumeChapter, m_epubChapterCount - 1);
        loadEpubChapter(chapter, resumeParagraph);
    });
}

void NovelBridge::loadEpubChapter(int chapter, int anchorParagraph)
{
    if (!m_epub || m_epubChapterCount <= 0) {
        return;
    }
    if (chapter < 0 || chapter >= m_epubChapterCount) {
        chapter = 0;
    }

    commitPendingPosition();

    // 命中预取：翻页同步生效，不必再等一次 Range 往返
    if (const auto it = m_cache.constFind(chapter); it != m_cache.constEnd() && it->epub) {
        ++m_loadSerial;
        invalidatePrefetch();
        stopLoading();
        applyEpubChapter(chapter, it->paragraphs, anchorParagraph);
        return;
    }

    // 其次看落盘缓存：冷启动 / 换设备后翻回读过的章，同样一次 Range 都不用发
    QStringList cachedParagraphs;
    if (NovelChapterCache::loadEpub(m_connectionId, m_path, fingerprint(), chapter,
                                    &cachedParagraphs)) {
        ++m_loadSerial;
        invalidatePrefetch();
        stopLoading();
        applyEpubChapter(chapter, cachedParagraphs, anchorParagraph);
        return;
    }

    invalidatePrefetch();
    const quint64 loadSerial = ++m_loadSerial;
    m_loading = true;
    emit loadingChanged();

    // EpubBook 内部用递增序列号丢弃过期结果，连点「下一章」不会被旧章节覆盖
    m_epub->readChapter(
        chapter,
        [this, chapter, anchorParagraph, loadSerial](QStringList paragraphs, StorageError error) {
            if (loadSerial != m_loadSerial) {
                return; // 已被更新的切章顶掉，loading 由新加载自己管
            }
            m_loading = false;
            emit loadingChanged();
            if (!error.isNull()) {
                fail(error.message().isEmpty() ? QStringLiteral("章节读取失败") : error.message());
                return;
            }
            cacheEpubChapter(chapter, paragraphs);
            applyEpubChapter(chapter, paragraphs, anchorParagraph);
        });
}

void NovelBridge::applyEpubChapter(int chapter, const QStringList &paragraphs, int anchorParagraph)
{
    // epub 没有字节行表，清掉 txt 的残留（reportParagraph 靠它判断走哪条路径）
    m_chapter = TxtChapterText();
    m_chapterIndex = chapter;
    m_chapterTitle = m_epubTitles.value(chapter);
    m_paragraphs = paragraphs;
    m_anchorParagraph = paragraphs.isEmpty()
        ? -1
        : qBound(-1, anchorParagraph, static_cast<int>(paragraphs.size()) - 1);
    // 封面页 / 纯图片页会解出空白：不是错误，只是这一章没有文字
    setStatus(paragraphs.isEmpty() ? QStringLiteral("本章没有可显示的文字") : QString());

    saveEpubProgress(chapter, m_anchorParagraph);
    setPercent(epubPercent(chapter, m_anchorParagraph));
    emit chapterChanged();

    prefetchAdjacent(chapter);
}

double NovelBridge::epubPercent(int chapter, int paragraph) const
{
    if (m_epubChapterCount <= 0 || chapter < 0) {
        return 0.0;
    }
    double within = 0.0;
    if (chapter == m_chapterIndex && paragraph >= 0 && !m_paragraphs.isEmpty()) {
        within = static_cast<double>(paragraph + 1) / static_cast<double>(m_paragraphs.size());
    }
    const double total = static_cast<double>(chapter) + within;
    return qBound(0.0, total / static_cast<double>(m_epubChapterCount), 1.0);
}

void NovelBridge::saveEpubProgress(int chapter, int paragraph, bool finished)
{
    if (m_connectionId.isEmpty() || m_path.isEmpty() || chapter < 0) {
        return;
    }
    ProgressRecord record;
    record.connectionId = m_connectionId;
    record.path = m_path;
    record.mediaType = QStringLiteral("novel");
    record.title = m_title;
    record.progress.insert(QStringLiteral("chapter"), chapter);
    record.progress.insert(QStringLiteral("paragraph"), paragraph);
    record.progress.insert(QStringLiteral("chapterTitle"), m_epubTitles.value(chapter));
    // 含预取邻章：预取会替「当前章」写位置，不能把刚读到底的 finished 冲掉
    record.finished = finished || m_finishedBook;
    record.percent = record.finished ? 1.0 : epubPercent(chapter, paragraph);
    applyFingerprint(&record);
    ProgressRepository::instance().upsert(record);
}

void NovelBridge::applyFingerprint(ProgressRecord *record) const
{
    if (record == nullptr) {
        return;
    }
    // 首页拿它校验封面缓存是否过期：不必再为每行发一次 stat（远程源上是次往返）。
    // 离线打开时没 stat 过，如实记「未知」，免得用 0 覆盖掉上一次记下的真指纹
    record->fileSize = m_fileSize > 0 ? m_fileSize : -1;
    record->modTimeMs = m_modTime > 0 ? m_modTime : -1;
}

void NovelBridge::rebuildChapters()
{
    const bool epub = epubMode();
    const int count = epub ? m_epubChapterCount : m_index.count();
    QVariantList list;
    list.reserve(count);
    for (int i = 0; i < count; ++i) {
        QVariantMap item;
        item.insert(QStringLiteral("title"),
                    epub ? m_epubTitles.value(i) : m_index.chapterTitle(i));
        item.insert(QStringLiteral("index"), i);
        list.append(item);
    }
    m_chapters = list;
}

// ---------------------------------------------------------------- 按章加载

void NovelBridge::goToChapter(int index)
{
    if (!m_opened || index < 0 || index >= chapterCount() || index == m_chapterIndex) {
        return;
    }
    if (epubMode()) {
        loadEpubChapter(index, -1);
        return;
    }
    loadChapter(index, m_index.chapterStart(index));
}

void NovelBridge::nextChapter()
{
    goToChapter(m_chapterIndex + 1);
}

void NovelBridge::prevChapter()
{
    goToChapter(m_chapterIndex - 1);
}

void NovelBridge::loadChapter(int chapter, qint64 anchorByte)
{
    if (epubMode() || !m_source || !m_index.isValid()) {
        return;
    }
    if (chapter < 0 || chapter >= m_index.count()) {
        chapter = 0;
    }

    // 换章前先把旧章的滚动位置落库，否则最后一段阅读记录会丢
    commitPendingPosition();

    if (const auto it = m_cache.constFind(chapter); it != m_cache.constEnd() && !it->epub) {
        ++m_loadSerial;
        invalidatePrefetch();
        stopLoading();
        applyChapter(it->text, m_index.chapterStart(chapter));
        return;
    }

    // 落盘缓存：锚点必须带上 —— 续读点很可能就落在刚被缓存下来的那一章，
    // 用章首顶替会把「读到第几段」洗掉
    TxtChapterText cachedText;
    if (NovelChapterCache::loadTxt(m_connectionId, m_path, fingerprint(), chapter, &cachedText)) {
        ++m_loadSerial;
        invalidatePrefetch();
        stopLoading();
        applyChapter(cachedText, anchorByte > 0 ? anchorByte : m_index.chapterStart(chapter));
        return;
    }

    invalidatePrefetch();
    const quint64 loadSerial = ++m_loadSerial;
    m_loading = true;
    emit loadingChanged();

    TxtChapterLoader::load(
        m_source, m_index, chapter,
        [this, chapter, anchorByte, loadSerial](TxtChapterText text, StorageError error) {
            if (loadSerial != m_loadSerial) {
                return; // 已被更新的切章顶掉
            }
            m_loading = false;
            emit loadingChanged();
            if (!error.isNull()) {
                if (m_offline) {
                    // 离线时「读不到」是常态而非故障：进错误页会让整块阅读器下屏，
                    // 连翻回已缓存的章都做不到
                    showOfflineGap(chapter);
                    return;
                }
                fail(error.message().isEmpty() ? QStringLiteral("章节读取失败") : error.message());
                return;
            }
            cacheTxtChapter(chapter, text);
            applyChapter(text, anchorByte);
        });
}

void NovelBridge::applyChapter(const TxtChapterText &text, qint64 anchorByte)
{
    m_chapter = text;
    m_chapterIndex = m_index.chapterAt(text.start);
    m_chapterTitle = text.title;
    m_paragraphs = text.paragraphs();

    // 锚点换算成段落下标：QML 只认段落序号，换算的权威在行表里
    m_anchorParagraph = anchorByte > 0 ? text.paragraphAtByte(anchorByte) : -1;

    // 落库位置用锚点而不是章首：从目录跳回来时章首已经存过一次，
    // 再拿章首覆盖会把「读到第几段」洗掉一截
    const qint64 anchor = qMax(anchorByte, text.start);

    if (m_offline) {
        // 离线时把「为什么隔壁章是空的」写在最显眼的地方
        setStatus(QStringLiteral("离线 · 仅显示已缓存的章节"));
    } else if (text.truncated) {
        setStatus(QStringLiteral("本章过长，仅显示前 4MB"));
    } else if (m_index.count() == 1 && m_index.ruleId.isEmpty()) {
        setStatus(QStringLiteral("未识别到章节，按全文阅读"));
    } else {
        setStatus(QString());
    }

    saveProgress(anchor);
    setPercent(m_index.percentAt(anchor));
    emit chapterChanged();

    prefetchAdjacent(m_chapterIndex);
}

// ---------------------------------------------------------------- 章节落盘缓存

void NovelBridge::cacheTxtChapter(int chapter, const TxtChapterText &text)
{
    NovelChapterCache::saveTxt(m_connectionId, m_path, fingerprint(), chapter, text);
}

void NovelBridge::cacheEpubChapter(int chapter, const QStringList &paragraphs)
{
    NovelChapterCache::saveEpub(m_connectionId, m_path, fingerprint(), chapter, paragraphs);
}

// ---------------------------------------------------------------- 邻章预取

void NovelBridge::invalidatePrefetch()
{
    ++m_prefetchSerial;
    m_prefetchQueue.clear();
}

void NovelBridge::stopLoading()
{
    if (!m_loading) {
        return;
    }
    m_loading = false;
    emit loadingChanged();
}

void NovelBridge::prefetchAdjacent(int chapter)
{
    m_prefetchQueue.clear();
    // 下一章优先：绝大多数人是往后读，反向往回翻是少数
    if (chapter + 1 < chapterCount()) {
        m_prefetchQueue.append(chapter + 1);
    }
    if (chapter - 1 >= 0) {
        m_prefetchQueue.append(chapter - 1);
    }
    pumpPrefetch();
}

void NovelBridge::pumpPrefetch()
{
    while (!m_prefetchQueue.isEmpty()) {
        const int chapter = m_prefetchQueue.takeFirst();
        if (chapter == m_chapterIndex || m_cache.contains(chapter)) {
            continue;
        }
        // 串行：EpubBook 只有一条读取线，并行预取会互相判废；
        // 同一时刻只允许一个在途预取，用户切章时整体作废
        const quint64 serial = ++m_prefetchSerial;

        if (epubMode()) {
            if (!m_epub) {
                return;
            }
            // 落盘缓存优先：翻回读过的章连一次 zip 条目读都不用发
            QStringList cachedParagraphs;
            if (NovelChapterCache::loadEpub(m_connectionId, m_path, fingerprint(), chapter,
                                            &cachedParagraphs)) {
                rememberChapter(chapter, true, cachedParagraphs, TxtChapterText());
                continue;
            }
            m_epub->readChapter(
                chapter, [this, chapter, serial](QStringList paragraphs, StorageError error) {
                    if (serial != m_prefetchSerial) {
                        return;
                    }
                    if (error.isNull()) {
                        cacheEpubChapter(chapter, paragraphs);
                        rememberChapter(chapter, true, paragraphs, TxtChapterText());
                    }
                    pumpPrefetch();
                });
            return;
        }

        if (!m_source || !m_index.isValid()) {
            return;
        }
        TxtChapterText cachedText;
        if (NovelChapterCache::loadTxt(m_connectionId, m_path, fingerprint(), chapter,
                                       &cachedText)) {
            rememberChapter(chapter, false, cachedText.paragraphs(), cachedText);
            continue;
        }
        TxtChapterLoader::load(m_source, m_index, chapter,
                               [this, chapter, serial](TxtChapterText text, StorageError error) {
                                   if (serial != m_prefetchSerial) {
                                       return;
                                   }
                                   if (error.isNull()) {
                                       cacheTxtChapter(chapter, text);
                                       rememberChapter(chapter, false, text.paragraphs(), text);
                                   }
                                   pumpPrefetch();
                               });
        return;
    }
}

void NovelBridge::rememberChapter(int chapter, bool epub, const QStringList &paragraphs,
                                  const TxtChapterText &text)
{
    if (chapter < 0 || chapter == m_chapterIndex) {
        return; // 可见章不占缓存位，切回来时走正常加载即可
    }
    CachedChapter entry;
    entry.epub = epub;
    entry.paragraphs = paragraphs;
    entry.text = text;
    m_cache.insert(chapter, entry);
    trimCache();
}

void NovelBridge::trimCache()
{
    // 只需要留住 ±1 各一章；留 4 个是为了「往前一章、再翻回来」不重复读
    constexpr int kMaxCachedChapters = 4;
    while (m_cache.size() > kMaxCachedChapters) {
        int victim = -1;
        int victimDistance = -1;
        for (auto it = m_cache.constBegin(); it != m_cache.constEnd(); ++it) {
            const int distance = qAbs(it.key() - m_chapterIndex);
            if (distance > victimDistance) {
                victimDistance = distance;
                victim = it.key();
            }
        }
        if (victim < 0) {
            break;
        }
        m_cache.remove(victim);
    }
}

// ---------------------------------------------------------------- 进度

void NovelBridge::reportParagraph(int index)
{
    if (!m_opened) {
        return;
    }
    // 已读到底：位置只会停在末尾，再写一次普通进度会把 finished 洗回 false
    if (m_bookEnd) {
        return;
    }

    if (epubMode()) {
        if (m_chapterIndex < 0 || index < 0) {
            return;
        }
        m_pendingChapter = m_chapterIndex;
        m_pendingParagraph = index;
    } else {
        if (m_chapter.isEmpty()) {
            return;
        }
        const qint64 byte = m_chapter.byteAtParagraph(index);
        if (byte < 0) {
            return;
        }
        m_pendingByte = byte;
    }

    // 滚动事件一秒几十次，跟着它写库会把首页刷新拖成幻灯片
    if (m_reportClock.isValid() && m_reportClock.elapsed() < kReportIntervalMs) {
        return;
    }
    commitPendingPosition();
}

void NovelBridge::commitPendingPosition()
{
    if (m_bookEnd) {
        // 已经翻到全书最后：攒下的还是「读到底之前」的位置，落下去会把
        // percent 拉回 99% 那一档（finished 由写入层守住，不必再写一次）
        m_pendingByte = -1;
        m_pendingChapter = -1;
        m_pendingParagraph = -1;
        return;
    }

    if (epubMode()) {
        if (m_pendingChapter < 0 || m_pendingParagraph < 0) {
            return;
        }
        const int chapter = m_pendingChapter;
        const int paragraph = m_pendingParagraph;
        m_pendingChapter = -1;
        m_pendingParagraph = -1;
        // 只发 percentChanged：发 chapterChanged 会让 QML 重建段落 model，把列表弹回顶部
        saveEpubProgress(chapter, paragraph);
        setPercent(epubPercent(chapter, paragraph));
        m_reportClock.start();
        return;
    }

    if (m_pendingByte < 0) {
        return;
    }
    const qint64 byte = m_pendingByte;
    m_pendingByte = -1;
    saveProgress(byte);
    setPercent(m_index.percentAt(byte));
    m_reportClock.start();
}

void NovelBridge::saveProgress(qint64 byteOffset, bool finished)
{
    if (m_connectionId.isEmpty() || m_path.isEmpty() || byteOffset < 0) {
        return;
    }
    ProgressRecord record;
    record.connectionId = m_connectionId;
    record.path = m_path;
    record.mediaType = QStringLiteral("novel");
    record.title = m_title;
    record.progress.insert(QStringLiteral("offset"), byteOffset);
    record.progress.insert(QStringLiteral("chapter"), m_index.chapterAt(byteOffset));
    record.progress.insert(QStringLiteral("chapterTitle"),
                           m_index.chapterTitle(m_index.chapterAt(byteOffset)));
    // 读过完就是既成事实：之后任何位置写入（节流上报、往回翻）都不许把它洗回未读完
    record.finished = finished || m_finishedBook;
    // finished 与 percent 必须自洽：否则首页会出现「已读完 · 37%」
    record.percent = record.finished ? 1.0 : m_index.percentAt(byteOffset);
    applyFingerprint(&record);
    ProgressRepository::instance().upsert(record);
    m_lastReportedByte = byteOffset;
}

void NovelBridge::close()
{
    if (!m_opened) {
        teardown();
        return;
    }
    // 节流里攒着的最后位置先落库，再拆现场
    commitPendingPosition();
    // epub 的进度在 applyEpubChapter 里已经写过一次，这里再走 txt 的 saveProgress
    // 会往记录里塞一个假的 offset=0，把百分比洗回 0。
    // 空章（离线缺章、加载失败）同理：`TxtChapterText()` 的 start 是 0，写下去等于把进度清零
    if (!epubMode() && m_lastReportedByte < 0 && !m_chapter.isEmpty()) {
        saveProgress(m_chapter.start);
    }
    teardown();
    m_opened = false;
    emit openedChanged();
    emit bookChanged();
    emit chapterChanged();
}

void NovelBridge::teardown()
{
    if (m_indexer) {
        m_indexer->cancel();
        m_indexer.reset();
    }
    if (m_epub) {
        // 先 cancel 再析构：在途的 Range 回调进来时 EpubBook 的存活标记已置 false
        m_epub->cancel();
        m_epub.reset();
    }
    m_sourceOwner.reset();
    m_source = nullptr;
    m_index = NovelIndex();
    m_chapter = TxtChapterText();
    m_chapters.clear();
    // 预取结果属于这本书：换书必须整体丢弃，否则会拿上一本的正文顶上来
    invalidatePrefetch();
    ++m_loadSerial;
    m_cache.clear();
    m_epubChapterCount = 0;
    m_epubTitles.clear();
    m_chapterIndex = -1;
    m_anchorParagraph = -1;
    m_percent = 0.0;
    m_pendingByte = -1;
    m_pendingChapter = -1;
    m_pendingParagraph = -1;
    m_fileSize = 0;
    m_modTime = 0;
    m_paragraphs.clear();
    m_chapterTitle.clear();
    // 必须发信号，不能只清成员：QML 的 visible 绑定看着 errorText，
    // 不发 notify 它就一直停在「有错误」的那一帧，关掉阅读器后整块覆盖层不下屏
    if (!m_statusText.isEmpty()) {
        m_statusText.clear();
        emit statusChanged();
    }
    if (!m_errorText.isEmpty()) {
        m_errorText.clear();
        emit errorTextChanged();
    }
    m_lastReportedByte = -1;
    m_pendingModTime = 0;
    m_reportClock.invalidate();
    m_loading = false;
    if (m_offline) {
        m_offline = false;
        emit offlineChanged();
    }
    // 读完推荐属于这本书：换书必须撤掉提示条，并作废在途的目录列举
    m_bookEnd = false;
    m_finishedBook = false;
    m_nextDismissed = false;
    ++m_nextQueryId;
    clearNextSuggestion();
    m_connectionId.clear();
    m_path.clear();
}

void NovelBridge::fail(const QString &message)
{
    m_loading = false;
    emit loadingChanged();
    m_errorText = message;
    emit errorTextChanged();
    MH_WARN(NovelIndex, QStringLiteral("阅读器打开失败：%1（%2）").arg(m_path, message));
}

void NovelBridge::setStatus(const QString &text)
{
    if (m_statusText == text) {
        return;
    }
    m_statusText = text;
    emit statusChanged();
}

// ---------------------------------------------------------------- 读完推荐（§4.6）

void NovelBridge::setAtBookEnd(bool atEnd)
{
    if (m_bookEnd == atEnd) {
        return;
    }
    m_bookEnd = atEnd;

    if (!atEnd) {
        // 往回翻了：撤掉提示条并复位「已收起」，下次读到底还能再推一次
        m_nextDismissed = false;
        ++m_nextQueryId; // 在途的目录列举回来就作废
        clearNextSuggestion();
        return;
    }

    markFinished();
    resolveNextSuggestion();
}

void NovelBridge::setPercent(double percent)
{
    // 读到底之后，晚到的章节加载 / 节流上报还会算出「书内位置」：
    // 直接回写就变成「刚读完却显示 0%」，所以末尾状态下恒定 100%
    m_percent = m_bookEnd ? 1.0 : percent;
    emit percentChanged();
}

void NovelBridge::markFinished()
{
    // 离线只能读到「恰好缓存下来的章」，那不一定是全书结尾，不能算读完
    if (!m_opened || m_offline) {
        return;
    }
    m_finishedBook = true;

    if (epubMode()) {
        if (m_epubChapterCount <= 0) {
            return;
        }
        const int chapter = m_epubChapterCount - 1;
        const int paragraph = m_chapterIndex == chapter ? qMax(0, m_paragraphs.size() - 1) : 0;
        saveEpubProgress(chapter, paragraph, true);
        setPercent(1.0);
        return;
    }

    if (m_index.count() <= 0) {
        return;
    }
    qint64 byte = m_lastReportedByte;
    if (byte < 0) {
        byte = m_index.chapterStart(m_index.count() - 1);
    }
    saveProgress(byte, true);
    setPercent(1.0);
}

void NovelBridge::resolveNextSuggestion()
{
    if (m_nextDismissed || m_path.isEmpty() || m_connectionId.isEmpty()) {
        return;
    }

    const QString dir = StoragePath::parent(m_path);
    if (dir.isEmpty()) {
        return;
    }

    // 顺序必须与浏览页一致：先取该目录的排序偏好，没有则回退全局
    const auto &settings = AppSettings::instance();
    const QVariantMap pref = settings.directorySortPreference(m_connectionId, dir);
    const QString sortKey = pref.value(QStringLiteral("key"), settings.sortKey()).toString();
    const bool ascending = pref.value(QStringLiteral("asc"), settings.sortAscending()).toBool();

    StorageError error;
    StorageAdapter *adapter = ConnectionStore::instance().adapterFor(m_connectionId, &error);
    if (!adapter) {
        return;
    }

    // 目录列举是异步的：回来时若已换书 / 已撤销 / 又读到底一轮，直接丢弃
    const QPointer<NovelBridge> guard(this);
    const int queryId = ++m_nextQueryId;
    const QString currentPath = StoragePath::normalize(m_path);
    adapter->list(dir, [this, guard, queryId, currentPath, sortKey, ascending](ListResult result) {
        if (!guard || queryId != m_nextQueryId || !result.ok()) {
            return;
        }
        if (StoragePath::normalize(m_path) != currentPath) {
            return; // 期间已经换书
        }
        setNextSuggestion(DirectorySort::nextBook(result.value, currentPath, sortKey, ascending));
    });
}

void NovelBridge::setNextSuggestion(const FileEntry &entry)
{
    if (!entry.isValid()) {
        MH_INFO(NovelIndex, QStringLiteral("下一本候选：无"));
        clearNextSuggestion();
        return;
    }

    MH_INFO(NovelIndex, QStringLiteral("下一本候选：%1").arg(entry.name));

    QVariantMap suggestion;
    suggestion.insert(QStringLiteral("connectionId"), m_connectionId);
    suggestion.insert(QStringLiteral("path"), entry.path);
    suggestion.insert(QStringLiteral("title"), StoragePath::baseName(entry.path));
    suggestion.insert(QStringLiteral("name"), entry.name);
    suggestion.insert(QStringLiteral("size"), entry.size);
    m_nextSuggestion = suggestion;
    emit nextSuggestionChanged();
}

void NovelBridge::clearNextSuggestion()
{
    if (m_nextSuggestion.isEmpty()) {
        return;
    }
    m_nextSuggestion.clear();
    emit nextSuggestionChanged();
}

void NovelBridge::openNextSuggestion()
{
    if (m_nextSuggestion.isEmpty()) {
        return;
    }
    const QVariantMap suggestion = m_nextSuggestion;
    clearNextSuggestion();
    // 换书保留它自己的续读点：用户点的是「读下一本」，不是「从头重读」
    open(m_connectionId, suggestion.value(QStringLiteral("path")).toString(),
         suggestion.value(QStringLiteral("title")).toString());
}

void NovelBridge::dismissNextSuggestion()
{
    m_nextDismissed = true;
    ++m_nextQueryId; // 在途的目录列举回来也别再弹
    clearNextSuggestion();
}

// ---------------------------------------------------------------- 排版偏好

void NovelBridge::loadPreferences()
{
    AppSettings &settings = AppSettings::instance();
    m_fontSize = qBound(kMinFontSize, settings.value(kFontSizeKey, 17).toInt(), kMaxFontSize);
    m_lineSpacing =
        qBound(kMinLineSpacing, settings.value(kLineSpacingKey, 1.6).toDouble(), kMaxLineSpacing);
    m_theme = qBound(0, settings.value(kThemeKey, 0).toInt(), 3);
    m_brightness = settings.value(kBrightnessKey, -1.0).toDouble();
}

void NovelBridge::storePreference(const QString &key, const QVariant &value)
{
    AppSettings::instance().setValue(key, value);
}

void NovelBridge::setFontSize(int px)
{
    const int clamped = qBound(kMinFontSize, px, kMaxFontSize);
    if (clamped == m_fontSize) {
        return;
    }
    m_fontSize = clamped;
    storePreference(kFontSizeKey, m_fontSize);
    emit fontSizeChanged();
}

void NovelBridge::setLineSpacing(double spacing)
{
    const double clamped = qBound(kMinLineSpacing, spacing, kMaxLineSpacing);
    if (qFuzzyCompare(clamped, m_lineSpacing)) {
        return;
    }
    m_lineSpacing = clamped;
    storePreference(kLineSpacingKey, m_lineSpacing);
    emit lineSpacingChanged();
}

void NovelBridge::setTheme(int theme)
{
    const int clamped = qBound(0, theme, 3);
    if (clamped == m_theme) {
        return;
    }
    m_theme = clamped;
    storePreference(kThemeKey, m_theme);
    emit themeChanged();
}

void NovelBridge::setBrightness(double value)
{
    if (qFuzzyCompare(value, m_brightness)) {
        return;
    }
    m_brightness = value;
    storePreference(kBrightnessKey, m_brightness);
    emit brightnessChanged();
}

} // namespace myhub
