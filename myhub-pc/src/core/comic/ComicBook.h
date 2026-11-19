#pragma once

#include "core/archive/ArchiveReader.h"
#include "core/archive/RangeZipReader.h"
#include "core/storage/StorageError.h"

#include <QHash>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QVector>

#include <functional>
#include <memory>

namespace myhub {

class RangeSource;

/**
 * 漫画书（PC-207）—— zip / cbz / rar / cbr 的页序与按页解包。
 *
 * 分层理由与 `EpubBook` 一致：**只在 myhub_core 里做解包**，桥接层与 QML 不碰压缩细节。
 * 一个 cbz 就是「一堆图片条目 + 一个看起来像书的名字」，没有元数据可读，
 * 所以这一层非常薄：页序 + 取一页。
 *
 * 两条解包路径，对上层是同一套接口：
 *   - **zip / cbz**：经 `RangeZipReader` 从 `RangeSource` 随机读，**不整包下载**；
 *   - **rar / cbr**：rar 没有尾部署引，只能整包在手 —— 用 `ArchiveReader`（libarchive）
 *     读本地文件。远程 rar 由桥接层先落地成缓存文件再交给这里。
 *
 * 三条纪律：
 *   - **不整包下载**（zip）：列页只读中央目录，取页只读那一条的压缩数据；
 *   - **页序 = 页名自然排序**，两条路径共用 `pageorder` 同一套过滤规则，
 *     不会出现「封面是第一页、打开却在另一页」，换格式也不会错乱；
 *   - 没有图片条目时明确报「不是漫画文件」，不返回空列表让上层去猜。
 *
 * 线程：本地文件路径（rar）的列页 / 解页在后台线程跑，回调仍投递回构造线程；
 * `RangeSource` 路径的回调由 source 自己保证线程（适配器已投递回 GUI 线程）。
 * **解页可并发**：每次 `readPage` 各带一份回调、各带一个请求 id，先回来的先投递；
 * 并发度由调用方控制（桥接层按「在途 ≤3」排队）。
 */
class ComicBook : public QObject
{
public:
    /// 列页结果：`pageNames` 按阅读顺序排列；空列表 + 非空 error 表示不是漫画
    using OpenCallback = std::function<void(QStringList pageNames, StorageError error)>;
    using PageCallback = std::function<void(QByteArray bytes, StorageError error)>;

    /// zip / cbz：按需 Range 读
    explicit ComicBook(RangeSource *source, QObject *parent = nullptr);
    /// rar / cbr：本地整包文件（也兼容本地 zip，走 libarchive）
    explicit ComicBook(const QString &localFilePath, QObject *parent = nullptr);
    ~ComicBook() override;

    ComicBook(const ComicBook &) = delete;
    ComicBook &operator=(const ComicBook &) = delete;

    /// 打开并列出全部页
    void open(OpenCallback cb);
    /**
     * 指定页序（图集 epub 用 OPF 的 spine 顺序），必须在 `open()` 之前调用。
     *
     * 压缩包里的条目名排序是「猜」出来的页序：`001.jpg / 002.jpg` 这种没问题，
     * 但图集 epub 的页序写在 spine 里，可能和名字顺序不一致。
     *
     * 两条纪律：
     *   - 名单里对得上的条目按名单顺序排，**对不上的条目丢掉** —— 图集 epub 的封面、
     *     广告页在 manifest 而不在 spine，不该混进正文页序；
     *   - 一个都对不上就退回自然排序，宁可页序不理想，也不能把整本开成空书
     *     （自制包里的 href 与条目名偶尔只差大小写，这里做了折中匹配）。
     */
    void setPageOrder(const QStringList &names);
    /**
     * 解第 index 页（图片原始字节，不解码）。
     *
     * **允许多个请求同时在途**：每次调用各带一份回调，按各自的请求 id 分发。
     * 预取（预解下一页 / 双页的配对页）靠这一点并发，不会像单槽位那样
     * 「后一次请求把前一次的回调顶掉」。去重与优先级是桥接层的事。
     */
    void readPage(int index, PageCallback cb);
    void cancel();

    int pageCount() const { return m_names.size(); }
    /// 页名（归档内全名，含子目录）：进度记录与缓存键都用它，页序变了也能对上
    QString pageName(int index) const { return m_names.value(index); }
    /// 是否像漫画压缩包（扩展名判定，内容嗅探在桥接层按 `ComicBook::open` 的结果做）
    static bool isComicArchivePath(const QString &path);
    /// 该路径是否走「整包在手」的 rar 路径
    static bool isRarPath(const QString &path) { return ArchiveReader::isRarPath(path); }

private:
    /// 按 `m_pageOrder` 重排页（zip 与 rar 两条路径共用；空页序时什么都不做）
    void applyPageOrder();
    void finishOpen(const StorageError &error);
    /// 按请求 id 取回调并投递（已被取消 / 对象已清理的请求直接丢弃）
    void finishPage(quint64 requestId, QByteArray bytes, const StorageError &error);

    /// 本地文件的列页 / 解页在后台跑完投递回来
    void openLocalAsync();
    void readPageLocalAsync(int index, quint64 requestId);

    RangeSource *m_source = nullptr;
    /// 非空表示走本地整包路径（rar / cbr，或本地 zip）
    QString m_localPath;

    std::unique_ptr<RangeZipReader> m_zip;
    QVector<ZipEntry> m_pages;
    /// rar 侧的条目（与 `m_pages` 平行的下标；本地路径才有）
    QVector<ArchiveEntry> m_archiveEntries;
    QStringList m_names;
    /// 调用方指定的页序（图集 epub 的 spine）；空 = 按条目名自然排序
    QStringList m_pageOrder;

    OpenCallback m_openCallback;
    /// 在途解页请求：请求 id → 回调（并发预取靠它，见 `readPage` 注释）
    QHash<quint64, PageCallback> m_pageCallbacks;
    /// 取消 / 重新打开时作废在途回调（`RangeZipReader` 自身也有活体标记，这里是第二道）
    quint64 m_openSerial = 0;
    quint64 m_pageRequestSerial = 0;
};

} // namespace myhub
