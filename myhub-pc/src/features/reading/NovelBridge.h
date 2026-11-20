#pragma once

#include "core/novel/NovelChapterCache.h"
#include "core/novel/NovelIndex.h"
#include "core/novel/TxtChapterLoader.h"
#include "features/reading/NovelPager.h"

#include <QElapsedTimer>
#include <QHash>
#include <QList>
#include <QObject>
#include <QQmlEngine>
#include <QSize>
#include <QString>
#include <QStringList>
#include <QVariantList>

#include <memory>

namespace myhub {

class EpubBook;
struct ProgressRecord;
class RangeSource;
class StorageAdapter;
class TxtIndexer;
struct FileEntry;

/**
 * 小说阅读器的 QML 桥接（QML 侧单例名 `Novel`）。
 *
 * 负责把「索引 → 按章加载 → 锚点定位 → 进度落库」串起来，QML 只管画。
 * 分层理由同 PlayerBridge：分章逻辑在 myhub_core（可单测），QML 只消费结果。
 *
 * 一条纪律：**txt 的进度锚点是全局字节偏移**（§5.1 PC-203），不是章号也不是字符下标。
 * 章号会在重扫后失效（规则漂移），字符下标会随字号/窗口宽度变化，
 * 只有「原始文件的第 N 个字节」在换设备、换排版后仍然指向同一句话。
 *
 * epub 是唯一例外：zip 里的章节是独立条目，彼此没有连续的字节坐标，
 * 硬凑一个「全局偏移」只能靠累加各条目大小，而条目顺序一变就全错。
 * 所以 epub 用「**章号 + 段落下标**」作锚点（`progress.chapter` / `progress.paragraph`），
 * 章号来自 OPF spine 顺序 —— epub 的章节边界是作者写死的，不像 txt 那样靠规则猜。
 *
 * txt 打开流程：
 *   1. 指纹（size + modTime）命中 `novelIndex` 缓存 → 直接用，零扫描；
 *   2. 未命中 → `TxtIndexer` 流式建索引（进度回传 UI），完成即落库；
 *   3. 一章都没识别出来 → 「整本单章」兜底，阅读器永远只处理一种情况。
 *
 * epub 打开流程：`EpubBook::load()` 读 container → OPF → NAV/NCX 拿目录，
 * 目录直接就是章节列表，没有「建索引」这一步；目录本身另存一份快照
 * （`EpubMetaStore`），供「文件够不着」时还原章数与章名。
 */
class NovelBridge : public QObject
{
    Q_OBJECT
    QML_NAMED_ELEMENT(Novel)
    QML_SINGLETON

    Q_PROPERTY(bool opened READ opened NOTIFY openedChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    Q_PROPERTY(QString title READ title NOTIFY bookChanged)
    Q_PROPERTY(QString chapterTitle READ chapterTitle NOTIFY chapterChanged)
    /// 当前章的正文段落（ListView 的 model，一段一个 item，可回收）
    Q_PROPERTY(QStringList paragraphs READ paragraphs NOTIFY chapterChanged)
    Q_PROPERTY(int chapterIndex READ chapterIndex NOTIFY chapterChanged)
    Q_PROPERTY(int chapterCount READ chapterCount NOTIFY bookChanged)
    Q_PROPERTY(QVariantList chapters READ chapters NOTIFY bookChanged)
    Q_PROPERTY(double percent READ percent NOTIFY percentChanged)
    /// 打开时要定位到的段落下标（-1 = 从头看）
    Q_PROPERTY(int anchorParagraph READ anchorParagraph NOTIFY chapterChanged)
    /// 建索引时的进度文案（0 章时也有内容，避免用户对着空白屏等）
    Q_PROPERTY(QString statusText READ statusText NOTIFY statusChanged)
    Q_PROPERTY(QString errorText READ errorText NOTIFY errorTextChanged)
    /// 文件当前不可用（离线 / 源不可达），阅读器只在已缓存的章节之间工作
    Q_PROPERTY(bool offline READ offline NOTIFY offlineChanged)
    /**
     * 插图落地计数：每取到一张就 +1。
     *
     * 段落 model 不因插图变化而重建（那会把列表滚回顶部），所以 QML 侧必须显式
     * 依赖这个值，插图写完时富文本才会重算。
     */
    Q_PROPERTY(int imageRevision READ imageRevision NOTIFY imageRevisionChanged)
    /**
     * 读完本书后推荐的「同目录下一本」（§4.6 的阅读侧对应）。
     *
     * 空 map = 没有候选（末本 / 目录里没有书 / 目录读不到）。
     * **只给候选，绝不自动翻**：是否切换由用户点击决定，也不做倒计时。
     */
    Q_PROPERTY(QVariantMap nextSuggestion READ nextSuggestion NOTIFY nextSuggestionChanged)

    // ---- 翻页模式（§5.1）：行级分页在 NovelPager，这里只管「第几页」与重排时机 ----
    /// 滚动 / 翻页。翻页模式下页码**不进持久化**，进度仍按段落下标存
    Q_PROPERTY(bool pageMode READ pageMode WRITE setPageMode NOTIFY pageModeChanged)
    Q_PROPERTY(int pageIndex READ pageIndex WRITE setPageIndex NOTIFY pageChanged)
    Q_PROPERTY(int pageCount READ pageCount NOTIFY paginationChanged)
    /// 单行行距（px）：QML 按固定行高画，才能与 C++ 分出的行数严丝合缝
    Q_PROPERTY(int pageLineHeight READ pageLineHeight NOTIFY paginationChanged)
    /// 每次重排自增：页内容不是属性，QML 只能靠它建立依赖，否则页数不变时会画着旧内容
    Q_PROPERTY(int paginationRevision READ paginationRevision NOTIFY paginationChanged)
    /**
     * 章名段落下标（-1 = 这一章没有单独成段的章名）。
     *
     * epub 的 `<h1>` 会落成第 0 段，与页眉里的章名重复：这里把它标出来，
     * 滚动模式跳过这一项、翻页模式交给「标题带」画 —— 章名全章只出现一次。
     */
    Q_PROPERTY(int titleParagraph READ titleParagraph NOTIFY chapterChanged)
    /// 标题带落在哪一页（-1 = 没有标题带）
    Q_PROPERTY(int titlePage READ titlePage NOTIFY paginationChanged)
    /// 标题带高度（px）：这一页顶部预留这么多，正文从它下面开始
    Q_PROPERTY(int titleReserve READ titleReserve NOTIFY paginationChanged)

    // ---- 排版偏好（落 AppSettings，键名与 iOS 对齐）----
    Q_PROPERTY(int fontSize READ fontSize WRITE setFontSize NOTIFY fontSizeChanged)
    Q_PROPERTY(double lineSpacing READ lineSpacing WRITE setLineSpacing NOTIFY lineSpacingChanged)
    /**
     * 正文字体族列表（逗号分隔）：QML 直接塞给 `font.family`，同一串也原样交给分页器。
     *
     * 只能有一个来源 —— 分页测行宽用的字体必须与 QML 画正文的字体一致，
     * 否则量出来一行能放 30 字、屏幕上只放得下 28 字，页尾就会溢出。
     * 所以字体偏好住在桥接层，QML 与 C++ 都从这里取值。
     */
    Q_PROPERTY(QString fontFamilies READ fontFamilies NOTIFY fontChanged)
    /// 0=黑体（无衬线，界面默认） 1=宋体（衬线，长文更耐读）
    Q_PROPERTY(int fontStyle READ fontStyle WRITE setFontStyle NOTIFY fontChanged)
    /// 0=跟随系统 1=日间 2=夜间 3=护眼
    Q_PROPERTY(int theme READ theme WRITE setTheme NOTIFY themeChanged)
    Q_PROPERTY(double brightness READ brightness WRITE setBrightness NOTIFY brightnessChanged)

public:
    static NovelBridge *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);
    static NovelBridge *instance();

    /**
     * 打开一本小说。
     *
     * `connectionId` 必须是 `ConnectionStore` 里真实存在的连接源 id —— 本地目录在
     * 本产品里也是一条「本地存储」连接，由 StorageAdapterFactory 统一出适配器。
     * 桥接层不自己判断路径是本地还是远程：判断散在两边就会出现「本地能读、远程不能」的分叉。
     */
    /// 按值接收：「打开下一本」传进来的就是 m_connectionId / m_path 本身，
    /// teardown() 清空成员后引用会变成空串，所以这里必须拿到自己的副本
    Q_INVOKABLE void open(QString connectionId, QString path, const QString &title);

    Q_INVOKABLE void goToChapter(int index);
    Q_INVOKABLE void nextChapter();
    Q_INVOKABLE void prevChapter();

    /// 关闭阅读器并落盘进度
    Q_INVOKABLE void close();

    /// 滚动时上报「当前可见的首段落下标」：txt 换算成字节偏移、epub 记章号+段落（1s 节流）
    Q_INVOKABLE void reportParagraph(int index);
    /**
     * 上报「段落 + 段内字符偏移」（偏移以**原始文案**为准，不含首行缩进）。
     *
     * 翻页模式用它把锚点钉到行：长段落横跨几页时，只记段落下标会让读者
     * 下次打开被拉回这一段的第一页。锚点仍以段落为主键，偏移只是它的细化。
     */
    Q_INVOKABLE void reportPosition(int paragraph, int charOffset);

    // ---- 正文插图（epub）----
    /// 这一段是不是插图：正文里插图占一格，段落文本是空串
    Q_INVOKABLE bool isImageParagraph(int paragraph) const;
    /// 插图快照的本地 URL；空串 = 还没取到（或离线且没缓存过）
    Q_INVOKABLE QString imageUrl(int paragraph) const;
    /// 插图原始像素尺寸；0x0 = 还不知道（QML 用它算等比高度，避免先按 0 高再跳一下）
    Q_INVOKABLE QSize imageSize(int paragraph) const;
    int imageRevision() const { return m_imageRevision; }

    // ---- 翻页模式 ----
    /**
     * 告知正文可视区尺寸与字体族列表并重排（QML 布局稳定后调用，只在翻页模式下有意义）。
     *
     * 字体必须由 QML 传：`AppTheme.fontFamily` 是一串候选族名，C++ 里再硬编码一份
     * 迟早与 QML 不一致，那时候量出来的行宽就是假的。
     */
    Q_INVOKABLE void setPageViewport(int width, int height);
    /// 第 page 页的文本行（QML 用 `\n` 串起来画成一块固定行高的 Text）
    Q_INVOKABLE QStringList pageLines(int page) const;
    /// 第 page 页若是整页插图，返回段落下标；-1 = 文字页
    Q_INVOKABLE int pageImageParagraph(int page) const;
    /// 段落 → 页码（-1 = 没有这一页）：恢复进度时一步定位
    Q_INVOKABLE int pageForParagraph(int paragraph) const;
    /// 段落 + 段内偏移 → 页码（-1 = 没有这一页）：恢复进度时一步定位
    Q_INVOKABLE int pageForPosition(int paragraph, int charOffset) const;
    /// 翻页；跨章时自动换章（返回 false 表示已经到头/到顶）
    Q_INVOKABLE bool nextPage();
    Q_INVOKABLE bool prevPage();

    bool pageMode() const { return m_pageMode; }
    void setPageMode(bool pageMode);
    int pageIndex() const { return m_pageIndex; }
    void setPageIndex(int index);
    int pageCount() const { return m_pager.pageCount(); }
    int pageLineHeight() const { return m_pager.lineHeight(); }
    int paginationRevision() const { return m_paginationRevision; }
    int titleParagraph() const { return m_titleParagraph; }
    int titlePage() const { return m_pager.titlePage(); }
    int titleReserve() const { return m_pager.titleReserve(); }

    /**
     * 「是否已翻到全书最后」（末章末尾）。
     *
     * 由 QML 判定 —— 只有滚动视图知道「当前屏是不是最后一屏」，C++ 按字节/段落
     * 猜末尾会在短章、插图、行距变化上误判。这里只负责状态迁移：
     *   · 进入末尾 → 落一次 `finished` 进度（首页据此显示「已读完」）+ 查下一本；
     *   · 离开末尾（往回翻）→ 撤销提示条，下一次读完还能再推。
     */
    Q_INVOKABLE void setAtBookEnd(bool atEnd);
    /// 打开推荐的那本（保留它自己的续读点 —— 只是换书，不是重读）
    Q_INVOKABLE void openNextSuggestion();
    /// 用户收起提示条：本次「读到底」不再重复查询
    Q_INVOKABLE void dismissNextSuggestion();

    /// 该章是否已在预取缓存里（切章会同步生效，不再等一次 Range 往返）；调试/测试用
    bool hasCachedChapter(int index) const { return m_cache.contains(index); }

    bool opened() const { return m_opened; }
    bool loading() const { return m_loading; }
    QString title() const { return m_title; }
    QString chapterTitle() const { return m_chapterTitle; }
    QStringList paragraphs() const { return m_paragraphs; }
    int chapterIndex() const { return m_chapterIndex; }
    int chapterCount() const
    {
        return m_epubChapterCount > 0 ? m_epubChapterCount : m_index.count();
    }
    QVariantList chapters() const { return m_chapters; }
    double percent() const { return m_percent; }
    int anchorParagraph() const { return m_anchorParagraph; }
    /// 锚点的段内字符偏移（原始文案坐标）；0 = 段首
    int anchorOffset() const { return m_anchorOffset; }
    QString statusText() const { return m_statusText; }
    QString errorText() const { return m_errorText; }
    bool offline() const { return m_offline; }
    QVariantMap nextSuggestion() const { return m_nextSuggestion; }

    /// 当前打开的书（删除源文件前由 app 层判断是否正被占用；空串表示未打开）
    QString path() const { return m_path; }
    QString connectionId() const { return m_connectionId; }

    int fontSize() const { return m_fontSize; }
    void setFontSize(int px);
    double lineSpacing() const { return m_lineSpacing; }
    void setLineSpacing(double spacing);
    QString fontFamilies() const { return m_fontFamilies.join(QStringLiteral(", ")); }
    int fontStyle() const { return m_fontStyle; }
    void setFontStyle(int style);
    int theme() const { return m_theme; }
    void setTheme(int theme);
    double brightness() const { return m_brightness; }
    void setBrightness(double value);

signals:
    void openedChanged();
    void loadingChanged();
    void bookChanged();
    void chapterChanged();
    /// 只随滚动位置变化：不能复用 chapterChanged —— 那会让 QML 重建段落 model
    /// 并把列表滚回顶部，读者每滚动一次就被弹回去
    void percentChanged();
    void statusChanged();
    void errorTextChanged();
    void offlineChanged();
    /// 插图落地：QML 靠它重算参考文献里的 `<img>`
    void imageRevisionChanged();
    /// 下一本候选变化；空 map 表示没有可推荐的下一本
    void nextSuggestionChanged();
    void fontSizeChanged();
    void lineSpacingChanged();
    /// 字体族变了：QML 要重算正文宽度，分页要重排
    void fontChanged();
    void themeChanged();
    void brightnessChanged();
    void pageModeChanged();
    void pageChanged();
    /// 重排完成：页数、行距、每页内容全部换了一批，QML 必须重新取内容
    void paginationChanged();

private:
    explicit NovelBridge(QObject *parent = nullptr);
    ~NovelBridge() override;

    /**
     * 当前这本是不是 epub。
     *
     * 离线打开时没有 `EpubBook`（打不开 zip 才降级的），但 `m_epubChapterCount`
     * 已经从目录快照恢复 —— 两条 epub 分支（在线 / 离线）都要走 epub 的加载与进度逻辑。
     */
    bool epubMode() const { return m_epub != nullptr || m_epubChapterCount > 0; }

    void teardown();
    void fail(const QString &message);
    /**
     * 文件不可用（离线 / 源不可达 / 已被移走）时的降级打开。
     *
     * 有分章索引 + 至少一章正文缓存就进阅读器，只在缓存章节之间工作；
     * 返回 false 表示连目录都没有，调用方照原样报错。
     */
    bool openOffline(StorageAdapter *adapter, const StorageError &cause);
    /// 离线且本章没缓存：停在空章上并提示，绝不走 fail()（那是整块覆盖阅读器的错误页）
    void showOfflineGap(int chapter);
    void rebuildChapters();
    void startIndexing();
    /// txt：按索引区间取一章（`anchorOffset` = 锚点在该段内的字符偏移）
    void loadChapter(int chapter, qint64 anchorByte, int anchorOffset = 0);
    void applyChapter(const TxtChapterText &text, qint64 anchorByte, int anchorOffset = 0);
    void saveProgress(qint64 byteOffset, bool finished = false, int charOffset = 0);

    // ---- epub 分支（与 txt 的字节锚点并存，互不干扰）----
    void openEpub();
    /**
     * 离线打开 epub：目录来自 `EpubMetaStore` 快照，正文只放已缓存的章节。
     *
     * 没有快照、或一章正文都没缓存时返回 false（调用方照常报错）——
     * 打开一个没有目录的空壳比直说「离线且未缓存」更糟。
     */
    bool openEpubOffline();
    /// 离线 epub 缺章：停在空章上提示，不写进度（不篡改续读点）
    void showEpubOfflineGap(int chapter);
    void loadEpubChapter(int chapter, int anchorParagraph, int anchorOffset = 0);
    /**
     * 判定为图集（整本都是整页图片）：整本转交漫画阅读器。
     *
     * 小说阅读器对它只能解出空段落，目录也毫无意义；延迟一拍再拆现场 ——
     * 这个调用栈还在 `EpubBook` 的读回调里，当场析构它会踩到它自己的栈帧。
     */
    void handOffToComic();
    void applyEpubChapter(int chapter, const QStringList &paragraphs, int anchorParagraph,
                          int anchorOffset = 0);
    /**
     * 把章节里的插图占位段落换成「本地快照 URL + 待取队列」。
     *
     * 段落总数与下标空间**不变**（插图占一格、文本置空），进度锚点与滚动上报照旧。
     * 已在盘上的快照直接可用，其余的排进队列由 `pumpImageQueue()` 串行抽出来落盘。
     */
    void resetImages(const QStringList &paragraphs);
    /// 串行取图：一次一张，避免把 zip 的 Range 读打散
    void pumpImageQueue();
    QString imageSnapshotPath(const QString &entry) const;
    /// 快照已在盘上：填 URL 与像素尺寸（顺带 touch 刷新 LRU 的 mtime）
    bool adoptImageSnapshot(const QString &entry, QString *url, QSize *size) const;
    void clearImages();
    void saveEpubProgress(int chapter, int paragraph, bool finished = false, int charOffset = 0);
    /// 给进度记录带上当前文件指纹（未知记 -1）：首页用来校验封面缓存是否过期
    void applyFingerprint(ProgressRecord *record) const;
    /// 章号 + 段落下标 → 0..1；只用于进度条与首页百分比，不参与定位
    double epubPercent(int chapter, int paragraph) const;

    // ---- 邻章预取（±1，串行、不会挤掉在途的可见章节）----
    /// 切章 / 关闭时作废在途预取：预取结果只允许写缓存，绝不允许覆盖可见章
    void invalidatePrefetch();
    /// 缓存命中直接上屏时用：把上一次在途加载的 loading 态收掉
    void stopLoading();
    void prefetchAdjacent(int chapter);
    void pumpPrefetch();
    void rememberChapter(int chapter, bool epub, const QStringList &paragraphs,
                         const TxtChapterText &text);
    void trimCache();

    // ---- 章节落盘缓存（§5 NovelChapterCache）----
    /// 当前文件的指纹；文件信息拿不到时 `known()` 为假，缓存按「宁可信其有」放行
    NovelChapterCache::Fingerprint fingerprint() const
    {
        return NovelChapterCache::Fingerprint{m_fileSize, m_modTime};
    }
    void cacheTxtChapter(int chapter, const TxtChapterText &text);
    void cacheEpubChapter(int chapter, const QStringList &paragraphs);
    /// 把节流缓存下来的滚动位置真正落库（切章/关闭前必须先调）
    void commitPendingPosition();
    void setStatus(const QString &text);
    void loadPreferences();
    void storePreference(const QString &key, const QVariant &value);

    // ---- 翻页模式 ----
    /// 排版参数/视口变化后重排：按「当前页首段」重新定位，不让页码原地乱跳
    void repaginate();
    /// 换章后把页码对到进度锚点（-1 = 章首）
    void syncPageToAnchor();
    /// 重排结束：revision 自增 + 通知（QML 的页内容绑定都挂在 revision 上）
    void notifyPagination();

    // ---- 读完推荐（§4.6）----
    /// 把本书标记为已读完：percent 归 1，进度按 `finished` 落库（仅在线可用时）
    void markFinished();
    /// 由「书内位置」换算出的 percent 统一从这里写入：末尾状态下恒为 100%（含 emit）
    void setPercent(double percent);
    /// 查同目录下一本：排序跟随该目录偏好，与浏览页所见顺序一致
    void resolveNextSuggestion();
    void setNextSuggestion(const FileEntry &entry);
    void clearNextSuggestion();

    QString m_connectionId;
    QString m_path;
    QString m_title;
    QString m_chapterTitle;
    QStringList m_paragraphs;
    QString m_statusText;
    QString m_errorText;

    std::unique_ptr<RangeSource> m_sourceOwner;
    RangeSource *m_source = nullptr; ///< 由 m_sourceOwner 持有，这里只借用
    std::unique_ptr<TxtIndexer> m_indexer;
    std::unique_ptr<EpubBook> m_epub; ///< 非空即 epub 模式

    NovelIndex m_index;
    TxtChapterText m_chapter; ///< 当前章（上报进度时要用它的行表）
    QVariantList m_chapters;

    /// 当前章的一张插图：条目名 + 快照 URL（空 = 还没取到）+ 原始像素尺寸
    struct ChapterImage
    {
        QString entry;
        QString url;
        QSize size;
    };
    /// 段落下标 → 插图（只有插图段落才有条目）
    QHash<int, ChapterImage> m_images;
    QStringList m_imageQueue;  ///< 本章待取的条目名（串行泵）
    quint64 m_imageSerial = 0; ///< 换章 / 关闭即作废在途取图
    int m_imageRevision = 0;

    /// 预取缓存的一章：txt 留行表（命中后能直接换算锚点），epub 只有段落
    struct CachedChapter
    {
        TxtChapterText text;
        QStringList paragraphs;
        bool epub = false;
    };
    QHash<int, CachedChapter> m_cache;
    QList<int> m_prefetchQueue;   ///< 待预取的章号（+1 优先，-1 次之）
    quint64 m_prefetchSerial = 0; ///< 切章 / 关闭即作废在途预取
    quint64 m_loadSerial = 0;     ///< 丢弃被后续切章顶掉的旧加载结果

    /// epub 章节数 / 标题（QML 只用标题，href 留在 EpubBook 里）
    int m_epubChapterCount = 0;
    QStringList m_epubTitles;

    int m_chapterIndex = -1;
    /// 章名段（只认第 0 段，且要长得像章名）：-1 = 没有
    int m_titleParagraph = -1;
    int m_anchorParagraph = -1;
    /// 锚点的段内字符偏移：长段落跨页时用它落回原行（页码从不持久化，靠它重算）
    int m_anchorOffset = 0;
    double m_percent = 0.0;
    qint64 m_pendingByte = -1;   ///< 节流：等待落库的最新滚动位置
    int m_pendingChapter = -1;   ///< epub 节流：等待落库的章号
    int m_pendingParagraph = -1; ///< epub 节流：等待落库的段落下标
    int m_pendingOffset = 0;     ///< 节流：等待落库的段内偏移
    qint64 m_lastReportedByte = -1;
    qint64 m_pendingModTime = 0;
    qint64 m_fileSize = 0; ///< 打开时 stat 到的文件长度（章节缓存的指纹）
    qint64 m_modTime = 0;  ///< 打开时 stat 到的修改时间（章节缓存的指纹）
    QElapsedTimer m_reportClock;

    bool m_opened = false;
    bool m_loading = false;
    bool m_offline = false; ///< 文件不可用：只在已缓存章节之间阅读

    /// 已翻到全书最后（QML 判定后上报）；读完后再上报的滚动位置一律忽略，
    /// 否则一次 1s 节流落库就会把 `finished` 洗回 false
    bool m_bookEnd = false;
    /// 本书已经记过 finished：预取邻章、往回翻都会继续写位置，必须在写入层保住这个事实
    bool m_finishedBook = false;
    /// 读完推荐候选；空 map = 无候选
    QVariantMap m_nextSuggestion;
    /// 用户已收起本次读到底的推荐：回滚到非末尾再复位
    bool m_nextDismissed = false;
    /// 目录列举是异步的：回来时若已换书 / 已撤销，靠这个序号丢弃结果
    int m_nextQueryId = 0;

    int m_fontSize = 17;
    double m_lineSpacing = 1.6;
    /// 正文字体族（含回退链）：QML 画正文与 C++ 折行都只认这一份
    QStringList m_fontFamilies;
    int m_fontStyle = 0; ///< 0=黑体 1=宋体
    int m_theme = 0;
    double m_brightness = -1.0; ///< 负值 = 跟随系统亮度

    /// 行级分页（§5.1）。页码只活在内存里：换字号/换窗口宽度就整章重排
    NovelPager m_pager;
    bool m_pageMode = false;
    int m_pageIndex = 0;
    int m_paginationRevision = 0;
    /// QML 推上来的正文可视区（setFontSize 之类改排版时用它重排）
    int m_pageWidth = 0;
    int m_pageHeight = 0;
    /// 往回翻跨章：章节是异步加载的，页码得等新章落地后再挪到末尾
    bool m_pendingPageEnd = false;
};

} // namespace myhub
