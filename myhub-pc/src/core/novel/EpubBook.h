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
    void cancel();

    const QVector<EpubChapterRef> &chapters() const { return m_chapters; }
    /// 封面条目在 zip 里的路径；没有声明时为空
    const QString &coverHref() const { return m_coverHref; }

    /// href → zip 条目名：percent 解码 + 处理 `../` + 相对 OPF 所在目录
    static QString resolveHref(const QString &baseDir, const QString &href);
    /// XHTML → 段落（块级标签断段、实体解码、空白压缩）
    static QStringList htmlToParagraphs(const QString &xhtml);

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

    RangeSource *m_source = nullptr;
    std::unique_ptr<RangeZipReader> m_zip;
    QVector<ZipEntry> m_entries;

    LoadCallback m_loadCallback;
    ChapterCallback m_chapterCallback;
    CoverCallback m_coverCallback;
    /// 封面与章节各用一条串行线：取封面不该把在途的章节请求判废
    quint64 m_serial = 0;
    quint64 m_coverSerial = 0;

    QString m_opfPath;
    QString m_opfDir;
    QString m_title;
    QString m_author;
    QString m_language;
    /// spine 的 idref 顺序（manifest id）
    QStringList m_spine;
    /// manifest id → zip 条目名
    QHash<QString, QString> m_manifestHref;
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
