#pragma once

#include "core/archive/RangeZipReader.h"
#include "core/storage/StorageError.h"
#include "core/stream/RangeSource.h"

#include <QHash>
#include <QString>
#include <QStringList>
#include <QVector>

#include <functional>
#include <memory>

namespace myhub {

/// 目录里的一项（阅读顺序上的一个 xhtml 文档）
struct EpubChapterRef
{
    QString title;
    QString href;  ///< 相对 zip 根的归一化路径（已去掉 #fragment）
    int level = 0; ///< 目录层级，仅 nav/ncx 能给；spine 兜底时全为 0
};

struct EpubMetadata
{
    QString title;
    QString author;
    QString language;
    QVector<EpubChapterRef> chapters;
    /// spine 里「整页图片」的条数：图集 epub 才非 0（见 `EpubBook::imageOnly`）
    int imagePages = 0;
    /// 判定为图集：交给漫画阅读器按页看，别在小说阅读器里对着空段落翻
    bool imageOnly = false;
    /// 图集的页序（zip 条目名，**按 spine 顺序**）：直接当漫画页名清单用
    QStringList imageEntries;
};

/**
 * epub 阅读器（PC-205）。
 *
 * 只做「解包 + 目录 + 段落流」，不管渲染与布局 —— 那是 `NovelBridge` 与 QML 的事。
 * 所有读取都经 `RangeZipReader`，所以整包不会被下载：列目录只读容器 / OPF / NAV 三个
 * 小条目，打开某章才读那一章。
 *
 * 解析容错取向：container / OPF / NCX 按严格 XML 解析（规范要求良构），章节 XHTML
 * 则走「去标签 + 实体解码」的宽松路线 —— 真实 epub 里 XHTML 常常不是良构的，
 * 用严格解析器会让整本书打不开。
 */
class EpubBook
{
public:
    using LoadCallback = std::function<void(EpubMetadata metadata, StorageError error)>;
    using ChapterCallback = std::function<void(QStringList paragraphs, StorageError error)>;
    using CoverCallback = std::function<void(QByteArray bytes, StorageError error)>;

    /// 封面原始字节上限：封面是正文之外的小图，超过就是 OPF 指错了对象
    static constexpr qint64 kMaxCoverBytes = 16 * 1024 * 1024;
    /// 正文插图字节上限：再大就不是「插图」了（多半是 manifest 里指了整本扫描件）
    static constexpr qint64 kMaxImageBytes = 32 * 1024 * 1024;

    explicit EpubBook(RangeSource *source);
    ~EpubBook();

    EpubBook(const EpubBook &) = delete;
    EpubBook &operator=(const EpubBook &) = delete;

    /// 读 container.xml → OPF → NAV/NCX，产出阅读顺序的章列表
    void load(LoadCallback cb);
    /// 读第 index 章并转成段落；图片型文档（封面页）返回空列表
    void readChapter(int index, ChapterCallback cb);
    /**
     * 读封面原始图片字节（jpg/png/gif/webp 原样返回，不解码、不缩放）。
     *
     * 文件只经 RangeZipReader 读那一条，不会整包下载；OPF 没声明封面时直接报
     * `NotFound`。EPUB3 认 `properties="cover-image"`，EPUB2 认
     * `<meta name="cover" content="<manifest id>"/>`。
     */
    void readCover(CoverCallback cb);
    /**
     * 读任意 zip 条目的原始字节（正文插图用）。
     *
     * 与 `readCover` 同一条路：只读那一条，不解码、不缩放 —— 解码与缩放是渲染层的
     * 事，core 层不碰 QtGui（见 `myhub_core` 的分层约束）。
     */
    void readResource(const QString &entry, CoverCallback cb);
    /// 该条目在不在 zip 里：章节里的 `<img src>` 常指向打包时漏掉的图
    bool hasEntry(const QString &entry) const;
    void cancel();

    /**
     * 段落流里的「插图占位」。
     *
     * 段落流是 `QStringList`，插图占一格：把 zip 条目名塞进一条带控制字符前缀的
     * 段落里。好处是**下标空间不变** —— 进度锚点、滚动上报、章节缓存全都不用改，
     * 渲染层认出前缀就换成图片。
     *
     * 控制字符在解码后的正文里不可能自然出现（XHTML 里的 0x01 会被清洗掉），
     * 所以这条标记不会和真实段落撞车。
     */
    static QString imageParagraph(const QString &entry);
    static bool isImageParagraph(const QString &paragraph);
    /// 占位里记的 zip 条目名；不是插图段落时返回空串
    static QString imageEntryOf(const QString &paragraph);

    /// href → zip 条目名：percent 解码 + 处理 `../` + 相对 OPF 所在目录
    static QString resolveHref(const QString &baseDir, const QString &href);
    /**
     * XHTML → 段落（块级标签断段、实体解码、空白压缩、插图占位）。
     *
     * `baseDir` 是章节文件所在目录（带结尾 `/`）：`<img src>` 是相对章节文件写的，
     * 不传就认不出图片条目。
     */
    static QStringList htmlToParagraphs(const QString &xhtml, const QString &baseDir = QString());

    const QVector<EpubChapterRef> &chapters() const { return m_chapters; }
    /// 封面条目在 zip 里的路径；没有声明时为空
    const QString &coverHref() const { return m_coverHref; }
    /// spine 里「整页图片」的条数
    int imagePageCount() const { return m_imagePages; }
    /// 图集的页序（zip 条目名，按 spine 顺序；不是图集时为空）
    const QStringList &imageEntries() const { return m_imageEntries; }
    /**
     * 是否图集（整本都是整页图片，比如把漫画打包成 epub）。
     *
     * 判据：spine 至少 2 条、且 ≥80% 是图片文档。正常小说的 spine 里只有 xhtml，
     * 封面虽然也是图片，但它在 manifest 而不在 spine，不会误判；把一章拆成几张
     * 扫描图的排版书也归到图集 —— 小说阅读器对它只能解出空段落。
     */
    bool imageOnly() const;

private:
    void openArchive();
    void readContainer();
    void readPackage(const QString &opfPath);
    void collectToc();
    /// 目录文件里的 href 相对它自己所在目录，不一定和 OPF 同目录
    void applyNcx(const QByteArray &ncxData, const QString &baseDir);
    void applyNav(const QByteArray &navData, const QString &baseDir);
    void buildChapters();
    void finishLoad(const StorageError &error);
    void finishChapter(QStringList paragraphs, const StorageError &error);
    void finishCover(QByteArray bytes, const StorageError &error);
    void finishResource(quint64 id, QByteArray bytes, const StorageError &error);

    RangeSource *m_source = nullptr;
    std::unique_ptr<RangeZipReader> m_zip;
    QVector<ZipEntry> m_entries;

    LoadCallback m_loadCallback;
    ChapterCallback m_chapterCallback;
    CoverCallback m_coverCallback;
    /// 插图请求可能并发（一章好几张）：按请求 id 各自回调，别互相顶掉
    QHash<quint64, CoverCallback> m_resourceCallbacks;
    /// 封面、章节、插图资源各用一条串行线：取插图不该把在途的章节请求判废
    quint64 m_serial = 0;
    quint64 m_coverSerial = 0;
    quint64 m_resourceSerial = 0;

    QString m_opfPath;
    QString m_opfDir;
    QString m_title;
    QString m_author;
    QString m_language;
    /// spine 的 idref 顺序（manifest id）
    QStringList m_spine;
    /// manifest id → zip 条目名
    QHash<QString, QString> m_manifestHref;
    /// manifest id → media-type（判定图集用：spine 指向的条目是不是 image/*）
    QHash<QString, QString> m_manifestType;
    /// spine 里图片文档的条数 / spine 总条数
    int m_imagePages = 0;
    int m_spineCount = 0;
    /// spine 里图片文档的条目名，保持 spine 顺序（图集交给漫画阅读器时的页序）
    QStringList m_imageEntries;
    QString m_navHref;
    QString m_ncxHref;
    /// 归一化 href → 标题（NAV/NCX 解析结果，spine 兜底时为空）
    QHash<QString, QString> m_tocTitles;
    QVector<EpubChapterRef> m_chapters;
    /// 封面条目路径（OPF 未声明时为空）
    QString m_coverHref;

    std::shared_ptr<bool> m_alive = std::make_shared<bool>(true);
};

} // namespace myhub
