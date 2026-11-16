#pragma once

#include "core/novel/NovelChapterCache.h"
#include "core/novel/NovelIndex.h"
#include "core/novel/TxtChapterLoader.h"

#include <QElapsedTimer>
#include <QHash>
#include <QList>
#include <QObject>
#include <QQmlEngine>
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
 * 目录直接就是章节列表，没有「建索引」这一步，也不需要缓存。
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
     * 读完本书后推荐的「同目录下一本」（§4.6 的阅读侧对应）。
     *
     * 空 map = 没有候选（末本 / 目录里没有书 / 目录读不到）。
     * **只给候选，绝不自动翻**：是否切换由用户点击决定，也不做倒计时。
     */
    Q_PROPERTY(QVariantMap nextSuggestion READ nextSuggestion NOTIFY nextSuggestionChanged)

    // ---- 排版偏好（落 AppSettings，键名与 iOS 对齐）----
    Q_PROPERTY(int fontSize READ fontSize WRITE setFontSize NOTIFY fontSizeChanged)
    Q_PROPERTY(double lineSpacing READ lineSpacing WRITE setLineSpacing NOTIFY lineSpacingChanged)
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
    QString statusText() const { return m_statusText; }
    QString errorText() const { return m_errorText; }
    bool offline() const { return m_offline; }
    QVariantMap nextSuggestion() const { return m_nextSuggestion; }

    int fontSize() const { return m_fontSize; }
    void setFontSize(int px);
    double lineSpacing() const { return m_lineSpacing; }
    void setLineSpacing(double spacing);
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
    /// 下一本候选变化；空 map 表示没有可推荐的下一本
    void nextSuggestionChanged();
    void fontSizeChanged();
    void lineSpacingChanged();
    void themeChanged();
    void brightnessChanged();

private:
    explicit NovelBridge(QObject *parent = nullptr);
    ~NovelBridge() override;

    /// 当前这本是不是 epub（只有打开成功的 epub 才会让 m_epub 非空）
    bool epubMode() const { return m_epub != nullptr; }

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
    /// txt：按索引区间取一章
    void loadChapter(int chapter, qint64 anchorByte);
    void applyChapter(const TxtChapterText &text, qint64 anchorByte);
    void saveProgress(qint64 byteOffset, bool finished = false);

    // ---- epub 分支（与 txt 的字节锚点并存，互不干扰）----
    void openEpub();
    void loadEpubChapter(int chapter, int anchorParagraph);
    void applyEpubChapter(int chapter, const QStringList &paragraphs, int anchorParagraph);
    void saveEpubProgress(int chapter, int paragraph, bool finished = false);
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
    int m_anchorParagraph = -1;
    double m_percent = 0.0;
    qint64 m_pendingByte = -1;   ///< 节流：等待落库的最新滚动位置
    int m_pendingChapter = -1;   ///< epub 节流：等待落库的章号
    int m_pendingParagraph = -1; ///< epub 节流：等待落库的段落下标
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
    int m_theme = 0;
    double m_brightness = -1.0; ///< 负值 = 跟随系统亮度
};

} // namespace myhub
