#include "NovelBridge.h"

#include "core/comic/ComicDetector.h"
#include "core/files/DirectorySort.h"
#include "core/history/ProgressRepository.h"
#include "core/novel/EpubBook.h"
#include "core/novel/EpubMetaStore.h"
#include "core/novel/NovelImageStore.h"
#include "core/novel/NovelIndexStore.h"
#include "core/novel/TxtIndexer.h"
#include "core/preferences/AppSettings.h"
#include "core/storage/StorageAdapter.h"
#include "core/storage/StoragePath.h"
#include "core/stream/AdapterRangeSource.h"
#include "core/utils/AppLogger.h"
#include "features/connections/ConnectionStore.h"
#include "features/reading/BundledFonts.h"
#include "features/reading/ComicBridge.h"

#include <QDateTime>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QImageReader>
#include <QPointer>
#include <QRegularExpression>
#include <QSet>
#include <QTimer>
#include <QUrl>

#include <utility>

namespace myhub {
namespace {

// 排版偏好键名与 iOS `AppSettings.Reader` 一致，配置互导时无需重新映射
constexpr auto kFontSizeKey = "reader.fontSize";
constexpr auto kLineSpacingKey = "reader.lineSpacing";
constexpr auto kFontStyleKey = "reader.fontStyle";
constexpr auto kThemeKey = "reader.theme";
constexpr auto kBrightnessKey = "reader.brightness";
constexpr auto kPageModeKey = "reader.pageMode";

constexpr int kMinFontSize = 12;
constexpr int kMaxFontSize = 32;
constexpr double kMinLineSpacing = 1.2;
constexpr double kMaxLineSpacing = 2.4;

/**
 * 正文字体回退链：从「最想用的」排到「几乎一定有的」。
 *
 * 不内置字体文件（思源宋体一套几十 MB，多数平台本来就有宋体/明体），
 * 命中链尾的 `serif` / `sans-serif` 由 Qt 交给系统兜底，不会出现方块字。
 * 这一串同时喂给 QML（`font.family`）与分页器（`QFont::setFamilies`）——
 * 两处必须完全一致，否则量出来的行宽与画出来的不是同一份。
 */
const QStringList &sansFamilies()
{
    static const QStringList families{
        QStringLiteral("Microsoft YaHei UI"), QStringLiteral("Microsoft YaHei"),
        QStringLiteral("PingFang SC"), QStringLiteral("Noto Sans CJK SC"),
        QStringLiteral("sans-serif")};
    return families;
}

const QStringList &serifFamilies()
{
    static const QStringList families{QStringLiteral("Source Han Serif SC"),
                                      QStringLiteral("Noto Serif CJK SC"),
                                      QStringLiteral("Songti SC"),
                                      QStringLiteral("STSong"),
                                      QStringLiteral("SimSun"),
                                      QStringLiteral("serif")};
    return families;
}

QStringList familiesForStyle(int style)
{
    QStringList families = style == 1 ? serifFamilies() : sansFamilies();
    // 内置字体排最前：跨平台字形一致靠它，系统字体只做兜底
    const QStringList bundled =
        style == 1 ? BundledFonts::serifFamilies() : BundledFonts::sansFamilies();
    // 倒着 prepend 才能保持注册顺序（qrc 里排在前面的字体仍然排最前）
    for (const QString &family : QStringList(bundled.crbegin(), bundled.crend())) {
        families.removeAll(family);
        families.prepend(family);
    }
    return families;
}

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

/// 只看扩展名：epub 与 txt 是两条完全不同的数据路径，判断点必须一致
bool isEpubPath(const QString &path)
{
    return path.endsWith(QLatin1String(".epub"), Qt::CaseInsensitive);
}

/**
 * 首段是不是就是章名（只判第 0 段）。
 *
 * epub 的 `<h1>` 会被解成第 0 段，和页眉里的目录章名重复：认出来就交给「标题带」画，
 * 正文里摘掉。判定宁严勿宽 —— 认错等于凭空藏掉一段正文，认不出最多是维持原样。
 */
bool looksLikeChapterHeading(const QString &paragraph, const QString &title)
{
    if (paragraph.isEmpty() || title.isEmpty())
        return false;

    // 空白与标点不参与比较：「第一章 起风了」与「第一章·起风了」是同一个章名
    static const QRegularExpression noise(
        QStringLiteral("[\\s\\u3000·•、,，.。:：;；!！?？\"'“”‘’()（）\\[\\]【】—–_]+"));
    auto normalize = [](const QString &raw) {
        QString text = raw;
        text.remove(noise);
        return text;
    };

    const QString body = normalize(paragraph);
    const QString name = normalize(title);
    if (body.isEmpty() || name.isEmpty() || body.size() > 40)
        return false; // 长段落不可能是章名
    if (body == name)
        return true;
    // 一边是另一边的截短（正文写「第一章」，目录写「第一章 起风了」）：短的那边别太短
    if (name.startsWith(body) && body.size() * 2 >= name.size())
        return true;
    if (body.startsWith(name) && name.size() * 2 >= body.size())
        return true;
    return false;
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
    // 先把排版参数交给分页器：视口要等 QML 布局完才推上来，但字体/字号/行距已知
    m_pager.setTypography(m_fontFamilies, m_fontSize, m_lineSpacing);

    // 设置页与阅读器共用同一组 `reader.*` 键：任一端改动，另一端立即跟上（§14.16）。
    // 走 setter 而不是直接赋值：钳位、相等即返回、发信号都复用同一套逻辑；
    // 自己写键时值已经先行赋值，setter 会静默返回，不会打转。
    connect(&AppSettings::instance(), &AppSettings::settingChanged, this,
            [this](const QString &key) {
                if (!key.startsWith(QLatin1String("reader."))) {
                    return;
                }
                AppSettings &settings = AppSettings::instance();
                setFontSize(settings.value(kFontSizeKey, 17).toInt());
                setLineSpacing(settings.value(kLineSpacingKey, 1.6).toDouble());
                setFontStyle(settings.value(kFontStyleKey, 0).toInt());
                setTheme(settings.value(kThemeKey, 0).toInt());
                setBrightness(settings.value(kBrightnessKey, -1.0).toDouble());
            });
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
        if (isEpubPath(m_path)) {
            openEpub();
            return;
        }

        // 续读起点：锚点是**全局字节偏移**，落在哪一章由索引自己算
        qint64 resumeByte = 0;
        int resumeOffset = 0;
        ProgressRecord record;
        if (ProgressRepository::instance().find(m_connectionId, m_path, &record)
            && !record.finished) {
            resumeByte = record.progress.value(QStringLiteral("offset")).toLongLong();
            resumeOffset = record.progress.value(QStringLiteral("charOffset"), 0).toInt();
        }
        m_lastReportedByte = resumeByte;

        if (NovelIndexStore::load(m_connectionId, m_path, size, modTime, &m_index)) {
            MH_INFO(NovelIndex,
                    QStringLiteral("索引命中缓存：%1（%2 章）").arg(m_path).arg(m_index.count()));
            rebuildChapters();
            m_opened = true;
            emit openedChanged();
            emit bookChanged();
            loadChapter(m_index.chapterAt(resumeByte), resumeByte, resumeOffset);
            return;
        }

        m_pendingModTime = modTime;
        startIndexing();
    });
}

bool NovelBridge::openOffline(StorageAdapter *adapter, const StorageError &cause)
{
    if (!adapter || !cause.isAvailabilityFailure()) {
        return false;
    }
    // epub 的目录不在正文里：得先 stat 到长度、再按 Range 读 zip 条目表才能拿到章数。
    // 快照就是为这一刻存的 —— 目录 + 章名照常还原，正文只放已缓存的那几章
    if (isEpubPath(m_path)) {
        return openEpubOffline();
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
    int resumeOffset = 0;
    ProgressRecord record;
    if (ProgressRepository::instance().find(m_connectionId, m_path, &record) && !record.finished) {
        resumeByte = record.progress.value(QStringLiteral("offset")).toLongLong();
        resumeOffset = record.progress.value(QStringLiteral("charOffset"), 0).toInt();
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
        resumeOffset = 0; // 换章了，原来的段内偏移不再指向任何东西
    }
    MH_INFO(NovelIndex,
            QStringLiteral("离线打开：%1（%2 章，已缓存 %3 章）")
                .arg(m_path)
                .arg(m_index.count())
                .arg(cachedChapters.size()));
    loadChapter(chapter, anchor, resumeOffset);
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

bool NovelBridge::openEpubOffline()
{
    EpubMeta meta;
    if (!EpubMetaStore::find(m_connectionId, m_path, &meta) || !meta.isValid()) {
        return false; // 一次都没成功打开过：连章数都不知道，别开一个没有目录的空壳
    }
    const QList<int> cachedChapters = NovelChapterCache::cachedChapters(m_connectionId, m_path);
    if (cachedChapters.isEmpty()) {
        return false;
    }

    m_offline = true;
    emit offlineChanged();

    // 指纹从快照恢复：章节缓存按它取、封面缓存按它校验 —— 恢复后与在线时同一口径。
    // 离线 stat 不到文件，但这两项是「上次打开那一刻」的真实值
    m_fileSize = meta.fileSize;
    m_modTime = meta.modTime;
    if (!meta.title.isEmpty()) {
        m_title = meta.title;
    }
    m_epubChapterCount = static_cast<int>(meta.chapters.size());
    m_epubTitles.clear();
    m_epubTitles.reserve(m_epubChapterCount);
    for (const EpubChapterRef &chapter : std::as_const(meta.chapters)) {
        m_epubTitles.append(chapter.title);
    }

    int chapter = 0;
    int paragraph = -1;
    int resumeOffset = 0;
    ProgressRecord record;
    if (ProgressRepository::instance().find(m_connectionId, m_path, &record) && !record.finished) {
        chapter = qBound(0, record.progress.value(QStringLiteral("chapter")).toInt(),
                         m_epubChapterCount - 1);
        paragraph = record.progress.value(QStringLiteral("paragraph"), -1).toInt();
        resumeOffset = record.progress.value(QStringLiteral("charOffset"), 0).toInt();
    }
    if (!cachedChapters.contains(chapter)) {
        chapter = nearestCached(cachedChapters, chapter);
        paragraph = -1;
        resumeOffset = 0; // 换了章，原来的段内偏移不再指向任何东西
    }

    rebuildChapters();
    m_opened = true;
    emit openedChanged();
    emit bookChanged();
    MH_INFO(NovelIndex,
            QStringLiteral("离线打开 epub：%1（%2 章，已缓存 %3 章）")
                .arg(m_path)
                .arg(m_epubChapterCount)
                .arg(cachedChapters.size()));
    loadEpubChapter(chapter, paragraph, resumeOffset);
    return true;
}

void NovelBridge::showEpubOfflineGap(int chapter)
{
    const int index = qBound(0, chapter, qMax(0, m_epubChapterCount - 1));
    m_chapter = TxtChapterText();
    m_paragraphs.clear();
    m_anchorParagraph = -1;
    m_chapterIndex = index;
    m_chapterTitle = m_epubTitles.value(index);
    // 同 txt：不写进度，续读点留在真正读到过的地方
    setStatus(QStringLiteral("离线 · 本章未缓存"));
    setPercent(epubPercent(index, -1));
    emit chapterChanged();
}

void NovelBridge::handOffToComic()
{
    const QString connectionId = m_connectionId;
    const QString path = m_path;
    const QString title = m_title;
    MH_INFO(NovelIndex, QStringLiteral("epub 是图集（整页图片），转交漫画阅读器：%1").arg(path));

    // 一拍之后再拆现场：这段栈还压在 `EpubBook` 的读回调里，当场 teardown 等于
    // 析构正在执行的对象。延后到事件循环下一轮，回调已经全部返回
    QTimer::singleShot(0, this, [this, connectionId, path, title]() {
        // 用户在这一轮里已经关掉（或换了一本）：别再自作主张弹出漫画阅读器
        if (m_path != path || m_connectionId != connectionId) {
            return;
        }
        teardown();
        m_opened = false;
        // teardown 只清值不发信号，而 `NovelReaderView` 的 visible 绑着 loading / errorText；
        // 少了这一下，覆盖层会停在「准备打开…」那一帧不下来
        emit loadingChanged();
        emit openedChanged();
        emit bookChanged();
        ComicBridge::instance()->open(connectionId, path, title);
    });
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
    int resumeOffset = 0;
    ProgressRecord record;
    if (ProgressRepository::instance().find(m_connectionId, m_path, &record) && !record.finished) {
        resumeChapter = record.progress.value(QStringLiteral("chapter")).toInt();
        resumeParagraph = record.progress.value(QStringLiteral("paragraph"), -1).toInt();
        resumeOffset = record.progress.value(QStringLiteral("charOffset"), 0).toInt();
    }

    m_epub->load([this, resumeChapter, resumeParagraph, resumeOffset](EpubMetadata metadata,
                                                                      StorageError error) {
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
        // 判定结论回写：列目录时靠它给 epub 挂漫画徽标，「下一本」靠它认出图集 epub。
        // 两条路都要记 —— 「查过了，不是图集」也是结论，记下来才好给文字书省掉重判
        ComicDetector::remember(m_connectionId, m_path, metadata.imageOnly, m_fileSize,
                                ComicDetector::secondsFromMillis(m_modTime));

        // 整本都是整页图片（漫画打包成的 epub）：这里只能解出空段落，
        // 交给漫画阅读器按页看才是正解
        if (metadata.imageOnly) {
            if (!metadata.title.isEmpty()) {
                m_title = metadata.title;
            }
            handOffToComic();
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

        // 目录快照：下次源够不着时靠它还原章数与章名（正文另有章节缓存）
        EpubMeta snapshot;
        snapshot.title = metadata.title;
        snapshot.author = metadata.author;
        snapshot.language = metadata.language;
        snapshot.coverHref = m_epub ? m_epub->coverHref() : QString();
        snapshot.chapters = metadata.chapters;
        snapshot.fileSize = m_fileSize;
        snapshot.modTime = m_modTime;
        EpubMetaStore::save(m_connectionId, m_path, snapshot);

        rebuildChapters();
        m_opened = true;
        emit openedChanged();
        emit bookChanged();
        setStatus(QString());

        const int chapter = qBound(0, resumeChapter, m_epubChapterCount - 1);
        loadEpubChapter(chapter, resumeParagraph, resumeOffset);
    });
}

void NovelBridge::loadEpubChapter(int chapter, int anchorParagraph, int anchorOffset)
{
    if (!epubMode() || m_epubChapterCount <= 0) {
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
        applyEpubChapter(chapter, it->paragraphs, anchorParagraph, anchorOffset);
        return;
    }

    // 其次看落盘缓存：冷启动 / 换设备后翻回读过的章，同样一次 Range 都不用发
    QStringList cachedParagraphs;
    if (NovelChapterCache::loadEpub(m_connectionId, m_path, fingerprint(), chapter,
                                    &cachedParagraphs)) {
        ++m_loadSerial;
        invalidatePrefetch();
        stopLoading();
        applyEpubChapter(chapter, cachedParagraphs, anchorParagraph, anchorOffset);
        return;
    }

    // 离线打开时没有 EpubBook（zip 根本没打开），只能停在「未缓存」上：
    // 不能走 fail()，否则整块阅读器被错误页盖住，缓存的章也翻不回去
    if (!m_epub) {
        showEpubOfflineGap(chapter);
        return;
    }

    invalidatePrefetch();
    const quint64 loadSerial = ++m_loadSerial;
    m_loading = true;
    emit loadingChanged();

    // EpubBook 内部用递增序列号丢弃过期结果，连点「下一章」不会被旧章节覆盖
    m_epub->readChapter(chapter,
                        [this, chapter, anchorParagraph, anchorOffset,
                         loadSerial](QStringList paragraphs, StorageError error) {
                            if (loadSerial != m_loadSerial) {
                                return; // 已被更新的切章顶掉，loading 由新加载自己管
                            }
                            m_loading = false;
                            emit loadingChanged();
                            if (!error.isNull()) {
                                fail(error.message().isEmpty() ? QStringLiteral("章节读取失败")
                                                               : error.message());
                                return;
                            }
                            cacheEpubChapter(chapter, paragraphs);
                            applyEpubChapter(chapter, paragraphs, anchorParagraph, anchorOffset);
                        });
}

void NovelBridge::applyEpubChapter(int chapter, const QStringList &paragraphs, int anchorParagraph,
                                   int anchorOffset)
{
    // epub 没有字节行表，清掉 txt 的残留（reportParagraph 靠它判断走哪条路径）
    m_chapter = TxtChapterText();
    m_chapterIndex = chapter;
    m_chapterTitle = m_epubTitles.value(chapter);
    // 插图占一格：换成空段落 + 一张待取的图，下标空间与进度锚点都不动
    resetImages(paragraphs);
    // <h1> 章名会被解成第 0 段，与页眉重复：标出来，交给标题带画
    m_titleParagraph = !m_paragraphs.isEmpty()
            && looksLikeChapterHeading(m_paragraphs.constFirst(), m_chapterTitle)
        ? 0
        : -1;
    m_anchorParagraph = paragraphs.isEmpty()
        ? -1
        : qBound(-1, anchorParagraph, static_cast<int>(paragraphs.size()) - 1);
    // 段内偏移只在「续读」那一次有意义，其余切章一律按段首；
    // 空段落没有字符，偏移必然是 0
    m_anchorOffset = m_anchorParagraph >= 0 ? qMax(0, anchorOffset) : 0;
    // 封面页 / 纯图片页会解出空白：不是错误，只是这一章没有文字。
    // 离线时状态栏要一直挂着「只看缓存」，否则用户会以为整本都能读
    // 「只有图没有字」的章（扉页、插页）不算「没有可显示的文字」：
    // 插图段落已经在 m_images 里排上队了
    if (m_offline) {
        setStatus(QStringLiteral("离线 · 仅显示已缓存的章节"));
    } else if (paragraphs.isEmpty()) {
        setStatus(QStringLiteral("本章没有可显示的文字"));
    } else {
        setStatus(QString());
    }

    saveEpubProgress(chapter, m_anchorParagraph, false, m_anchorOffset);
    setPercent(epubPercent(chapter, m_anchorParagraph));
    // 先分页再发 chapterChanged：QML 收到信号时读到的已经是新章的页数与当前页
    syncPageToAnchor();
    emit chapterChanged();
    ++m_imageRevision;
    emit imageRevisionChanged();

    prefetchAdjacent(chapter);
}

void NovelBridge::resetImages(const QStringList &paragraphs)
{
    clearImages();
    m_paragraphs.clear();
    m_paragraphs.reserve(paragraphs.size());

    QStringList pending;
    for (int i = 0; i < paragraphs.size(); ++i) {
        const QString &paragraph = paragraphs.at(i);
        if (!EpubBook::isImageParagraph(paragraph)) {
            m_paragraphs.append(paragraph);
            continue;
        }

        // 占位段落本身不显示文字：QML 认出 isImageParagraph(index) 就换成图
        m_paragraphs.append(QString());
        const QString entry = EpubBook::imageEntryOf(paragraph);
        if (entry.isEmpty()) {
            continue;
        }

        ChapterImage image;
        image.entry = entry;
        adoptImageSnapshot(entry, &image.url, &image.size);
        // 没快照也先记下来：QML 据此显示「加载中」而不是一片空白
        m_images.insert(i, image);
        if (image.url.isEmpty() && !pending.contains(entry)) {
            pending.append(entry);
        }
    }

    if (!pending.isEmpty() && m_epub) {
        m_imageQueue.append(pending);
        pumpImageQueue();
    }
}

void NovelBridge::pumpImageQueue()
{
    // 串行：一次一张。zip 的 Range 读并发打散反而更慢，还会顶掉章节请求的优先级
    if (!m_epub || m_imageQueue.isEmpty()) {
        return;
    }
    const QString entry = m_imageQueue.takeFirst();
    const quint64 serial = m_imageSerial;
    m_epub->readResource(entry, [this, serial, entry](QByteArray bytes, StorageError error) {
        if (serial != m_imageSerial) {
            // 已换章 / 换书：这张丢掉，但队列属于新章，接着取
            pumpImageQueue();
            return;
        }
        if (error.isNull() && !bytes.isEmpty()) {
            const QString file = imageSnapshotPath(entry);
            if (NovelImageStore::save(file, bytes)) {
                const QString url = QUrl::fromLocalFile(file).toString();
                const QSize size = QImageReader(file).size();
                // 同一条目可能被多处引用（同一张图重复出现），全部换上
                for (auto &image : m_images) {
                    if (image.entry != entry) {
                        continue;
                    }
                    image.url = url;
                    image.size = size;
                }
                ++m_imageRevision;
                emit imageRevisionChanged();
            }
        } else {
            MH_WARN(NovelIndex, QStringLiteral("插图取不到：%1").arg(entry));
        }
        pumpImageQueue();
    });
}

QString NovelBridge::imageSnapshotPath(const QString &entry) const
{
    return NovelImageStore::pathFor(m_connectionId, m_path, m_fileSize, m_modTime, entry);
}

bool NovelBridge::adoptImageSnapshot(const QString &entry, QString *url, QSize *size) const
{
    const QString file = imageSnapshotPath(entry);
    if (!QFileInfo::exists(file)) {
        return false;
    }
    // 命中即刷新 mtime：LRU 按 mtime 淘汰，常看的书不该先被清掉
    NovelImageStore::touch(file);
    if (url != nullptr) {
        *url = QUrl::fromLocalFile(file).toString();
    }
    if (size != nullptr) {
        *size = QImageReader(file).size();
    }
    return true;
}

void NovelBridge::clearImages()
{
    // 换章即作废在途取图：旧章的结果不该写进新章的下标表
    ++m_imageSerial;
    m_images.clear();
    m_imageQueue.clear();
}

bool NovelBridge::isImageParagraph(int paragraph) const
{
    return m_images.contains(paragraph);
}

QString NovelBridge::imageUrl(int paragraph) const
{
    return m_images.value(paragraph).url;
}

QSize NovelBridge::imageSize(int paragraph) const
{
    return m_images.value(paragraph).size;
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

void NovelBridge::saveEpubProgress(int chapter, int paragraph, bool finished, int charOffset)
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
    // 段内偏移是「段落锚点」的细化：老记录没有这个键，读到 0 即按段首
    record.progress.insert(QStringLiteral("charOffset"), qMax(0, charOffset));
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

void NovelBridge::loadChapter(int chapter, qint64 anchorByte, int anchorOffset)
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
        applyChapter(it->text, m_index.chapterStart(chapter), anchorOffset);
        return;
    }

    // 落盘缓存：锚点必须带上 —— 续读点很可能就落在刚被缓存下来的那一章，
    // 用章首顶替会把「读到第几段」洗掉
    TxtChapterText cachedText;
    if (NovelChapterCache::loadTxt(m_connectionId, m_path, fingerprint(), chapter, &cachedText)) {
        ++m_loadSerial;
        invalidatePrefetch();
        stopLoading();
        applyChapter(cachedText, anchorByte > 0 ? anchorByte : m_index.chapterStart(chapter),
                     anchorOffset);
        return;
    }

    invalidatePrefetch();
    const quint64 loadSerial = ++m_loadSerial;
    m_loading = true;
    emit loadingChanged();

    TxtChapterLoader::load(m_source, m_index, chapter,
                           [this, chapter, anchorByte, anchorOffset,
                            loadSerial](TxtChapterText text, StorageError error) {
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
                                   fail(error.message().isEmpty() ? QStringLiteral("章节读取失败")
                                                                  : error.message());
                                   return;
                               }
                               cacheTxtChapter(chapter, text);
                               applyChapter(text, anchorByte, anchorOffset);
                           });
}

void NovelBridge::applyChapter(const TxtChapterText &text, qint64 anchorByte, int anchorOffset)
{
    m_chapter = text;
    m_chapterIndex = m_index.chapterAt(text.start);
    m_chapterTitle = text.title;
    m_paragraphs = text.paragraphs();
    // txt 的章名行本来就被 firstBodyLine 摘掉了，这里多数情况认不出来（正常）
    m_titleParagraph = !m_paragraphs.isEmpty()
            && looksLikeChapterHeading(m_paragraphs.constFirst(), m_chapterTitle)
        ? 0
        : -1;

    // 锚点换算成段落下标：QML 只认段落序号，换算的权威在行表里
    m_anchorParagraph = anchorByte > 0 ? text.paragraphAtByte(anchorByte) : -1;
    // 字节锚点只到段落，段内偏移得单独带：长段落跨页时靠它落回原行
    m_anchorOffset = m_anchorParagraph >= 0 ? qMax(0, anchorOffset) : 0;

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

    saveProgress(anchor, false, m_anchorOffset);
    setPercent(m_index.percentAt(anchor));
    syncPageToAnchor();
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
            // 落盘缓存优先：翻回读过的章连一次 zip 条目读都不用发
            QStringList cachedParagraphs;
            if (NovelChapterCache::loadEpub(m_connectionId, m_path, fingerprint(), chapter,
                                            &cachedParagraphs)) {
                rememberChapter(chapter, true, cachedParagraphs, TxtChapterText());
                continue;
            }
            // 离线（没有 EpubBook）：缓存里没有的章再也取不到，预取到此为止，
            // 但上面那步落盘命中的邻章仍然要装进内存 —— 否则翻过去还要再查一次
            if (!m_epub) {
                return;
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
    // 滚动模式只知道「哪一段」，段内偏移按段首算
    reportPosition(index, 0);
}

void NovelBridge::reportPosition(int index, int charOffset)
{
    if (!m_opened) {
        return;
    }
    // 已读到底：位置只会停在末尾，再写一次普通进度会把 finished 洗回 false
    if (m_bookEnd) {
        return;
    }

    const int offset = qMax(0, charOffset);
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
    m_pendingOffset = offset;

    // 锚点立刻跟上（不等节流）：重排要按当前读到的这一行重新定位
    m_anchorParagraph = index;
    m_anchorOffset = offset;

    // 翻页模式下锚点还会被别处改（拖进度条、跳目录）：页码要跟着锚点走，
    // 否则界面停在旧页而 percent 已经变了。放在节流之前 —— 翻页是连点，不能被 1s 卡住
    if (m_pageMode) {
        const int page = m_pager.pageOfPosition(index, offset);
        if (page >= 0 && page != m_pageIndex) {
            m_pageIndex = page;
            emit pageChanged();
        }
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
        m_pendingOffset = 0;
        return;
    }

    if (epubMode()) {
        if (m_pendingChapter < 0 || m_pendingParagraph < 0) {
            return;
        }
        const int chapter = m_pendingChapter;
        const int paragraph = m_pendingParagraph;
        const int offset = m_pendingOffset;
        m_pendingChapter = -1;
        m_pendingParagraph = -1;
        m_pendingOffset = 0;
        // 只发 percentChanged：发 chapterChanged 会让 QML 重建段落 model，把列表弹回顶部
        saveEpubProgress(chapter, paragraph, false, offset);
        setPercent(epubPercent(chapter, paragraph));
        m_reportClock.start();
        return;
    }

    if (m_pendingByte < 0) {
        return;
    }
    const qint64 byte = m_pendingByte;
    const int offset = m_pendingOffset;
    m_pendingByte = -1;
    m_pendingOffset = 0;
    saveProgress(byte, false, offset);
    setPercent(m_index.percentAt(byte));
    m_reportClock.start();
}

void NovelBridge::saveProgress(qint64 byteOffset, bool finished, int charOffset)
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
    // 字节锚点是段落粒度，段内偏移单独记：长段落跨页时靠它落回原行
    record.progress.insert(QStringLiteral("charOffset"), qMax(0, charOffset));
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
    m_titleParagraph = -1;
    m_anchorParagraph = -1;
    m_anchorOffset = 0;
    m_percent = 0.0;
    m_pendingByte = -1;
    m_pendingChapter = -1;
    m_pendingParagraph = -1;
    m_pendingOffset = 0;
    m_fileSize = 0;
    m_modTime = 0;
    m_paragraphs.clear();
    // 插图属于这本书：条目名 / 快照 URL 一并丢弃，在途取图靠序列号作废
    clearImages();
    ++m_imageRevision;
    emit imageRevisionChanged();
    // 分页结果属于这本书：正文清空后重排只剩一页空页，页码也归零
    m_pager.setText(QStringList(), QSet<int>());
    m_pager.relayout();
    m_pageIndex = 0;
    m_pendingPageEnd = false;
    notifyPagination();
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
        // 读到最后一段的最后：偏移没有意义，按段首记（重开时落在该段所在页）
        saveEpubProgress(chapter, paragraph, true, 0);
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
    saveProgress(byte, true, 0);
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

// ---------------------------------------------------------------- 翻页模式

void NovelBridge::setPageViewport(int width, int height)
{
    m_pageWidth = width;
    m_pageHeight = height;
    // 字体以本对象的偏好为准：QML 画正文与这里折行用的是同一串族名
    m_pager.setTypography(m_fontFamilies, m_fontSize, m_lineSpacing);
    m_pager.setViewport(width, height);
    repaginate();
}

void NovelBridge::repaginate()
{
    // 重排会改页数（字号、行距、字体、窗口宽度都会），所以按「当前页首行」重新定位：
    // 页码不是身份，段落 + 段内偏移才是
    // 还没排过版（刚开书、视口刚推上来）时旧页码里没有位置信息，只能信锚点 ——
    // 否则续读的段内偏移会在第一次布局时被抹成段首
    const bool firstLayout = m_pager.pageCount() == 0;
    int anchorParagraph = -1;
    int anchorOffset = 0;
    if (firstLayout) {
        anchorParagraph = m_anchorParagraph;
        anchorOffset = m_anchorOffset;
    } else {
        m_pager.positionOfPage(m_pageIndex, &anchorParagraph, &anchorOffset);
    }

    m_pager.setTitleParagraph(m_titleParagraph);
    m_pager.setText(m_paragraphs, QSet<int>(m_images.keyBegin(), m_images.keyEnd()));
    m_pager.relayout();

    int page = m_pageIndex;
    if (anchorParagraph >= 0) {
        const int at = m_pager.pageOfPosition(anchorParagraph, anchorOffset);
        if (at >= 0) {
            page = at;
        }
    }
    page = m_pager.pageCount() > 0 ? qBound(0, page, m_pager.pageCount() - 1) : 0;

    const bool moved = page != m_pageIndex;
    m_pageIndex = page;
    notifyPagination();
    if (moved) {
        emit pageChanged();
    }
}

void NovelBridge::syncPageToAnchor()
{
    m_pager.setTitleParagraph(m_titleParagraph);
    m_pager.setText(m_paragraphs, QSet<int>(m_images.keyBegin(), m_images.keyEnd()));
    m_pager.relayout();

    int page = 0;
    if (m_pendingPageEnd && m_pager.pageCount() > 0) {
        // 往回翻跨章：新章落地后落在最后一页，而不是被锚点拉回章首
        page = m_pager.pageCount() - 1;
    } else if (m_anchorParagraph >= 0) {
        // 段落 + 段内偏移：长段落跨页时才能落回读到的行，而不是这一段的第一页
        const int at = m_pager.pageOfPosition(m_anchorParagraph, m_anchorOffset);
        if (at >= 0) {
            page = at;
        }
    }
    m_pendingPageEnd = false;

    const bool moved = page != m_pageIndex;
    m_pageIndex = page;
    notifyPagination();
    if (moved) {
        emit pageChanged();
    }
}

void NovelBridge::notifyPagination()
{
    ++m_paginationRevision;
    emit paginationChanged();
}

void NovelBridge::setPageMode(bool pageMode)
{
    if (pageMode == m_pageMode) {
        return;
    }
    m_pageMode = pageMode;
    storePreference(kPageModeKey, m_pageMode);
    emit pageModeChanged();
}

void NovelBridge::setPageIndex(int index)
{
    const int count = m_pager.pageCount();
    const int clamped = count > 0 ? qBound(0, index, count - 1) : 0;
    if (clamped == m_pageIndex) {
        return;
    }
    m_pageIndex = clamped;
    emit pageChanged();

    // 翻页就是阅读位置：进度按「本页首行」上报；页码本身不进持久化
    int paragraph = -1;
    int offset = 0;
    m_pager.positionOfPage(m_pageIndex, &paragraph, &offset);
    if (paragraph >= 0) {
        reportPosition(paragraph, offset);
    }
}

QStringList NovelBridge::pageLines(int page) const
{
    return m_pager.linesOf(page);
}

int NovelBridge::pageImageParagraph(int page) const
{
    return m_pager.imageParagraphOf(page);
}

int NovelBridge::pageForParagraph(int paragraph) const
{
    return m_pager.pageOfParagraph(paragraph);
}

int NovelBridge::pageForPosition(int paragraph, int charOffset) const
{
    return m_pager.pageOfPosition(paragraph, charOffset);
}

bool NovelBridge::nextPage()
{
    if (!m_opened) {
        return false;
    }
    if (m_pageIndex + 1 < m_pager.pageCount()) {
        setPageIndex(m_pageIndex + 1);
        return true;
    }
    if (m_chapterIndex + 1 < chapterCount()) {
        nextChapter();
        return true;
    }
    return false;
}

bool NovelBridge::prevPage()
{
    if (!m_opened) {
        return false;
    }
    if (m_pageIndex > 0) {
        setPageIndex(m_pageIndex - 1);
        return true;
    }
    if (m_chapterIndex > 0) {
        // 章节异步加载：记号留下，等新章落地时落到最后一页
        m_pendingPageEnd = true;
        prevChapter();
        return true;
    }
    return false;
}

// ---------------------------------------------------------------- 排版偏好

void NovelBridge::loadPreferences()
{
    AppSettings &settings = AppSettings::instance();
    m_fontSize = qBound(kMinFontSize, settings.value(kFontSizeKey, 17).toInt(), kMaxFontSize);
    m_lineSpacing =
        qBound(kMinLineSpacing, settings.value(kLineSpacingKey, 1.6).toDouble(), kMaxLineSpacing);
    m_fontStyle = qBound(0, settings.value(kFontStyleKey, 0).toInt(), 1);
    m_fontFamilies = familiesForStyle(m_fontStyle);
    m_theme = qBound(0, settings.value(kThemeKey, 0).toInt(), 3);
    m_brightness = settings.value(kBrightnessKey, -1.0).toDouble();
    m_pageMode = settings.value(kPageModeKey, false).toBool();
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
    // 字变了行数就变：整章重排（页码按当前页首行重新定位）
    m_pager.setTypography(m_fontFamilies, m_fontSize, m_lineSpacing);
    repaginate();
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
    m_pager.setTypography(m_fontFamilies, m_fontSize, m_lineSpacing);
    repaginate();
}

void NovelBridge::setFontStyle(int style)
{
    const int clamped = qBound(0, style, 1);
    if (clamped == m_fontStyle) {
        return;
    }
    m_fontStyle = clamped;
    m_fontFamilies = familiesForStyle(m_fontStyle);
    storePreference(kFontStyleKey, m_fontStyle);
    emit fontChanged();
    // 换字体等于换字宽：行数与页数都会变，和改字号同一条路（整章重排 + 按首行重新定位）
    m_pager.setTypography(m_fontFamilies, m_fontSize, m_lineSpacing);
    repaginate();
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
