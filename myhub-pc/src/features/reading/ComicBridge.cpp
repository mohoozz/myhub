#include "ComicBridge.h"

#include "core/archive/ArchiveFetcher.h"
#include "core/comic/ComicBook.h"
#include "core/comic/ComicDetector.h"
#include "core/comic/ComicPageStore.h"
#include "core/files/DirectorySort.h"
#include "core/history/ProgressRepository.h"
#include "core/novel/EpubBook.h"
#include "core/preferences/AppSettings.h"
#include "core/storage/LocalAdapter.h"
#include "core/storage/StorageAdapter.h"
#include "core/storage/StoragePath.h"
#include "core/cache/CacheCleaner.h"
#include "core/cache/CachePartition.h"
#include "core/cache/CacheStore.h"
#include "core/stream/AdapterRangeSource.h"
#include "core/utils/AppLogger.h"
#include "core/utils/AppPaths.h"
#include "features/connections/ConnectionStore.h"

#include <QBuffer>
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImageReader>
#include <QPointer>
#include <QSaveFile>
#include <QUrl>

#include <utility>

namespace myhub {
namespace {

constexpr int kCacheHashChars = 16;

constexpr auto kModeKey = "reader.comic.mode";
/// 方向偏好：-1 自动 / 0 左到右 / 1 右到左
constexpr auto kDirectionKey = "reader.comic.direction";
/// 老版本的布尔方向键：只在**新键还不存在**时当作手动值迁移过来
constexpr auto kRtlKey = "reader.comic.rtl";
/// 与小说阅读器**同一个键**：亮度是「这块屏幕」的偏好，不是某个阅读器的
constexpr auto kBrightnessKey = "reader.brightness";

constexpr int kModeSingle = 0;
constexpr int kModeDouble = 1;
constexpr int kModeStrip = 2;
constexpr int kModeCount = 3;

/// 方向偏好的「自动」哨兵值：-1 与 0（左到右）必须区分开
constexpr int kDirectionAuto = -1;

QString hashOf(const QString &text, int chars)
{
    return QString::fromLatin1(
               QCryptographicHash::hash(text.toUtf8(), QCryptographicHash::Sha1).toHex())
        .left(chars);
}

/**
 * 图集 epub 也按漫画包打开。
 *
 * 两条入口：`NovelBridge` 判出「spine 全是整页图片」后整本转交；以及浏览页右键
 * 「以漫画阅读器打开」。浏览页里的 epub 仍归小说（`MediaType` 不变、徽标不变、
 * 排序不变），只有这两条路会进来。
 *
 * 页序**取自 OPF 的 spine**（见 `probeEpubCollection`）：条目名排序只是猜，
 * 图集 epub 的页序可能写在 spine 里且与名字顺序不同。
 */
bool isImageCollectionPath(const QString &path)
{
    return path.endsWith(QLatin1String(".epub"), Qt::CaseInsensitive);
}

/// 图片只看头部就能判定格式与尺寸，不值得整页解码一遍
bool isDecodableImage(const QByteArray &bytes)
{
    QBuffer buffer;
    buffer.setData(bytes);
    if (!buffer.open(QIODevice::ReadOnly)) {
        return false;
    }
    const QImageReader reader(&buffer);
    return reader.canRead();
}

} // namespace

ComicBridge *ComicBridge::instance()
{
    static ComicBridge *bridge = nullptr;
    if (!bridge) {
        bridge = new ComicBridge(nullptr);
    }
    return bridge;
}

ComicBridge *ComicBridge::create(QQmlEngine *, QJSEngine *)
{
    // 与 NovelBridge 同理：工厂会被调用多次，必须幂等
    return instance();
}

ComicBridge::ComicBridge(QObject *parent)
    : QObject(parent)
{
    loadPreferences();

    // 亮度与小说共用 `reader.brightness`，模式/方向也有设置页入口：
    // 任一入口改动都要即时反映到另一处（§14.16）。走 setter 以复用「换模式清空页面队列」等副作用。
    connect(&AppSettings::instance(), &AppSettings::settingChanged, this,
            [this](const QString &key) {
                if (key != QLatin1String(kModeKey) && key != QLatin1String(kDirectionKey)
                    && key != QLatin1String(kRtlKey) && key != QLatin1String(kBrightnessKey)) {
                    return;
                }
                AppSettings &settings = AppSettings::instance();
                setMode(settings.value(kModeKey, kModeSingle).toInt());
                // 方向只同步进内存、不回写：回写会把「键被删掉」变成显式值，
                // 于是老布尔键的迁移就永远轮不上了
                const int directionBefore = m_direction;
                m_direction = readDirectionPreference();
                if (m_direction != directionBefore) {
                    emit directionChanged();
                }
                resolveDirection();
                setBrightness(settings.value(kBrightnessKey, -1.0).toDouble());
            });

    // 崩在下载中间会留下 `.part`：正常退出也扫一遍，别让半包越攒越多
    if (QCoreApplication *app = QCoreApplication::instance()) {
        QObject::connect(app, &QCoreApplication::aboutToQuit, this, [this]() { cleanPackTemps(); });
    }
}

ComicBridge::~ComicBridge() = default;

double ComicBridge::percent() const
{
    if (m_pages.isEmpty() || m_pageIndex < 0) {
        return 0.0;
    }
    // 双页最后一屏的 `pageIndex` 停在倒数第二页，靠页码算会永远差一屏；
    // 读到底这件事由视图上报（`setAtBookEnd`），这里只负责把它算成 100%。
    // 离线例外：看得出「第几页」不等于读完了那一页，不能给虚假的 100%
    if (m_bookEnd && !m_offline) {
        return 1.0;
    }
    return static_cast<double>(m_pageIndex + 1) / static_cast<double>(m_pages.size());
}

// ---------------------------------------------------------------- 显示偏好

void ComicBridge::loadPreferences()
{
    AppSettings &settings = AppSettings::instance();
    m_mode = qBound(kModeSingle, settings.value(kModeKey, kModeSingle).toInt(), kModeCount - 1);

    m_direction = readDirectionPreference();
    m_brightness = settings.value(kBrightnessKey, -1.0).toDouble();
    // 偏好就绪后先算出一次生效值（此时还没有书，自动那一路保持当前默认）
    resolveDirection();
}

void ComicBridge::storePreference(const QString &key, const QVariant &value)
{
    AppSettings::instance().setValue(key, value);
}

void ComicBridge::setMode(int mode)
{
    const int clamped = qBound(kModeSingle, mode, kModeCount - 1);
    if (clamped == m_mode) {
        return;
    }
    m_mode = clamped;
    storePreference(kModeKey, m_mode);
    // 换模式 = 换一屏要看的东西：旧模式排队中的页已经没有意义
    clearPageQueue();
    emit modeChanged();
}

int ComicBridge::readDirectionPreference() const
{
    AppSettings &settings = AppSettings::instance();
    if (settings.value(kDirectionKey).isValid()) {
        return qBound(kDirectionAuto, settings.value(kDirectionKey).toInt(), 1);
    }
    // 老版本只有一个布尔键：读到时当成手动值迁移过来 ——
    // 老用户已经选过的方向不该被「自动」重新猜一遍
    if (settings.value(kRtlKey).isValid()) {
        return settings.value(kRtlKey).toBool() ? 1 : 0;
    }
    return kDirectionAuto;
}

void ComicBridge::setDirection(int direction)
{
    const int clamped = qBound(kDirectionAuto, direction, 1);
    if (clamped == m_direction) {
        return;
    }
    m_direction = clamped;
    storePreference(kDirectionKey, m_direction);
    emit directionChanged();
    resolveDirection();
}

int ComicBridge::autoDirection() const
{
    if (m_detected == ComicDirection::Unknown) {
        // 猜不出来：显示的就是当前生效值，免得界面上「自动」和实际方向对不上
        return m_rightToLeft ? 1 : 0;
    }
    return m_detected == ComicDirection::RightToLeft ? 1 : 0;
}

void ComicBridge::resolveDirection()
{
    bool effective = m_rightToLeft;
    if (m_direction >= 0) {
        effective = m_direction == 1;
    } else if (m_detected != ComicDirection::Unknown) {
        effective = m_detected == ComicDirection::RightToLeft;
    }
    if (effective == m_rightToLeft) {
        return;
    }
    m_rightToLeft = effective;
    emit rightToLeftChanged();
}

void ComicBridge::setRightToLeft(bool rightToLeft)
{
    // 用户点了方向 = 手动定下来（写成 0 / 1），以后打开这本书不再被自动判定改写
    setDirection(rightToLeft ? 1 : 0);
}

void ComicBridge::refineDirection(const QStringList &pageNames)
{
    // 已经有结论（用户定过 / 书名判出来了）就不再改：翻到一半跳方向比猜不出更糟
    if (m_direction >= 0 || m_detected != ComicDirection::Unknown || pageNames.isEmpty()) {
        return;
    }
    const ComicDirection detected = detectComicDirection(QString(), pageNames);
    if (detected == ComicDirection::Unknown) {
        return;
    }
    m_detected = detected;
    emit directionChanged();
    resolveDirection();
}

void ComicBridge::setBrightness(double value)
{
    if (qFuzzyCompare(value, m_brightness)) {
        return;
    }
    m_brightness = value;
    storePreference(kBrightnessKey, m_brightness);
    emit brightnessChanged();
}

// ---------------------------------------------------------------- 打开

void ComicBridge::open(QString connectionId, QString path, const QString &title)
{
    if (connectionId.isEmpty() || path.isEmpty()) {
        fail(QStringLiteral("缺少连接源或文件路径"));
        return;
    }

    // 从一本换另一本：先把位置落库，再拆现场
    commitProgress();
    teardown();

    m_connectionId = connectionId;
    m_path = path;
    m_title = title.isEmpty() ? QFileInfo(path).fileName() : title;
    if (m_title.isEmpty()) {
        m_title = path;
    }
    m_loading = true;
    // 方向自动判定：只凭书名（文件名多半带着「第N巻」「(C99)」「webtoon」这类线索），
    // 页名要等归档打开才齐，那时候第一页已经上屏，再翻方向更突兀
    m_detected = detectComicDirection(m_title);
    resolveDirection();
    m_errorText.clear();
    emit errorTextChanged();
    emit loadingChanged();
    emit bookChanged();
    setStatus(QStringLiteral("准备打开…"));

    StorageError error;
    StorageAdapter *adapter = ConnectionStore::instance().adapterFor(m_connectionId, &error);
    if (!adapter) {
        fail(error.isNull() ? QStringLiteral("连接源不可用") : error.message());
        return;
    }
    m_adapter = adapter;

    // 扩展名先挡一道：把 txt / mp4 误交给漫画阅读器时，直说支持什么，
    // 别等 RangeZipReader 去解析再报「不是压缩包」那种看不懂的话
    if (!ComicBook::isComicArchivePath(m_path) && !isImageCollectionPath(m_path)) {
        fail(QStringLiteral("这不是漫画文件（支持 cbz / zip / cbr / rar / 图集 epub）"));
        return;
    }

    // stat 只为拿指纹（决定旧页缓存是否还有效）与源长度（RangeZipReader 算区间要用）
    adapter->stat(m_path, [this](StatResult result) {
        if (!result.ok()) {
            // 源够不着（离线 / 超时 / 文件被移走）但手上有页名清单 + 页缓存：
            // 进降级阅读，读过的页一张也不会少，没缓存的页给一句明确的话
            if (openOffline(result.error)) {
                return;
            }
            fail(result.error.message().isEmpty() ? QStringLiteral("读取文件信息失败")
                                                  : result.error.message());
            return;
        }
        if (result.value.isDir) {
            fail(QStringLiteral("这是目录，不是漫画文件"));
            return;
        }
        if (result.value.size <= 0) {
            fail(QStringLiteral("文件是空的"));
            return;
        }

        m_fileSize = result.value.size;
        m_modTime = result.value.modTime.isValid() ? result.value.modTime.toMSecsSinceEpoch() : -1;
        purgeStalePages();

        // 图集 epub：页序在 OPF 的 spine 里（不是压缩包里条目名的排序），
        // 得先把 container + OPF 读出来（几 KB）；顺便挡掉「把文字书交给漫画阅读器」
        if (isImageCollectionPath(m_path)) {
            m_sourceOwner = std::make_unique<AdapterRangeSource>(m_adapter, m_path, m_fileSize);
            m_source = m_sourceOwner.get();
            probeEpubCollection();
            return;
        }

        // 页名清单命中：页数、页序、续读页**立刻**就有，当前页在盘上就直接上屏。
        // 归档照旧在后台打开 —— 没缓存的页要它去解，顺便核对清单（可能被重新打包过）
        ComicPageList cachedPages;
        if (ComicPageStore::load(m_connectionId, m_path, m_fileSize, m_modTime, &cachedPages)) {
            refineDirection(cachedPages.pages);
            showPageList(cachedPages.pages, false);
        }

        // rar / cbr 没有尾部署引，只能整包在手：本地文件直接读，
        // 远程先落地成缓存包（带进度），落地完再交给 `ComicBook`
        if (ComicBook::isRarPath(m_path)) {
            if (auto *local = qobject_cast<LocalAdapter *>(m_adapter)) {
                openLocalPack(local->realPath(m_path));
            } else {
                startPackDownload();
            }
            return;
        }

        m_sourceOwner = std::make_unique<AdapterRangeSource>(m_adapter, m_path, m_fileSize);
        m_source = m_sourceOwner.get();
        m_book = std::make_unique<ComicBook>(m_source);
        openBookCommon();
    });
}

void ComicBridge::probeEpubCollection()
{
    m_epubProbe = std::make_unique<EpubBook>(m_source);
    const quint64 serial = ++m_epubSerial;

    m_epubProbe->load([this, serial](EpubMetadata metadata, StorageError error) {
        if (serial != m_epubSerial) {
            return; // 已经关掉 / 换书：这份 OPF 结果没人要了
        }
        m_epubProbe.reset();

        if (!error.isNull()) {
            fail(error.userMessage().isEmpty() ? QStringLiteral("这个 epub 打不开")
                                               : error.userMessage());
            return;
        }
        // 判定结论回写：列目录时靠它给 epub 挂漫画徽标，
        // 「下一本」靠它把图集 epub 与 cbz/cbr 算成同类（负结论同样有用）
        ComicDetector::remember(m_connectionId, m_path, metadata.imageOnly, m_fileSize,
                                ComicDetector::secondsFromMillis(m_modTime));

        // 手动「以漫画阅读器打开」被用在文字书上：直说该换哪个阅读器，
        // 别让 `ComicBook` 去报「压缩包里没有图片页」——那句话对 epub 不成立
        if (!metadata.imageOnly || metadata.imageEntries.isEmpty()) {
            fail(QStringLiteral("这本 epub 是文字书，不是图集（请用小说阅读器打开）"));
            return;
        }

        m_pageOrderHint = metadata.imageEntries;
        // 页名清单只有**页序一致**才拿来秒开：图集可能上一版是按条目名排序存的，
        // 照搬会把页序错开，等归档回来又跳一下
        ComicPageList cachedPages;
        if (ComicPageStore::load(m_connectionId, m_path, m_fileSize, m_modTime, &cachedPages)
            && cachedPages.pages == m_pageOrderHint) {
            showPageList(cachedPages.pages, false);
        }

        m_book = std::make_unique<ComicBook>(m_source);
        m_book->setPageOrder(m_pageOrderHint);
        openBookCommon();
    });
}

void ComicBridge::openLocalPack(const QString &packPath)
{
    m_book = std::make_unique<ComicBook>(packPath);
    openBookCommon();
}

void ComicBridge::openBookCommon()
{
    if (!m_book) {
        fail(QStringLiteral("文件不可读"));
        return;
    }
    m_archivePending = true;

    m_book->open([this](QStringList pages, StorageError openError) {
        m_archivePending = false;
        // 清单已经把屏开起来了（`showPageList`）：归档这边出岔子不该把
        // 看得好好的页打黑，降级成「只用缓存」，能看的页照看
        const bool early = m_opened;

        if (!openError.isNull() || pages.isEmpty()) {
            if (!early) {
                fail(openError.isNull() ? QStringLiteral("这本漫画一页都没有")
                                        : openError.userMessage());
                return;
            }
            MH_WARN(ComicReader,
                    QStringLiteral("归档补齐失败，改用页缓存继续：%1")
                        .arg(openError.isNull() ? QStringLiteral("一页都没有")
                                                : openError.userMessage()));
            m_offline = true;
            emit offlineChanged();
            setStatus(QStringLiteral("离线 · 仅显示已缓存的页"));
            if (m_pageUrl.isEmpty()) {
                showUnavailablePage(m_pageIndex);
            }
            return;
        }

        if (early) {
            refineDirection(pages);
            reconcilePages(pages);
            return;
        }

        refineDirection(pages);
        m_pages = pages;
        storePageList();

        // 打开成功：下载进度退出（页内部还有各自的「正在解压」提示）
        setDownloadProgress(-1.0);
        m_loading = false;
        m_opened = true;
        emit loadingChanged();
        emit openedChanged();
        emit bookChanged();
        setStatus(QString());
        MH_INFO(ComicReader,
                QStringLiteral("打开漫画：%1（%2 页）").arg(m_title).arg(m_pages.size()));

        loadPage(resumePage());
    });
}

void ComicBridge::showPageList(const QStringList &pages, bool offline)
{
    if (pages.isEmpty()) {
        return;
    }
    m_pages = pages;
    m_loading = false;
    m_opened = true;
    if (m_offline != offline) {
        m_offline = offline;
        emit offlineChanged();
    }
    emit loadingChanged();
    emit openedChanged();
    emit bookChanged();
    setStatus(QString());
    MH_INFO(ComicReader,
            QStringLiteral("%1：%2（%3 页）")
                .arg(offline ? QStringLiteral("离线打开") : QStringLiteral("页名清单命中，先上屏"))
                .arg(m_title)
                .arg(m_pages.size()));
    loadPage(resumePage());
}

int ComicBridge::resumePage() const
{
    if (m_pages.isEmpty()) {
        return 0;
    }
    ProgressRecord record;
    if (!ProgressRepository::instance().find(m_connectionId, m_path, &record) || record.finished) {
        return 0;
    }
    // 页序可能被重新打包打乱：`pageName` 才是「同一张图」的稳定标识，页码只是兜底
    const QString name = record.progress.value(QStringLiteral("pageName")).toString();
    if (!name.isEmpty()) {
        const int byName = m_pages.indexOf(name);
        if (byName >= 0) {
            return byName;
        }
    }
    return qBound(0, record.progress.value(QStringLiteral("page")).toInt(), m_pages.size() - 1);
}

void ComicBridge::reconcilePages(const QStringList &pages)
{
    const QString currentName = m_pages.value(m_pageIndex);
    const bool same = pages == m_pages;
    m_pages = pages;
    // 清单是「打开那一刻」的页序：归档补齐后以它为准，顺手把清单更新掉
    storePageList();

    if (same) {
        MH_DEBUG(ComicReader, QStringLiteral("归档列举与页名清单一致（%1 页）").arg(pages.size()));
        const int waiting = m_waitingPage;
        m_waitingPage = -1;
        if (m_pageUrl.isEmpty()) {
            loadPage(waiting >= 0 ? waiting : m_pageIndex);
        } else {
            prefetchAround(m_pageIndex, m_pageDirection);
        }
        return;
    }

    // 重新打包过：页码会漂，按页名把用户放回同一张图（找不到才退回原页码）
    const int byName = pages.indexOf(currentName);
    const int target = byName >= 0 ? byName : qBound(0, m_pageIndex, pages.size() - 1);
    MH_INFO(ComicReader,
            QStringLiteral("页序与清单不一致，按页名重定位：%1 → %2")
                .arg(currentName.isEmpty() ? QStringLiteral("(无)") : currentName)
                .arg(m_pages.value(target)));
    m_waitingPage = -1;
    emit bookChanged();
    if (target == m_pageIndex && !m_pageUrl.isEmpty()) {
        prefetchAround(target, m_pageDirection);
        return;
    }
    loadPage(target);
}

bool ComicBridge::openOffline(const StorageError &cause)
{
    if (!cause.isAvailabilityFailure()) {
        return false;
    }

    ComicPageList cached;
    if (!ComicPageStore::find(m_connectionId, m_path, &cached)) {
        return false; // 页名都没有：进阅读器只能对着空白屏
    }

    // 指纹从清单行里**恢复**出来：页缓存文件名与整包缓存名都按它算，
    // 恢复出来这些键才继续对得上，离线读的正是当初缓下来的那些页
    m_fileSize = cached.fileSize > 0 ? cached.fileSize : -1;
    m_modTime = cached.modTime;

    // 远程 cbr 早前把整包落过盘：整包在手等于整本可读，这条不算降级
    if (ComicBook::isRarPath(m_path)) {
        const QString pack = packCachePath();
        if (m_fileSize > 0 && QFileInfo(pack).size() == m_fileSize) {
            MH_INFO(ComicReader, QStringLiteral("离线打开（整包缓存命中）：%1").arg(m_title));
            openLocalPack(pack);
            return true;
        }
    }

    m_book.reset();
    m_sourceOwner.reset();
    m_source = nullptr;
    showPageList(cached.pages, true);
    MH_INFO(ComicReader,
            QStringLiteral("离线打开（仅页缓存）：%1，%2（%3 页）")
                .arg(m_title)
                .arg(cause.message().isEmpty() ? cause.userMessage() : cause.message())
                .arg(cached.pages.size()));
    return true;
}

void ComicBridge::showUnavailablePage(int index)
{
    if (m_pages.isEmpty()) {
        return;
    }
    index = qBound(0, index, m_pages.size() - 1);
    if (index != m_pageIndex) {
        m_pageIndex = index;
        m_pageUrl.clear();
        emit pageChanged();
        emit percentChanged();
    }

    if (m_offline) {
        setPageLoading(false);
        // 刻意不写进度：这一页根本没读到，把续读点挪过来等于篡改阅读记录
        setStatus(QStringLiteral("离线 · 第 %1 页未缓存").arg(index + 1));
        return;
    }

    // 清单秒开：归档还在路上，就绪后 `openBookCommon` 会把这一页解出来
    m_waitingPage = index;
    setPageLoading(true);
    setStatus(QStringLiteral("正在读取第 %1 页…").arg(index + 1));
}

void ComicBridge::storePageList() const
{
    if (m_pages.isEmpty() || m_fileSize <= 0 || m_path.isEmpty()) {
        return;
    }
    ComicPageStore::save(m_connectionId, m_path, m_pages, m_fileSize, m_modTime);
}

// ---------------------------------------------------------------- 远程 rar 整包落地

void ComicBridge::startPackDownload()
{
    m_packPath = packCachePath();

    // 同一版本已经整包落过：直接开，不再重下一遍
    if (QFileInfo(m_packPath).size() == m_fileSize) {
        MH_INFO(ComicReader,
                QStringLiteral("整包命中缓存：%1").arg(QFileInfo(m_packPath).fileName()));
        openLocalPack(m_packPath);
        return;
    }

    purgeStalePacks();
    QFile::remove(m_packPath);

    const quint64 serial = ++m_packSerial;
    setDownloadProgress(0.0);
    setStatus(QStringLiteral("正在下载整包 0%"));

    const QString packPath = m_packPath;
    const QString partPath = packPath + QStringLiteral(".part");
    // 下载中的半包必须护住：`CacheStore` 默认把 `.part` 当下载残骸最先删
    CacheCleaner::instance().protect(partPath);
    ArchiveFetcher::fetch(
        m_adapter, m_path, m_fileSize, packPath,
        [this, serial](qint64 done, qint64 total) {
            if (serial != m_packSerial) {
                return;
            }
            setDownloadProgress(static_cast<double>(done) / static_cast<double>(total));
            setStatus(
                QStringLiteral("正在下载整包 %1%")
                    .arg(qRound(100.0 * static_cast<double>(done) / static_cast<double>(total))));
        },
        [this, serial, partPath](QString localPath, StorageError error) {
            // 先解除保护再判 serial：取消过的下载也要放行，否则保护集只增不减
            CacheCleaner::instance().unprotect(partPath);
            if (serial != m_packSerial) {
                return; // 已经关掉 / 换书了：包留着，下次命中缓存
            }
            if (!error.isNull()) {
                fail(error.userMessage());
                return;
            }
            setDownloadProgress(1.0);
            MH_INFO(ComicReader, QStringLiteral("整包落地完成：%1 字节").arg(m_fileSize));
            openLocalPack(localPath);
        });
}

QString ComicBridge::packCacheDir() const
{
    // 整包与解压页同属「漫画」分区（需求文档 §5.5），但要分目录放：
    // 页文件按 `key-` 前缀清扫，混在一个目录里会连整包一起扫掉
    const QString dir = pageCacheDir() + QStringLiteral("/packs");
    AppPaths::ensureDir(dir);
    return dir;
}

QString ComicBridge::packCachePath() const
{
    const QString dir = packCacheDir();
    const QString key = hashOf(m_connectionId + QLatin1Char('\n') + m_path, kCacheHashChars);
    // 文件名里带指纹：文件换了就是另一个包，旧包由 `purgeStalePacks` 清掉
    return QStringLiteral("%1/%2-%3.pack").arg(dir, key, fingerprint());
}

void ComicBridge::purgeStalePacks() const
{
    const QString dir = packCacheDir();
    if (!QFileInfo::exists(dir)) {
        return;
    }
    const QString key = hashOf(m_connectionId + QLatin1Char('\n') + m_path, kCacheHashChars);
    const QString alive = QStringLiteral("%1-%2.").arg(key, fingerprint());

    QDir cache(dir);
    const QStringList entries =
        cache.entryList(QStringList{QStringLiteral("%1-*.pack").arg(key)}, QDir::Files);
    for (const QString &entry : entries) {
        if (entry.startsWith(alive)) {
            continue;
        }
        cache.remove(entry);
    }
}

void ComicBridge::cleanPackTemps() const
{
    const QString dir = pageCacheDir() + QStringLiteral("/packs");
    if (!QFileInfo::exists(dir)) {
        return;
    }
    QDir cache(dir);
    const QStringList parts = cache.entryList(QStringList{QStringLiteral("*.part")}, QDir::Files);
    for (const QString &part : parts) {
        if (!cache.remove(part)) {
            MH_WARN(ComicReader, QStringLiteral("半包清理失败：%1").arg(part));
        }
    }
}

// ---------------------------------------------------------------- 翻页

void ComicBridge::goToPage(int index)
{
    if (!m_opened || m_pages.isEmpty()) {
        return;
    }
    const int clamped = qBound(0, index, m_pages.size() - 1);
    if (clamped == m_pageIndex && !m_pageUrl.isEmpty()) {
        return;
    }
    loadPage(clamped);
}

void ComicBridge::nextPage()
{
    goToPage(m_pageIndex + 1);
}

void ComicBridge::prevPage()
{
    goToPage(m_pageIndex - 1);
}

void ComicBridge::retryPage()
{
    if (!m_opened || m_pageIndex < 0) {
        return;
    }
    // 离线 / 归档还在路上：没有能重解的东西，重看一遍当前页即可
    if (!m_book || m_offline) {
        loadPage(m_pageIndex);
        return;
    }
    // 缓存文件可能恰好是坏的那一份（上一轮写了一半），删掉重解
    const QString cached = pageCachePath(m_pageIndex);
    if (QFileInfo::exists(cached)) {
        QFile::remove(cached);
    }
    m_errorText.clear();
    emit errorTextChanged();
    loadPage(m_pageIndex);
}

void ComicBridge::close()
{
    commitProgress();
    teardown();
    m_loading = false;
    m_opened = false;
    m_errorText.clear();
    m_title.clear();
    m_statusText.clear();
    m_fileSize = -1;
    m_modTime = -1;
    m_connectionId.clear();
    m_path.clear();
    emit loadingChanged();
    emit openedChanged();
    emit bookChanged();
    emit pageChanged();
    emit pageLoadingChanged();
    emit percentChanged();
    emit statusChanged();
    emit errorTextChanged();
}

void ComicBridge::loadPage(int index)
{
    if (m_pages.isEmpty()) {
        return;
    }
    index = qBound(0, index, m_pages.size() - 1);
    // 方向决定预取先排哪一侧：往后翻先把后三页排上，往回翻先把前三页排上
    m_pageDirection = index >= m_pageIndex ? 1 : -1;
    const int serial = ++m_pageSerial;

    // 页码先动、图后到：进度条与页码不必等解压
    m_pageIndex = index;
    m_pageUrl.clear();
    m_errorText.clear();
    m_waitingPage = -1;
    emit pageChanged();
    emit percentChanged();
    emit errorTextChanged();

    // 用户换了页：上一屏的排队已经没意义，清掉重排。
    // 在途的解压不取消（取消也没用，字节都读下去了），回来照样进缓存
    m_pendingPages.clear();

    const QString cached = pageCachePath(index);
    if (QFileInfo(cached).size() > 0) {
        MH_DEBUG(ComicReader, QStringLiteral("第 %1 页命中缓存").arg(index + 1));
        markPageAccessed(index);
        m_pageUrl = QUrl::fromLocalFile(cached).toString();
        setPageLoading(false);
        setStatus(QString());
        emit pageChanged();
        commitProgress();
        prefetchAround(index, m_pageDirection);
        return;
    }

    // 页不在盘上：要么归档还没就绪（清单秒开），要么源够不着（离线）
    if (!m_book || m_offline) {
        showUnavailablePage(index);
        return;
    }

    setPageLoading(true);
    setStatus(QStringLiteral("正在解压第 %1 页…").arg(index + 1));

    // 预取刚好在解这一页（用户翻得比预取快半步）：别再解一遍，
    // 等它的回调回来直接当主路径收尾（见 `pumpPageQueue`）
    if (m_inflightPages.contains(index)) {
        MH_DEBUG(ComicReader, QStringLiteral("第 %1 页已在预取中，等它回来").arg(index + 1));
        return;
    }

    MH_INFO(ComicReader, QStringLiteral("解压第 %1 页…").arg(index + 1));

    ++m_primaryInflight;
    m_book->readPage(index, [this, index, serial](QByteArray bytes, StorageError error) {
        if (m_primaryInflight > 0) {
            --m_primaryInflight;
        }
        if (serial != m_pageSerial) {
            // 用户已经翻到别页了：结果丢弃，但要把并发名额让出来
            pumpPageQueue();
            return;
        }
        if (!error.isNull()) {
            MH_WARN(
                ComicReader,
                QStringLiteral("解页失败（第 %1 页）：%2").arg(index + 1).arg(error.userMessage()));
            setPageLoading(false);
            setStatus(QString());
            // 页面级失败不关阅读器：前一页还在，用户点「重试」即可
            fail(error.userMessage());
            pumpPageQueue();
            return;
        }
        MH_INFO(ComicReader,
                QStringLiteral("第 %1 页解压完成（%2 字节）").arg(index + 1).arg(bytes.size()));
        applyPage(index, bytes);
    });
}

void ComicBridge::applyPage(int index, const QByteArray &bytes)
{
    if (!isDecodableImage(bytes)) {
        setPageLoading(false);
        setStatus(QString());
        fail(QStringLiteral("第 %1 页不是能显示的图片").arg(index + 1));
        return;
    }

    writePageCache(index, bytes);
    publishPage(index);
}

void ComicBridge::publishPage(int index)
{
    m_pageUrl = QUrl::fromLocalFile(pageCachePath(index)).toString();
    m_pageIndex = index;
    setPageLoading(false);
    setStatus(QString());
    emit pageChanged();
    commitProgress();
    prefetchAround(index, m_pageDirection);
}

void ComicBridge::writePageCache(int index, const QByteArray &bytes) const
{
    const QString path = pageCachePath(index);
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly)) {
        MH_WARN(ComicReader, QStringLiteral("漫画页缓存打不开：%1").arg(path));
        return;
    }
    file.write(bytes);
    if (!file.commit()) {
        MH_WARN(ComicReader, QStringLiteral("漫画页写入缓存失败：%1").arg(path));
        return;
    }
    // 页缓存是「只增不减」的大户：写入后请求一次容量约束（`CacheCleaner` 内部节流 60 秒）
    CacheCleaner::instance().requestCleanup();
}

void ComicBridge::markPageAccessed(int index)
{
    if (index < 0 || m_touchedPages.contains(index)) {
        return;
    }
    m_touchedPages.insert(index);
    // 命中即刷新 mtime：淘汰按 mtime 走，不刷新的话常看的书会被当成旧书清掉
    CacheStore::touch(pageCachePath(index));
}

void ComicBridge::prefetchAround(int index, int direction)
{
    if (!m_book || m_offline || m_pages.isEmpty()) {
        return;
    }
    // 「内容缓存本地化」关闭：不预取相邻页。当前页仍按需写盘（阅读必须有本地文件），
    // 只是不再替用户多缓存几页
    if (!AppSettings::instance().contentCachingEnabled()) {
        return;
    }
    const int step = direction >= 0 ? 1 : -1;
    // 先排「正要看的那一侧」（往后读就是后三页），再排反方向；越近越先
    for (int i = 1; i <= kPrefetchRadius; ++i) {
        enqueuePrefetch(index + i * step);
    }
    for (int i = 1; i <= kPrefetchRadius; ++i) {
        enqueuePrefetch(index - i * step);
    }
    pumpPageQueue();
}

void ComicBridge::enqueuePrefetch(int index)
{
    if (index < 0 || index >= m_pages.size()) {
        return;
    }
    if (m_inflightPages.contains(index) || m_pendingPages.contains(index)) {
        return;
    }
    if (!pageUrlAt(index).isEmpty()) {
        return; // 已经在盘上，别白排一次
    }
    m_pendingPages.append(index);
}

// ---------------------------------------------------------------- 多页按需解压

QString ComicBridge::pageUrlAt(int index) const
{
    if (index < 0 || index >= m_pages.size()) {
        return QString();
    }
    // 当前页可能刚解出来还没检查过盘，直接给手上这份，省一次 stat
    if (index == m_pageIndex && !m_pageUrl.isEmpty()) {
        return m_pageUrl;
    }
    const QString cached = pageCachePath(index);
    if (QFileInfo(cached).size() <= 0) {
        return QString();
    }
    return QUrl::fromLocalFile(cached).toString();
}

void ComicBridge::ensurePage(int index)
{
    if (!m_opened || index < 0 || index >= m_pages.size()) {
        return;
    }
    // 缓存页离线也能给；要现场解压的才需要归档
    if (!pageUrlAt(index).isEmpty()) {
        // 条漫的「在读」只体现在滚动触发的 `ensurePage` 上，这里不刷 mtime 的话
        // 条漫用户看的页永远是最旧的那批
        markPageAccessed(index);
        emit pageCached(index);
        return;
    }
    if (!m_book || m_offline) {
        return;
    }
    // 当前页正由主路径在解（单页/双页都会把首张页再 ensurePage 一次）：别重复解
    if (m_pageLoading && index == m_pageIndex) {
        return;
    }
    if (m_inflightPages.contains(index) || m_pendingPages.contains(index)) {
        return;
    }
    // QML 要的页（双页配对页 / 条漫一屏 / 缩略图）比自动预取更急：插到队首
    m_pendingPages.prepend(index);
    pumpPageQueue();
}

void ComicBridge::clearPageQueue()
{
    // 队列里只是「还没开始」的，丢掉即可；在途的解压中断不了，让它跑完（结果照样进缓存）
    m_pendingPages.clear();
}

void ComicBridge::pumpPageQueue()
{
    // 主路径（用户正在看的那一页）也占并发名额：预取不许把它挤到后面
    while (m_book && !m_offline && !m_pendingPages.isEmpty()
           && m_inflightPages.size() + m_primaryInflight < kMaxInflight) {
        const int index = m_pendingPages.takeFirst();
        if (!pageUrlAt(index).isEmpty()) {
            emit pageCached(index);
            continue;
        }
        m_inflightPages.insert(index);
        const qint64 started = QDateTime::currentMSecsSinceEpoch();
        m_book->readPage(index, [this, index, started](QByteArray bytes, StorageError error) {
            m_inflightPages.remove(index);
            const bool decoded = error.isNull() && !bytes.isEmpty() && isDecodableImage(bytes);
            if (decoded) {
                writePageCache(index, bytes);
                emit pageCached(index);
                MH_DEBUG(ComicReader,
                         QStringLiteral("预取第 %1 页完成（%2 字节 / %3 ms）")
                             .arg(index + 1)
                             .arg(bytes.size())
                             .arg(QDateTime::currentMSecsSinceEpoch() - started));
            }
            // 预取正好捡到「用户刚翻到的那页」（`loadPage` 会跳过重复解压）：
            // 直接当主路径收尾。失败要显性报出来，否则那一页会一直转圈
            if (index == m_pageIndex && m_pageUrl.isEmpty()) {
                if (decoded) {
                    publishPage(index);
                } else {
                    setPageLoading(false);
                    setStatus(QString());
                    fail(error.isNull() ? QStringLiteral("第 %1 页不是能显示的图片").arg(index + 1)
                                        : error.userMessage());
                }
            } else if (!error.isNull()) {
                MH_DEBUG(ComicReader,
                         QStringLiteral("预取第 %1 页失败（不打断阅读）：%2")
                             .arg(index + 1)
                             .arg(error.userMessage()));
            }
            pumpPageQueue();
        });
    }
}

void ComicBridge::trackPage(int index)
{
    if (!m_opened || m_pages.isEmpty()) {
        return;
    }
    const int clamped = qBound(0, index, m_pages.size() - 1);
    if (clamped == m_pageIndex) {
        return;
    }
    // 条漫是「滚动即翻页」：页码要跟上，但**不要去解压**——那一屏的图
    // 已经由 `ensurePage` 负责；这里只更新进度，并按新位置重排两侧预取
    m_pageDirection = clamped >= m_pageIndex ? 1 : -1;
    m_pageIndex = clamped;
    emit pageChanged();
    emit percentChanged();
    commitProgress();
    // 滚动很快：上一屏的排队已作废，按新位置重排（在途的不取消）
    m_pendingPages.clear();
    prefetchAround(clamped, m_pageDirection);
}

// ---------------------------------------------------------------- 进度 / 缓存

void ComicBridge::commitProgress()
{
    if (!m_opened || m_pages.isEmpty() || m_pageIndex < 0) {
        return;
    }
    ProgressRecord record;
    record.connectionId = m_connectionId;
    record.path = m_path;
    record.mediaType = QStringLiteral("comic");
    record.title = m_title;
    record.progress.insert(QStringLiteral("page"), m_pageIndex);
    // 页码会随页序重排漂移，页名是「同一张图」的稳定标识（换版本时也不会张冠李戴）
    record.progress.insert(QStringLiteral("pageName"), m_pages.value(m_pageIndex));
    // 已经上报过「翻到底」的，别被后续换屏的自动提交改回未读完
    record.finished = m_finishedBook || m_pageIndex >= m_pages.size() - 1;
    record.percent = record.finished ? 1.0 : percent();
    if (m_fileSize > 0) {
        record.fileSize = m_fileSize;
        record.modTimeMs = m_modTime;
    }
    ProgressRepository::instance().upsert(record);
}

// ---------------------------------------------------------------- 读完推荐（§4.6）

void ComicBridge::setAtBookEnd(bool atEnd)
{
    if (m_bookEnd == atEnd) {
        return;
    }
    m_bookEnd = atEnd;
    emit percentChanged();

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

void ComicBridge::markFinished()
{
    // 离线只读到「恰好缓存过的那几页」，未必是全书结尾：这种情况不盖章「已读完」
    if (!m_opened || m_offline || m_pages.isEmpty() || m_pageIndex < 0) {
        return;
    }
    m_finishedBook = true;
    // 双页最后一屏的 pageIndex 停在倒数第二页，但「读完了」这件事照样要落库
    commitProgress();
}

void ComicBridge::resolveNextSuggestion()
{
    if (m_nextDismissed || m_offline || m_path.isEmpty() || m_connectionId.isEmpty()) {
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
    const QPointer<ComicBridge> guard(this);
    const int queryId = ++m_nextQueryId;
    const QString currentPath = StoragePath::normalize(m_path);
    adapter->list(dir, [this, guard, queryId, currentPath, sortKey, ascending](ListResult result) {
        if (!guard || queryId != m_nextQueryId || !result.ok()) {
            return;
        }
        if (StoragePath::normalize(m_path) != currentPath) {
            return; // 期间已经换书
        }
        // 候选要按阅读顺序一个个确认，不能只靠「已有的结论」：
        // 隔壁那卷 epub 没人打开过，缓存里是未知 —— 直接问缓存等于永远推不出来。
        FileEntryList sorted = result.value;
        DirectorySort::sort(sorted, sortKey, ascending);
        int index = -1;
        for (int i = 0; i < sorted.size(); ++i) {
            if (sorted.at(i).path == currentPath) {
                index = i;
                break;
            }
        }
        if (index < 0) {
            clearNextSuggestion();
            return;
        }
        scanNextCandidates(sorted, index + 1, kMaxNextProbes, queryId);
    });
}

void ComicBridge::scanNextCandidates(const FileEntryList &sorted, int fromIndex, int probesLeft,
                                     int queryId)
{
    for (int i = fromIndex; i < sorted.size(); ++i) {
        if (queryId != m_nextQueryId) {
            return; // 又读到底一轮，或已经换书
        }
        const FileEntry &entry = sorted.at(i);
        if (entry.isDir) {
            continue;
        }

        bool comic = false;
        if (ComicDetector::known(m_connectionId, entry, &comic)) {
            if (comic) {
                setNextSuggestion(entry);
                return;
            }
            continue; // 判过了：文字书 / 普通文件，跳过
        }

        // 到这里只剩下「没人读过 OPF 的 epub」：要真读一次才知道是不是图集
        if (probesLeft <= 0) {
            // 预算用尽。此时后面还夹着没判过的 epub，隔着它们去推更靠后的 cbz 会漏卷，
            // 所以宁可这次不给建议
            MH_INFO(ComicReader, QStringLiteral("下一卷候选：探测预算用尽，暂不推荐"));
            clearNextSuggestion();
            return;
        }
        probeNextCandidate(entry, sorted, i + 1, probesLeft - 1, queryId);
        return;
    }
    clearNextSuggestion();
}

void ComicBridge::probeNextCandidate(const FileEntry &entry, const FileEntryList &sorted,
                                     int nextIndex, int probesLeft, int queryId)
{
    if (!m_adapter) {
        clearNextSuggestion();
        return;
    }

    const int serial = ++m_nextProbeSerial;
    const QPointer<ComicBridge> guard(this);
    m_adapter->stat(
        entry.path,
        [this, guard, serial, queryId, entry, sorted, nextIndex, probesLeft](StatResult stat) {
            if (!guard || serial != m_nextProbeSerial || queryId != m_nextQueryId) {
                return;
            }
            if (!stat.ok() || stat.value.size <= 0) {
                // 够不着（离线 / 没权限）：跳过这一本继续往后，不让一个坏文件毁掉整条链
                scanNextCandidates(sorted, nextIndex, probesLeft, queryId);
                return;
            }

            const qint64 size = stat.value.size;
            const qint64 modSecs =
                stat.value.modTime.isValid() ? stat.value.modTime.toSecsSinceEpoch() : 0;
            m_nextProbeSource = std::make_unique<AdapterRangeSource>(m_adapter, entry.path, size);
            m_nextProbe = std::make_unique<EpubBook>(m_nextProbeSource.get());
            m_nextProbe->load([this, guard, serial, queryId, entry, sorted, nextIndex, probesLeft,
                               size, modSecs](EpubMetadata metadata, StorageError error) {
                if (!guard || serial != m_nextProbeSerial || queryId != m_nextQueryId) {
                    return;
                }
                m_nextProbe.reset();
                m_nextProbeSource.reset();

                if (error.isNull()) {
                    // 探测结论一律回写：下次列目录 / 再读到底就不用再付这笔请求
                    ComicDetector::remember(m_connectionId, entry.path, metadata.imageOnly, size,
                                            modSecs);
                    if (metadata.imageOnly && !metadata.imageEntries.isEmpty()) {
                        setNextSuggestion(entry);
                        return;
                    }
                }
                scanNextCandidates(sorted, nextIndex, probesLeft, queryId);
            });
        });
}

void ComicBridge::setNextSuggestion(const FileEntry &entry)
{
    if (!entry.isValid()) {
        MH_INFO(ComicReader, QStringLiteral("下一卷候选：无"));
        clearNextSuggestion();
        return;
    }

    MH_INFO(ComicReader, QStringLiteral("下一卷候选：%1").arg(entry.name));

    QVariantMap suggestion;
    suggestion.insert(QStringLiteral("connectionId"), m_connectionId);
    suggestion.insert(QStringLiteral("path"), entry.path);
    // 漫画阅读器显示的是文件名（带扩展名），换卷后标题才与正常打开一致
    suggestion.insert(QStringLiteral("title"), StoragePath::fileName(entry.path));
    suggestion.insert(QStringLiteral("name"), entry.name);
    suggestion.insert(QStringLiteral("size"), entry.size);
    m_nextSuggestion = suggestion;
    emit nextSuggestionChanged();
}

void ComicBridge::clearNextSuggestion()
{
    if (m_nextSuggestion.isEmpty()) {
        return;
    }
    m_nextSuggestion.clear();
    emit nextSuggestionChanged();
}

void ComicBridge::openNextSuggestion()
{
    if (m_nextSuggestion.isEmpty()) {
        return;
    }
    const QVariantMap suggestion = m_nextSuggestion;
    clearNextSuggestion();
    // 换书保留它自己的续读点：用户点的是「读下一卷」，不是「从头重读」
    open(m_connectionId, suggestion.value(QStringLiteral("path")).toString(),
         suggestion.value(QStringLiteral("title")).toString());
}

void ComicBridge::dismissNextSuggestion()
{
    m_nextDismissed = true;
    ++m_nextQueryId; // 在途的目录列举回来也别再弹
    clearNextSuggestion();
}

void ComicBridge::fail(const QString &message)
{
    m_loading = false;
    m_pageLoading = false;
    m_errorText = message;
    m_statusText.clear();
    setDownloadProgress(-1.0);
    emit loadingChanged();
    emit pageLoadingChanged();
    emit statusChanged();
    emit errorTextChanged();
    MH_WARN(ComicReader, message);
}

void ComicBridge::teardown()
{
    ++m_pageSerial;
    ++m_packSerial;
    ++m_epubSerial;
    m_packPath.clear();
    setDownloadProgress(-1.0);
    clearPageQueue();
    // 换书 / 关书：在途预取的计数必须归零，否则下一本会被「名额已满」卡住
    // （`ComicBook` 析构时回调已全部作废，不会有迟到的回调再来减）
    m_inflightPages.clear();
    m_primaryInflight = 0;
    m_pageDirection = 1;
    m_touchedPages.clear();
    m_book.reset();
    // 探测句柄持有 RangeSource 的读：必须排在 source 之前释放
    m_epubProbe.reset();
    // 「下一本」的探测也要作废：先让回调失效，再释放（同样排在 source 之前）
    ++m_nextProbeSerial;
    m_nextProbe.reset();
    m_nextProbeSource.reset();
    m_pageOrderHint.clear();
    m_sourceOwner.reset();
    m_source = nullptr;
    m_adapter = nullptr;
    m_pages.clear();
    m_pageIndex = -1;
    m_pageUrl.clear();
    m_pageLoading = false;
    // `m_opened` 必须跟着回 false：`openBookCommon` 靠它判断「清单是不是已经先上屏」，
    // 留着上一本的 true 会让新书走「归档补齐」分支，永远进不了 opened
    if (m_opened) {
        m_opened = false;
        emit openedChanged();
    }
    // 降级 / 秒开的中间态属于这一本：换书一律回到「正常打开」
    m_archivePending = false;
    m_waitingPage = -1;
    if (m_offline) {
        m_offline = false;
        emit offlineChanged();
    }
    // 方向判定属于这一本：换书要重新猜，否则上一本的结论会顶到下一本
    if (m_detected != ComicDirection::Unknown) {
        m_detected = ComicDirection::Unknown;
        emit directionChanged();
    }
    // 自动模式下回到默认值（右→左）：下一本判不出方向时不该继承上一本的结果
    if (m_direction < 0 && !m_rightToLeft) {
        m_rightToLeft = true;
        emit rightToLeftChanged();
    }
    // 读完推荐属于这一卷：换书必须撤掉提示条，并作废在途的目录列举
    m_bookEnd = false;
    m_finishedBook = false;
    m_nextDismissed = false;
    ++m_nextQueryId;
    clearNextSuggestion();
}

void ComicBridge::setStatus(const QString &text)
{
    if (m_statusText == text) {
        return;
    }
    m_statusText = text;
    emit statusChanged();
}

void ComicBridge::setPageLoading(bool loading)
{
    if (m_pageLoading == loading) {
        return;
    }
    m_pageLoading = loading;
    emit pageLoadingChanged();
}

void ComicBridge::setDownloadProgress(double value)
{
    const double clamped = value < 0.0 ? -1.0 : qBound(0.0, value, 1.0);
    if (qFuzzyCompare(clamped + 2.0, m_downloadProgress + 2.0)) {
        return; // +2 是为了让 -1 也能走「相等」判断（qFuzzyCompare 不吃 0 附近）
    }
    m_downloadProgress = clamped;
    emit downloadProgressChanged();
}

QString ComicBridge::fingerprint() const
{
    if (m_fileSize <= 0) {
        return QStringLiteral("none");
    }
    return hashOf(QStringLiteral("%1:%2").arg(m_fileSize).arg(m_modTime), 8);
}

QString ComicBridge::pageCacheDir() const
{
    // 分区名收敛到 `CacheDirs`：以前这里写 `"comic"`、整包写 `"comic-packs"`，
    // 与 `AppPaths::initializeAll()` 建的目录名三套并存
    return CachePartitions::path(QString::fromLatin1(CacheDirs::ComicPages));
}

QString ComicBridge::pageCachePath(int index) const
{
    const QString dir = pageCacheDir();
    AppPaths::ensureDir(dir);
    const QString key = hashOf(m_connectionId + QLatin1Char('\n') + m_path, kCacheHashChars);

    QString suffix = QFileInfo(m_pages.value(index)).suffix().toLower();
    if (suffix.isEmpty()) {
        suffix = QStringLiteral("img");
    }
    const QString name =
        QStringLiteral("%1-%2-%3.%4")
            .arg(key, fingerprint(), QString::number(index).rightJustified(5, QLatin1Char('0')),
                 suffix);
    return dir + QLatin1Char('/') + name;
}

void ComicBridge::purgeStalePages()
{
    const QString dir = pageCacheDir();
    if (!QFileInfo::exists(dir)) {
        return;
    }
    const QString key = hashOf(m_connectionId + QLatin1Char('\n') + m_path, kCacheHashChars);
    const QString alive = QStringLiteral("%1-%2-").arg(key, fingerprint());

    QDir cache(dir);
    const QStringList entries =
        cache.entryList(QStringList{QStringLiteral("%1-*.?*").arg(key)}, QDir::Files);
    for (const QString &entry : entries) {
        if (entry.startsWith(alive)) {
            continue;
        }
        cache.remove(entry);
    }
}

} // namespace myhub
