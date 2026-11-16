#pragma once

#include <QList>
#include <QObject>
#include <QQmlEngine>
#include <QString>
#include <QStringList>
#include <QVariant>

#include <memory>

namespace myhub {

class ComicBook;
class RangeSource;
class StorageAdapter;

/**
 * 漫画阅读器的 QML 桥接（QML 侧单例名 `Comic`，§6 PC-207）。
 *
 * 与 NovelBridge 同构的「门面」：解包在 myhub_core（`ComicBook`，可单测），
 * QML 只管画一张图 + 前后翻页。
 *
 * 三条纪律：
 *   - **zip / cbz 走 Range，不整包下载**；**rar / cbr 必须整包在手**（没有尾部署引），
 *     本地文件直读，远程先落地成缓存包再打开，落地过程报 `downloadProgress`。
 *   - **页序来自压缩包条目 + 自然排序**，不在 QML 里按 index 猜；
 *     页码也只是「打开那一刻的顺序」，进度里同时记 `pageName` 便于对账。
 *   - **解出来的页落磁盘缓存**（按 连接源+路径+文件指纹+页码 做键），
 *     重开同一本、来回翻页都不再走网络；文件变了旧页自然失效。
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

    /// 阅读模式：0 单页 / 1 双页 / 2 条漫（§6）。持久化，下次打开沿用
    Q_PROPERTY(int mode READ mode WRITE setMode NOTIFY modeChanged)
    /// 双页方向：true = 从右向左（日漫默认）。只在双页模式下有意义
    Q_PROPERTY(bool rightToLeft READ rightToLeft WRITE setRightToLeft NOTIFY rightToLeftChanged)
    /// 亮度蒙层（与小说阅读器共用 `reader.brightness`；负值 = 跟随系统）
    Q_PROPERTY(double brightness READ brightness WRITE setBrightness NOTIFY brightnessChanged)

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

    int mode() const { return m_mode; }
    void setMode(int mode);
    bool rightToLeft() const { return m_rightToLeft; }
    void setRightToLeft(bool rightToLeft);
    double brightness() const { return m_brightness; }
    void setBrightness(double value);

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
    void modeChanged();
    void rightToLeftChanged();
    void brightnessChanged();
    /// 第 index 页已经可读（落进缓存），QML 可以把它画出来了
    void pageCached(int index);

private:
    void teardown();
    void fail(const QString &message);
    /// 建好 `m_book` 之后统一的打开流程（两条解包路径共用）
    void openBookCommon();
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
    /// 顺手把下一页也解出来（只为省一次等待，失败静默）
    void prefetch(int index);
    /// 串行泵：`ComicBook` 只有一个在途槽位，多页请求靠这条队列排队
    void pumpPageQueue();
    void writePageCache(int index, const QByteArray &bytes) const;
    void loadPreferences();
    void storePreference(const QString &key, const QVariant &value);
    void commitProgress();
    void setStatus(const QString &text);
    void setPageLoading(bool loading);

    QString fingerprint() const;
    QString pageCacheDir() const;
    QString pageCachePath(int index) const;
    /// 文件换了（大小/修改时间变了）就把这本的旧页清掉，免得越攒越多
    void purgeStalePages();

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
    QString m_statusText;
    QString m_errorText;

    qint64 m_fileSize = -1;
    qint64 m_modTime = -1;

    int m_mode = 0;
    bool m_rightToLeft = true;
    double m_brightness = -1.0;

    /// 待解页队列（双页的右页、条漫的下一屏）：先进先出，一次只跑一页
    QList<int> m_pendingPages;
    bool m_queueBusy = false;

    StorageAdapter *m_adapter = nullptr;
    /// 远程 rar 落地的整包路径（写一半的 `.part` 由 `ArchiveFetcher` 自己收尾）
    QString m_packPath;
    /// 关掉 / 换书时作废在途的分块下载
    quint64 m_packSerial = 0;
    std::unique_ptr<RangeSource> m_sourceOwner;
    RangeSource *m_source = nullptr;
    std::unique_ptr<ComicBook> m_book;
    /// 快速翻页时旧页的解压结果不许覆盖新页
    int m_pageSerial = 0;
};

} // namespace myhub
