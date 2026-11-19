#pragma once

#include "core/comic/ComicDirection.h"

#include <QList>
#include <QObject>
#include <QQmlEngine>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QVariant>
#include <QVariantMap>

#include <memory>

namespace myhub {

class ComicBook;
class EpubBook;
class RangeSource;
class StorageAdapter;
class StorageError;
struct FileEntry;

/**
 * 漫画阅读器的 QML 桥接（QML 侧单例名 `Comic`，§6 PC-207）。
 *
 * 与 NovelBridge 同构的「门面」：解包在 myhub_core（`ComicBook`，可单测），
 * QML 只管画一张图 + 前后翻页。
 *
 * 四条纪律：
 *   - **zip / cbz 走 Range，不整包下载**；**rar / cbr 必须整包在手**（没有尾部署引），
 *     本地文件直读，远程先落地成缓存包再打开，落地过程报 `downloadProgress`。
 *   - **页序来自压缩包条目 + 自然排序**，不在 QML 里按 index 猜；
 *     页码也只是「打开那一刻的顺序」，进度里同时记 `pageName` 便于对账。
 *   - **解出来的页落磁盘缓存**（按 连接源+路径+文件指纹+页码 做键），
 *     重开同一本、来回翻页都不再走网络；文件变了旧页自然失效。
 *   - **一屏之外提前解**：当前页两侧各 3 页排队、最多 3 页并行，翻页方向那一侧先解；
 *     用户正在看的那页永远插队（`loadPage` 直接解，预取给它让位）。
 */
class ComicBridge : public QObject
{
    Q_OBJECT
    QML_NAMED_ELEMENT(Comic)
    QML_SINGLETON

    Q_PROPERTY(bool opened READ opened NOTIFY openedChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    Q_PROPERTY(QString title READ title NOTIFY bookChanged)
    /// 0 基页码；-1 表示还没定位到任何一页
    Q_PROPERTY(int pageIndex READ pageIndex NOTIFY pageChanged)
    Q_PROPERTY(int pageCount READ pageCount NOTIFY bookChanged)
    Q_PROPERTY(QString pageName READ pageName NOTIFY pageChanged)
    /// 当前页的本地缓存文件（`file://`），空串表示这一页还没准备好
    Q_PROPERTY(QString pageUrl READ pageUrl NOTIFY pageChanged)
    Q_PROPERTY(bool pageLoading READ pageLoading NOTIFY pageLoadingChanged)
    Q_PROPERTY(double percent READ percent NOTIFY percentChanged)
    /// 远程 rar 整包落地进度 0..1；-1 = 不需要（zip 走 Range，不整包下载）
    Q_PROPERTY(double downloadProgress READ downloadProgress NOTIFY downloadProgressChanged)
    Q_PROPERTY(QString statusText READ statusText NOTIFY statusChanged)
    Q_PROPERTY(QString errorText READ errorText NOTIFY errorTextChanged)
    /**
     * 降级阅读中：源够不着，页只来自磁盘缓存。
     *
     * 离线时页数仍取自页名清单（`ComicPageStore`），所以能翻、能看缓存过的页；
     * 没缓存的页给一句「离线 · 第 N 页未缓存」，而不是一直转圈。
     */
    Q_PROPERTY(bool offline READ offline NOTIFY offlineChanged)

    /// 阅读模式：0 单页 / 1 双页 / 2 条漫（§6）。持久化，下次打开沿用
    Q_PROPERTY(int mode READ mode WRITE setMode NOTIFY modeChanged)
    /**
     * 双页方向**偏好**：-1 自动 / 0 从左到右 / 1 从右到左。持久化。
     *
     * 「自动」= 打开时按书名与页名猜（`detectComicDirection`），猜不出就沿用上一次的取值；
     * 用户在阅读器或设置页点一下就会变成手动值并落库 —— 猜错一次之后不会再被猜错。
     */
    Q_PROPERTY(int direction READ direction WRITE setDirection NOTIFY directionChanged)
    /// 自动判定出来的方向（0 / 1，看不出来时按右到左）：只给界面显示「自动（右→左）」
    Q_PROPERTY(int autoDirection READ autoDirection NOTIFY directionChanged)
    /// 当前**生效**的方向：true = 从右向左。只在双页模式下有意义
    Q_PROPERTY(bool rightToLeft READ rightToLeft WRITE setRightToLeft NOTIFY rightToLeftChanged)
    /// 亮度蒙层（与小说阅读器共用 `reader.brightness`；负值 = 跟随系统）
    Q_PROPERTY(double brightness READ brightness WRITE setBrightness NOTIFY brightnessChanged)

    /**
     * 翻完这卷后推荐的「同目录下一卷」（§4.6 的漫画侧）。
     *
     * 空 map = 没有候选（最后一卷 / 目录里没有别的漫画包 / 目录读不到）。
     * **只给候选，绝不自动翻**：是否切换由用户点击决定，也不做倒计时。
     */
    Q_PROPERTY(QVariantMap nextSuggestion READ nextSuggestion NOTIFY nextSuggestionChanged)

public:
    static ComicBridge *instance();
    static ComicBridge *create(QQmlEngine *, QJSEngine *);

    explicit ComicBridge(QObject *parent = nullptr);
    ~ComicBridge() override;

    bool opened() const { return m_opened; }
    bool loading() const { return m_loading; }
    QString title() const { return m_title; }
    int pageIndex() const { return m_pageIndex; }
    int pageCount() const { return m_pages.size(); }
    QString pageName() const { return m_pages.value(m_pageIndex); }
    QString pageUrl() const { return m_pageUrl; }
    bool pageLoading() const { return m_pageLoading; }
    double percent() const;
    double downloadProgress() const { return m_downloadProgress; }
    QString statusText() const { return m_statusText; }
    QString errorText() const { return m_errorText; }
    bool offline() const { return m_offline; }

    int mode() const { return m_mode; }
    void setMode(int mode);
    int direction() const { return m_direction; }
    void setDirection(int direction);
    int autoDirection() const;
    bool rightToLeft() const { return m_rightToLeft; }
    /// 兼容旧入口：等价于 `setDirection(从右向左 ? 1 : 0)`（写成手动值）
    void setRightToLeft(bool rightToLeft);
    double brightness() const { return m_brightness; }
    void setBrightness(double value);

    QVariantMap nextSuggestion() const { return m_nextSuggestion; }

    /// 打开一本 cbz / zip / cbr / rar（`title` 空则用文件名）
    Q_INVOKABLE void open(QString connectionId, QString path, const QString &title);
    Q_INVOKABLE void goToPage(int index);
    Q_INVOKABLE void nextPage();
    Q_INVOKABLE void prevPage();
    /// 当前页失败后再试一次（网络抖一下时用户只需要点一下）
    Q_INVOKABLE void retryPage();
    Q_INVOKABLE void close();

    /// 第 index 页的本地缓存 URL（还没解出来就是空串）：**只查盘，不触发解压**
    /// 双页要同时显示两页、条漫要一屏多页，QML 靠它取「已就绪」的那些页
    Q_INVOKABLE QString pageUrlAt(int index) const;
    /// 让第 index 页进缓存；已在缓存里则立刻 `pageCached`
    Q_INVOKABLE void ensurePage(int index);
    /// 条漫滚动时只更新「读到第几页」，不去解压（翻屏的解压由 `ensurePage` 管）
    Q_INVOKABLE void trackPage(int index);
    /// 丢掉排队中的自动解压（切模式 / 关闭时用，免得旧模式的排队拖住新的一屏）
    Q_INVOKABLE void clearPageQueue();

    /**
     * 用户是否已经翻到这一卷的最后一屏（QML 判定后上报）。
     *
     * 只有阅读视图知道「当前这屏算不算看完」：双页模式最后一屏的 `pageIndex`
     * 停在倒数第二页（整屏两页），条漫则要看是否滚到底 —— C++ 按页码猜必然误判。
     * 这里只负责状态迁移：
     *   · 进入末尾 → 落一次 `finished` 进度（首页据此显示「已读完」）+ 查下一卷；
     *   · 离开末尾（往回翻）→ 撤销提示条，下次翻到底还能再推。
     */
    Q_INVOKABLE void setAtBookEnd(bool atEnd);
    /// 打开推荐的那一卷（保留它自己的续读点 —— 只是换书，不是重读）
    Q_INVOKABLE void openNextSuggestion();
    /// 用户收起提示条：本次「翻到底」不再重复查询
    Q_INVOKABLE void dismissNextSuggestion();

signals:
    void openedChanged();
    void loadingChanged();
    void bookChanged();
    void pageChanged();
    void pageLoadingChanged();
    void percentChanged();
    void downloadProgressChanged();
    void statusChanged();
    void errorTextChanged();
    void offlineChanged();
    void modeChanged();
    void directionChanged();
    void rightToLeftChanged();
    void brightnessChanged();
    /// 下一卷候选变化；空 map 表示没有可推荐的下一卷
    void nextSuggestionChanged();
    /// 第 index 页已经可读（落进缓存），QML 可以把它画出来了
    void pageCached(int index);

private:
    /// 预取半径：当前页前后各 3 页（正常往后读时后 3 页先排）
    static constexpr int kPrefetchRadius = 3;
    /// 同时在途的解页数：远程 zip 三次 Range 并行，比串行等三轮快得多
    static constexpr int kMaxInflight = 3;

    void teardown();
    void fail(const QString &message);
    /// 读方向偏好：新三态键优先，没有就把老的布尔键当成手动值迁移过来
    int readDirectionPreference() const;
    /// 按「偏好在先、自动判定在后」算出生效方向；变了才发信号
    void resolveDirection();
    /// 书名判不出方向时用页名补一刀（只认首尾各几页；已经有结论就不动）
    void refineDirection(const QStringList &pageNames);
    /// 建好 `m_book` 之后统一的打开流程（两条解包路径共用）
    void openBookCommon();
    /// 用页名清单先把阅读器打开（秒开 / 离线共用）：定位续读页，命中缓存就直接上屏
    void showPageList(const QStringList &pages, bool offline);
    /// 续读页：优先认 `pageName`（页序可能被重新打包打乱），拿不到才退回页码
    int resumePage() const;
    /// 归档补齐时核对清单：页序变了就按页名重定位，一致的什么都不动
    void reconcilePages(const QStringList &pages);
    /// 源够不着时降级阅读（页只来自磁盘缓存）；没有清单可用则返回 false
    bool openOffline(const StorageError &cause);
    /// 源码还在路上 / 离线：这一页只有缓存能用时的提示
    void showUnavailablePage(int index);
    /// 把当前清单写回 `ComicPageStore`（指纹必须已经拿到）
    void storePageList() const;
    /// 图集 epub：先读 OPF 拿 spine 页序（顺便挡掉文字书），再按漫画包打开
    void probeEpubCollection();
    /// rar：整包在手（本地文件或已落地的缓存包）
    void openLocalPack(const QString &packPath);
    /// rar：远程整包分块落地，边下边报进度
    void startPackDownload();
    /// 退出 / 异常退出后残留的半包（`.part`）在下次打开与退出时清掉
    void cleanPackTemps() const;
    void purgeStalePacks() const;
    QString packCachePath() const;
    void setDownloadProgress(double value);
    /// 定位到某页：命中磁盘缓存就直接用，否则按需解这一页
    void loadPage(int index);
    void applyPage(int index, const QByteArray &bytes);
    /// 页字节已在盘上：切当前页 / 通知 QML / 续上预取（`applyPage` 的后半段）
    void publishPage(int index);
    /// 当前页两侧各 `kPrefetchRadius` 页进队列，`direction` 那一侧优先
    void prefetchAround(int index, int direction);
    /// 进预取队列（越界 / 已缓存 / 已在途 / 已排队的一律忽略）
    void enqueuePrefetch(int index);
    /// 泵队列：在途页数没到 `kMaxInflight` 就继续放行
    void pumpPageQueue();
    void writePageCache(int index, const QByteArray &bytes) const;
    void loadPreferences();
    void storePreference(const QString &key, const QVariant &value);
    void commitProgress();
    void setStatus(const QString &text);
    void setPageLoading(bool loading);

    // ---- 翻到底推荐（§4.6）----
    /// 把这一卷标记为已读完：进度按 `finished` 落库（双页最后一屏也要算）
    void markFinished();
    /// 查同目录下一卷：排序跟随该目录偏好，与浏览页所见顺序一致
    void resolveNextSuggestion();
    void setNextSuggestion(const FileEntry &entry);
    void clearNextSuggestion();

    QString fingerprint() const;
    QString pageCacheDir() const;
    QString pageCachePath(int index) const;
    /// 整包（远程 cbr 整本落盘）目录：`comicPages/packs`
    QString packCacheDir() const;
    /// 文件换了（大小/修改时间变了）就把这本的旧页清掉，免得越攒越多
    void purgeStalePages();
    /// 读过的页刷新 mtime（LRU 依据）；同一页本轮只刷一次，条漫滚动不会写盘风暴
    void markPageAccessed(int index);

    QString m_connectionId;
    QString m_path;
    QString m_title;
    QStringList m_pages;

    int m_pageIndex = -1;
    QString m_pageUrl;
    double m_downloadProgress = -1.0;
    bool m_opened = false;
    bool m_loading = false;
    bool m_pageLoading = false;
    /// 降级阅读：页只来自磁盘缓存（源够不着）
    bool m_offline = false;
    /// 清单已经先把阅读器开起来了，归档还在后台打开：
    /// 这一页解不出来时不能报错，要等它回来（见 `openBookCommon`）
    bool m_archivePending = false;
    /// 清单秒开期间用户翻到的页：归档一就绪就把它解出来
    int m_waitingPage = -1;
    QString m_statusText;
    QString m_errorText;

    qint64 m_fileSize = -1;
    qint64 m_modTime = -1;

    int m_mode = 0;
    /// 方向偏好：-1 自动 / 0 左到右 / 1 右到左（落库的只有这一份）
    int m_direction = -1;
    /// 本书自动判定出来的方向（`m_direction == -1` 时生效）
    ComicDirection m_detected = ComicDirection::Unknown;
    /// 当前生效方向（QML 只读它，不关心是猜的还是用户定的）
    bool m_rightToLeft = true;
    double m_brightness = -1.0;

    /// 本轮已刷新过 mtime 的页：避免条漫每屏都 open/close 一次缓存文件
    QSet<int> m_touchedPages;
    /// 待解页队列（双页的配对页、条漫的下一屏、两侧预取）：front 最急
    QList<int> m_pendingPages;
    /// 正在解的页（预取那一路），与 `m_primaryInflight` 一起构成并发上限
    QSet<int> m_inflightPages;
    /// 用户正在看的那一页在途数量（翻了页它的结果就作废，但仍占着一次解压）
    int m_primaryInflight = 0;
    /// 最近一次翻页方向：+1 往后、-1 往前 —— 预取先排「正要看的那一侧」
    int m_pageDirection = 1;

    StorageAdapter *m_adapter = nullptr;
    /// 远程 rar 落地的整包路径（写一半的 `.part` 由 `ArchiveFetcher` 自己收尾）
    QString m_packPath;
    /// 关掉 / 换书时作废在途的分块下载
    quint64 m_packSerial = 0;
    std::unique_ptr<RangeSource> m_sourceOwner;
    RangeSource *m_source = nullptr;
    std::unique_ptr<ComicBook> m_book;
    /// 图集 epub 的探测句柄（读 OPF 拿 spine 页序；打开完成即释放）
    std::unique_ptr<EpubBook> m_epubProbe;
    /// 图集 epub 的页序（spine 顺序）：归档补齐后核对页序也以它为准
    QStringList m_pageOrderHint;
    /// 关掉 / 换书时作废在途的 OPF 探测
    quint64 m_epubSerial = 0;
    /// 快速翻页时旧页的解压结果不许覆盖新页
    int m_pageSerial = 0;

    /// 本次阅读是否已翻到底（会话内有效；决定百分比与提示条，不落库）
    bool m_bookEnd = false;
    /// 这一卷是否已被标记读完（进度落库用；防止后续 `commitProgress` 把它改回未读完）
    bool m_finishedBook = false;
    QVariantMap m_nextSuggestion;
    /// 用户收起过提示条：本次「翻到底」不再打扰
    bool m_nextDismissed = false;
    /// 换书/离开末尾时作废在途的目录查询
    int m_nextQueryId = 0;
};

} // namespace myhub
