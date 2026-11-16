#include "ComicBridge.h"

#include "core/archive/ArchiveFetcher.h"
#include "core/comic/ComicBook.h"
#include "core/history/ProgressRepository.h"
#include "core/preferences/AppSettings.h"
#include "core/storage/LocalAdapter.h"
#include "core/storage/StorageAdapter.h"
#include "core/stream/AdapterRangeSource.h"
#include "core/utils/AppLogger.h"
#include "core/utils/AppPaths.h"
#include "features/connections/ConnectionStore.h"

#include <QBuffer>
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImageReader>
#include <QSaveFile>
#include <QUrl>

#include <utility>

namespace myhub {
namespace {

constexpr int kCacheHashChars = 16;

constexpr auto kModeKey = "reader.comic.mode";
constexpr auto kRtlKey = "reader.comic.rtl";
/// 与小说阅读器**同一个键**：亮度是「这块屏幕」的偏好，不是某个阅读器的
constexpr auto kBrightnessKey = "reader.brightness";

constexpr int kModeSingle = 0;
constexpr int kModeDouble = 1;
constexpr int kModeStrip = 2;
constexpr int kModeCount = 3;

QString hashOf(const QString &text, int chars)
{
    return QString::fromLatin1(
               QCryptographicHash::hash(text.toUtf8(), QCryptographicHash::Sha1).toHex())
        .left(chars);
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
    return static_cast<double>(m_pageIndex + 1) / static_cast<double>(m_pages.size());
}

// ---------------------------------------------------------------- 显示偏好

void ComicBridge::loadPreferences()
{
    AppSettings &settings = AppSettings::instance();
    m_mode = qBound(kModeSingle, settings.value(kModeKey, kModeSingle).toInt(), kModeCount - 1);
    m_rightToLeft = settings.value(kRtlKey, true).toBool();
    m_brightness = settings.value(kBrightnessKey, -1.0).toDouble();
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

void ComicBridge::setRightToLeft(bool rightToLeft)
{
    if (rightToLeft == m_rightToLeft) {
        return;
    }
    m_rightToLeft = rightToLeft;
    storePreference(kRtlKey, m_rightToLeft);
    emit rightToLeftChanged();
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

    // stat 只为拿指纹（决定旧页缓存是否还有效）与源长度（RangeZipReader 算区间要用）
    adapter->stat(m_path, [this](StatResult result) {
        if (!result.ok()) {
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

    m_book->open([this](QStringList pages, StorageError openError) {
        if (!openError.isNull()) {
            fail(openError.userMessage());
            return;
        }
        m_pages = pages;

        int resume = 0;
        ProgressRecord record;
        if (ProgressRepository::instance().find(m_connectionId, m_path, &record)
            && !record.finished) {
            resume = record.progress.value(QStringLiteral("page")).toInt();
        }
        if (m_pages.isEmpty()) {
            fail(QStringLiteral("这本漫画一页都没有"));
            return;
        }

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

        loadPage(qBound(0, resume, m_pages.size() - 1));
    });
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
        [this, serial, packPath](QString localPath, StorageError error) {
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

QString ComicBridge::packCachePath() const
{
    const QString dir = AppPaths::cachePartition(QStringLiteral("comic-packs"));
    AppPaths::ensureDir(dir);
    const QString key = hashOf(m_connectionId + QLatin1Char('\n') + m_path, kCacheHashChars);
    // 文件名里带指纹：文件换了就是另一个包，旧包由 `purgeStalePacks` 清掉
    return QStringLiteral("%1/%2-%3.pack").arg(dir, key, fingerprint());
}

void ComicBridge::purgeStalePacks() const
{
    const QString dir = AppPaths::cachePartition(QStringLiteral("comic-packs"));
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
    const QString dir = AppPaths::cachePartition(QStringLiteral("comic-packs"));
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
    if (!m_book || m_pages.isEmpty()) {
        return;
    }
    index = qBound(0, index, m_pages.size() - 1);
    // 真正要看的这一页优先：自动预解让位（`ComicBook` 只有一个在途槽位，
    // 下面这次 readPage 会顶掉排队中的那次回调，所以标志也要一起复位）
    m_pendingPages.clear();
    m_queueBusy = false;
    const int serial = ++m_pageSerial;

    // 页码先动、图后到：进度条与页码不必等解压
    m_pageIndex = index;
    m_pageUrl.clear();
    m_errorText.clear();
    emit pageChanged();
    emit percentChanged();
    emit errorTextChanged();

    const QString cached = pageCachePath(index);
    if (QFileInfo(cached).size() > 0) {
        MH_DEBUG(ComicReader, QStringLiteral("第 %1 页命中缓存").arg(index + 1));
        m_pageUrl = QUrl::fromLocalFile(cached).toString();
        setPageLoading(false);
        setStatus(QString());
        emit pageChanged();
        commitProgress();
        prefetch(index + 1);
        return;
    }

    setPageLoading(true);
    setStatus(QStringLiteral("正在解压第 %1 页…").arg(index + 1));

    MH_INFO(ComicReader, QStringLiteral("解压第 %1 页…").arg(index + 1));

    m_book->readPage(index, [this, index, serial](QByteArray bytes, StorageError error) {
        if (serial != m_pageSerial) {
            return; // 用户已经翻到别页了
        }
        if (!error.isNull()) {
            MH_WARN(
                ComicReader,
                QStringLiteral("解页失败（第 %1 页）：%2").arg(index + 1).arg(error.userMessage()));
            setPageLoading(false);
            setStatus(QString());
            // 页面级失败不关阅读器：前一页还在，用户点「重试」即可
            fail(error.userMessage());
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

    m_pageUrl = QUrl::fromLocalFile(pageCachePath(index)).toString();
    m_pageIndex = index;
    setPageLoading(false);
    setStatus(QString());
    emit pageChanged();
    commitProgress();
    prefetch(index + 1);
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
    }
}

void ComicBridge::prefetch(int index)
{
    ensurePage(index);
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
    if (!m_opened || !m_book || index < 0 || index >= m_pages.size()) {
        return;
    }
    if (!pageUrlAt(index).isEmpty()) {
        emit pageCached(index);
        return;
    }
    if (m_pendingPages.contains(index)) {
        return;
    }
    m_pendingPages.append(index);
    pumpPageQueue();
}

void ComicBridge::clearPageQueue()
{
    m_pendingPages.clear();
    m_queueBusy = false;
}

void ComicBridge::pumpPageQueue()
{
    // 用户正在等的那一页优先：`loadPage` 的在途回调不许被自动预解顶掉
    // （顶掉就变成「翻页翻一半没了」，等页解完由 `prefetch` 再把队列续上）
    if (m_pageLoading) {
        return;
    }

    // `ComicBook::readPage` 是单槽位的（新请求顶掉旧回调），所以这里一次只放一页，
    // 回来再放下一张：双页和条漫都是「一屏几页」，靠这条队列排队而不是并发抢槽
    while (!m_queueBusy && !m_pendingPages.isEmpty() && m_book) {
        const int index = m_pendingPages.takeFirst();
        if (!pageUrlAt(index).isEmpty()) {
            emit pageCached(index);
            continue;
        }
        m_queueBusy = true;
        m_book->readPage(index, [this, index](QByteArray bytes, StorageError error) {
            m_queueBusy = false;
            if (error.isNull() && !bytes.isEmpty() && isDecodableImage(bytes)) {
                writePageCache(index, bytes);
                emit pageCached(index);
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
    // 已经由 `ensurePage` 负责，这里只更新进度
    m_pageIndex = clamped;
    emit pageChanged();
    emit percentChanged();
    commitProgress();
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
    record.finished = m_pageIndex >= m_pages.size() - 1;
    record.percent = record.finished ? 1.0 : percent();
    if (m_fileSize > 0) {
        record.fileSize = m_fileSize;
        record.modTimeMs = m_modTime;
    }
    ProgressRepository::instance().upsert(record);
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
    m_packPath.clear();
    setDownloadProgress(-1.0);
    clearPageQueue();
    m_book.reset();
    m_sourceOwner.reset();
    m_source = nullptr;
    m_adapter = nullptr;
    m_pages.clear();
    m_pageIndex = -1;
    m_pageUrl.clear();
    m_pageLoading = false;
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
    return AppPaths::cachePartition(QStringLiteral("comic"));
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
