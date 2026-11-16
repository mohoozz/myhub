#include "EpubBook.h"

#include "core/text/TextCodec.h"

#include <QRegularExpression>
#include <QSet>
#include <QUrl>
#include <QXmlStreamReader>

#include <algorithm>
#include <utility>

namespace myhub {

namespace {

constexpr auto kContainerPath = "META-INF/container.xml";

QString attrOf(const QXmlStreamReader &xml, const char *name)
{
    return xml.attributes().value(QLatin1String(name)).toString();
}

/// XML 声明的 encoding / meta charset：epub 里绝大多数是 UTF-8，但老书会用 GBK
QString declaredEncodingName(const QByteArray &raw)
{
    static const QRegularExpression re(
        QStringLiteral("(?:encoding|charset)\\s*=\\s*[\"']([A-Za-z0-9._-]+)[\"']"),
        QRegularExpression::CaseInsensitiveOption);
    // 只看开头：声明一定在文件最前面，取 2KB 足够，也不会被正文里的 charset 字样骗到
    const auto match = re.match(QString::fromLatin1(raw.left(2048)));
    return match.hasMatch() ? match.captured(1) : QString();
}

QString decodeMarkup(const QByteArray &raw)
{
    const QString declared = declaredEncodingName(raw);
    if (!declared.isEmpty()) {
        const TextCodec::Encoding encoding = TextCodec::fromName(declared);
        if (encoding != TextCodec::Unknown) {
            return TextCodec::decodeAs(raw, encoding).text;
        }
    }
    return TextCodec::decode(raw).text;
}

/// 命名实体 + 数字实体。顺序讲究：先解具体的，最后才解 `&amp;`，
/// 否则 `&amp;lt;` 会被解成 `<`（双层解码）。
QString decodeEntities(QString text)
{
    if (!text.contains(QLatin1Char('&'))) {
        return text;
    }

    static const QRegularExpression numeric(QStringLiteral("&#(x?)([0-9a-fA-F]+);"));
    if (text.contains(QLatin1String("&#"))) {
        QString out;
        out.reserve(text.size());
        int last = 0;
        auto it = numeric.globalMatch(text);
        while (it.hasNext()) {
            const auto match = it.next();
            out += text.mid(last, match.capturedStart() - last);
            bool ok = false;
            const uint code = match.captured(2).toUInt(&ok, match.captured(1).isEmpty() ? 10 : 16);
            // 代理区码点不能直接 fromUcs4，按原样保留
            if (ok && code > 0 && code <= 0x10FFFF && !(code >= 0xD800 && code <= 0xDFFF)) {
                char32_t point = static_cast<char32_t>(code);
                out += QString::fromUcs4(&point, 1);
            } else {
                out += match.captured(0);
            }
            last = match.capturedEnd();
        }
        out += text.mid(last);
        text = out;
    }

    text.replace(QLatin1String("&nbsp;"), QLatin1String(" "));
    text.replace(QLatin1String("&lt;"), QLatin1String("<"));
    text.replace(QLatin1String("&gt;"), QLatin1String(">"));
    text.replace(QLatin1String("&quot;"), QLatin1String("\""));
    text.replace(QLatin1String("&apos;"), QLatin1String("'"));
    text.replace(QLatin1String("&mdash;"), QStringLiteral("—"));
    text.replace(QLatin1String("&hellip;"), QStringLiteral("…"));
    text.replace(QLatin1String("&amp;"), QLatin1String("&"));
    return text;
}

QString stripTags(QString text)
{
    text.remove(QRegularExpression(QStringLiteral("<[^>]*>")));
    return decodeEntities(text).trimmed();
}

/// 目录部分（带尾斜杠），作为相对 href 的基准
QString dirOf(const QString &path)
{
    const int slash = path.lastIndexOf(QLatin1Char('/'));
    return slash >= 0 ? path.left(slash + 1) : QString();
}

QString fileNameTitle(const QString &zipPath)
{
    QString name = zipPath.mid(zipPath.lastIndexOf(QLatin1Char('/')) + 1);
    const int dot = name.lastIndexOf(QLatin1Char('.'));
    if (dot > 0) {
        name.truncate(dot);
    }
    return name;
}

} // namespace

EpubBook::EpubBook(RangeSource *source)
    : m_source(source)
{
    Q_ASSERT(m_source);
}

EpubBook::~EpubBook()
{
    *m_alive = false;
    m_source = nullptr;
    m_zip.reset();
    m_loadCallback = nullptr;
    m_chapterCallback = nullptr;
    m_coverCallback = nullptr;
}

void EpubBook::cancel()
{
    ++m_serial;
    ++m_coverSerial;
    m_loadCallback = nullptr;
    m_chapterCallback = nullptr;
    m_coverCallback = nullptr;
    if (m_zip) {
        m_zip->cancel();
    }
}

void EpubBook::load(LoadCallback cb)
{
    Q_ASSERT(cb);
    m_loadCallback = std::move(cb);
    ++m_serial;

    m_entries.clear();
    m_chapters.clear();
    m_manifestHref.clear();
    m_tocTitles.clear();
    m_spine.clear();
    m_navHref.clear();
    m_ncxHref.clear();
    m_opfPath.clear();
    m_opfDir.clear();
    m_title.clear();
    m_author.clear();
    m_language.clear();
    m_coverHref.clear();

    if (!m_source) {
        finishLoad(StorageError(StorageError::InvalidPath, QStringLiteral("未绑定数据源")));
        return;
    }

    m_zip = std::make_unique<RangeZipReader>(m_source);
    openArchive();
}

void EpubBook::openArchive()
{
    const auto alive = m_alive;
    const quint64 serial = m_serial;
    m_zip->open([this, alive, serial](QVector<ZipEntry> entries, StorageError error) {
        if (!*alive || serial != m_serial) {
            return;
        }
        if (!error.isNull()) {
            finishLoad(error);
            return;
        }
        m_entries = std::move(entries);
        readContainer();
    });
}

void EpubBook::readContainer()
{
    const int index = RangeZipReader::indexOf(m_entries, QLatin1String(kContainerPath));
    if (index < 0) {
        // container.xml 缺失：直接从中央目录里找一个 .opf，尽量把书打开
        for (const ZipEntry &entry : std::as_const(m_entries)) {
            if (entry.name.endsWith(QLatin1String(".opf"), Qt::CaseInsensitive)) {
                m_opfPath = entry.name;
                readPackage(m_opfPath);
                return;
            }
        }
        finishLoad(StorageError(StorageError::InvalidResponse,
                                QStringLiteral("不是有效的 epub：缺少 META-INF/container.xml")));
        return;
    }

    const auto alive = m_alive;
    const quint64 serial = m_serial;
    m_zip->readEntry(
        m_entries.at(index), [this, alive, serial](QByteArray data, StorageError error) {
            if (!*alive || serial != m_serial) {
                return;
            }
            if (!error.isNull()) {
                finishLoad(error);
                return;
            }
            QXmlStreamReader xml(data);
            QString opfPath;
            while (!xml.atEnd() && opfPath.isEmpty()) {
                xml.readNext();
                if (xml.isStartElement() && xml.name() == QLatin1String("rootfile")) {
                    opfPath = attrOf(xml, "full-path");
                }
            }
            if (opfPath.isEmpty()) {
                finishLoad(StorageError(StorageError::InvalidResponse,
                                        QStringLiteral("epub 的 container.xml 里没有 rootfile")));
                return;
            }
            m_opfPath = opfPath;
            readPackage(m_opfPath);
        });
}

void EpubBook::readPackage(const QString &opfPath)
{
    const int index = RangeZipReader::indexOf(m_entries, opfPath);
    if (index < 0) {
        finishLoad(StorageError(StorageError::InvalidResponse,
                                QStringLiteral("epub 缺少 OPF 文件：%1").arg(opfPath)));
        return;
    }
    m_opfDir = dirOf(opfPath);

    const auto alive = m_alive;
    const quint64 serial = m_serial;
    m_zip->readEntry(
        m_entries.at(index), [this, alive, serial](QByteArray data, StorageError error) {
            if (!*alive || serial != m_serial) {
                return;
            }
            if (!error.isNull()) {
                finishLoad(error);
                return;
            }

            struct Item
            {
                QString href;
                QString properties;
            };
            QHash<QString, Item> manifest;
            QString ncxId;
            /// EPUB2 的封面写法：metadata 里 `<meta name="cover" content="<manifest id>"/>`
            QString coverId;

            QXmlStreamReader xml(data);
            bool inMetadata = false;
            bool inManifest = false;
            while (!xml.atEnd()) {
                xml.readNext();
                if (xml.isStartElement()) {
                    const auto name = xml.name();
                    if (name == QLatin1String("metadata")) {
                        inMetadata = true;
                    } else if (name == QLatin1String("manifest")) {
                        inManifest = true;
                    } else if (name == QLatin1String("title") && inMetadata) {
                        if (m_title.isEmpty()) {
                            m_title = xml.readElementText().trimmed();
                        }
                    } else if (name == QLatin1String("creator") && inMetadata) {
                        if (m_author.isEmpty()) {
                            m_author = xml.readElementText().trimmed();
                        }
                    } else if (name == QLatin1String("language") && inMetadata) {
                        if (m_language.isEmpty()) {
                            m_language = xml.readElementText().trimmed();
                        }
                    } else if (name == QLatin1String("meta") && inMetadata) {
                        if (attrOf(xml, "name") == QLatin1String("cover")) {
                            coverId = attrOf(xml, "content");
                        }
                    } else if (name == QLatin1String("item") && inManifest) {
                        const QString id = attrOf(xml, "id");
                        const QString href = resolveHref(m_opfDir, attrOf(xml, "href"));
                        const QString properties = attrOf(xml, "properties");
                        if (!id.isEmpty() && !href.isEmpty()) {
                            manifest.insert(id, Item{href, properties});
                            const QStringList props = properties.split(QLatin1Char(' '));
                            if (props.contains(QLatin1String("nav"))) {
                                m_navHref = href;
                            }
                            // EPUB3 的封面声明方式；EPUB2 走下面的 metadata meta
                            if (m_coverHref.isEmpty()
                                && props.contains(QLatin1String("cover-image"))) {
                                m_coverHref = href;
                            }
                        }
                    } else if (name == QLatin1String("spine")) {
                        ncxId = attrOf(xml, "toc");
                    } else if (name == QLatin1String("itemref")) {
                        const QString idref = attrOf(xml, "idref");
                        if (!idref.isEmpty()) {
                            m_spine.append(idref);
                        }
                    }
                } else if (xml.isEndElement()) {
                    if (xml.name() == QLatin1String("metadata")) {
                        inMetadata = false;
                    } else if (xml.name() == QLatin1String("manifest")) {
                        inManifest = false;
                    }
                }
            }

            for (const auto &[id, item] : std::as_const(manifest).asKeyValueRange()) {
                m_manifestHref.insert(id, item.href);
            }
            if (!ncxId.isEmpty()) {
                m_ncxHref = m_manifestHref.value(ncxId);
            }
            // EPUB2：metadata 里的 cover 指向 manifest id，manifest 已建好才能反查 href
            if (m_coverHref.isEmpty() && !coverId.isEmpty()) {
                m_coverHref = m_manifestHref.value(coverId);
            }

            if (m_title.isEmpty()) {
                m_title = fileNameTitle(m_opfPath);
            }
            collectToc();
        });
}

void EpubBook::collectToc()
{
    // 目录优先级：EPUB3 NAV → EPUB2 NCX → 无目录（退回 spine 顺序 + 文件名）
    if (!m_navHref.isEmpty()) {
        const int index = RangeZipReader::indexOf(m_entries, m_navHref);
        if (index >= 0) {
            const auto alive = m_alive;
            const quint64 serial = m_serial;
            m_zip->readEntry(m_entries.at(index),
                             [this, alive, serial](QByteArray data, StorageError error) {
                                 if (!*alive || serial != m_serial) {
                                     return;
                                 }
                                 // 目录读不出来不算致命：书还能按 spine 顺序读
                                 if (error.isNull()) {
                                     applyNav(data, dirOf(m_navHref));
                                 }
                                 buildChapters();
                                 finishLoad(StorageError());
                             });
            return;
        }
    }

    if (!m_ncxHref.isEmpty()) {
        const int index = RangeZipReader::indexOf(m_entries, m_ncxHref);
        if (index >= 0) {
            const auto alive = m_alive;
            const quint64 serial = m_serial;
            m_zip->readEntry(m_entries.at(index),
                             [this, alive, serial](QByteArray data, StorageError error) {
                                 if (!*alive || serial != m_serial) {
                                     return;
                                 }
                                 if (error.isNull()) {
                                     applyNcx(data, dirOf(m_ncxHref));
                                 }
                                 buildChapters();
                                 finishLoad(StorageError());
                             });
            return;
        }
    }

    buildChapters();
    finishLoad(StorageError());
}

void EpubBook::applyNav(const QByteArray &navData, const QString &baseDir)
{
    const QString xhtml = decodeMarkup(navData);
    static const QRegularExpression navBlock(
        QStringLiteral("<nav\\b[^>]*epub:type\\s*=\\s*[\"']toc[\"'][^>]*>(.*?)</nav>"),
        QRegularExpression::DotMatchesEverythingOption | QRegularExpression::CaseInsensitiveOption);
    const auto navMatch = navBlock.match(xhtml);
    const QString block = navMatch.hasMatch() ? navMatch.captured(1) : xhtml;

    static const QRegularExpression anchor(
        QStringLiteral("<a\\b[^>]*href\\s*=\\s*[\"']([^\"']*)[\"'][^>]*>(.*?)</a>"),
        QRegularExpression::DotMatchesEverythingOption | QRegularExpression::CaseInsensitiveOption);
    auto it = anchor.globalMatch(block);
    while (it.hasNext()) {
        const auto match = it.next();
        const QString href = resolveHref(baseDir, match.captured(1));
        const QString label = stripTags(match.captured(2));
        if (!href.isEmpty() && !label.isEmpty()) {
            m_tocTitles.insert(href, label);
        }
    }
}

void EpubBook::applyNcx(const QByteArray &ncxData, const QString &baseDir)
{
    QXmlStreamReader xml(ncxData);
    int depth = 0;
    QString label;
    while (!xml.atEnd()) {
        xml.readNext();
        if (xml.isStartElement()) {
            const auto name = xml.name();
            if (name == QLatin1String("navPoint")) {
                ++depth;
            } else if (name == QLatin1String("text") && depth > 0) {
                label = xml.readElementText().trimmed();
            } else if (name == QLatin1String("content") && depth > 0) {
                const QString href = resolveHref(baseDir, attrOf(xml, "src"));
                if (!href.isEmpty() && !label.isEmpty()) {
                    m_tocTitles.insert(href, label);
                }
                label.clear();
            }
        } else if (xml.isEndElement() && xml.name() == QLatin1String("navPoint")) {
            --depth;
        }
    }
}

void EpubBook::buildChapters()
{
    m_chapters.clear();
    QSet<QString> seen;

    const auto appendChapter = [this, &seen](const QString &href) {
        if (href.isEmpty() || seen.contains(href)) {
            return;
        }
        seen.insert(href);
        EpubChapterRef chapter;
        chapter.href = href;
        chapter.title = m_tocTitles.value(href);
        if (chapter.title.isEmpty()) {
            chapter.title = fileNameTitle(href);
        }
        m_chapters.append(chapter);
    };

    for (const QString &idref : std::as_const(m_spine)) {
        appendChapter(m_manifestHref.value(idref));
    }

    // spine 缺失（个别自制 epub）时退化成「所有 xhtml 按名字排序」
    if (m_chapters.isEmpty()) {
        QVector<QString> hrefs;
        for (const ZipEntry &entry : std::as_const(m_entries)) {
            if (entry.isDirectory()) {
                continue;
            }
            const QString lower = entry.name.toLower();
            if (lower.endsWith(QLatin1String(".xhtml")) || lower.endsWith(QLatin1String(".html"))) {
                hrefs.append(entry.name);
            }
        }
        std::sort(hrefs.begin(), hrefs.end());
        for (const QString &href : std::as_const(hrefs)) {
            appendChapter(href);
        }
    }
}

void EpubBook::readChapter(int index, ChapterCallback cb)
{
    Q_ASSERT(cb);
    m_chapterCallback = std::move(cb);
    const quint64 serial = ++m_serial;

    if (index < 0 || index >= m_chapters.size()) {
        finishChapter(
            {},
            StorageError(StorageError::InvalidPath, QStringLiteral("章节序号越界：%1").arg(index)));
        return;
    }
    if (!m_zip) {
        finishChapter({}, StorageError(StorageError::InvalidPath, QStringLiteral("尚未打开 epub")));
        return;
    }

    const QString href = m_chapters.at(index).href;
    const int entryIndex = RangeZipReader::indexOf(m_entries, href);
    if (entryIndex < 0) {
        finishChapter({},
                      StorageError(StorageError::InvalidPath,
                                   QStringLiteral("epub 里缺少章节文件：%1").arg(href)));
        return;
    }

    const auto alive = m_alive;
    m_zip->readEntry(m_entries.at(entryIndex),
                     [this, alive, serial](QByteArray data, StorageError error) {
                         if (!*alive || serial != m_serial) {
                             return;
                         }
                         if (!error.isNull()) {
                             finishChapter({}, error);
                             return;
                         }
                         finishChapter(htmlToParagraphs(decodeMarkup(data)), StorageError());
                     });
}

void EpubBook::readCover(CoverCallback cb)
{
    Q_ASSERT(cb);
    m_coverCallback = std::move(cb);
    const quint64 serial = ++m_coverSerial;

    if (m_coverHref.isEmpty()) {
        finishCover({},
                    StorageError(StorageError::NotFound, QStringLiteral("这部 epub 没有声明封面")));
        return;
    }
    if (!m_zip) {
        finishCover({}, StorageError(StorageError::InvalidPath, QStringLiteral("尚未打开 epub")));
        return;
    }

    const int entryIndex = RangeZipReader::indexOf(m_entries, m_coverHref);
    if (entryIndex < 0) {
        finishCover({},
                    StorageError(StorageError::NotFound,
                                 QStringLiteral("epub 里缺少封面文件：%1").arg(m_coverHref)));
        return;
    }

    const ZipEntry &entry = m_entries.at(entryIndex);
    if (entry.uncompressedSize > kMaxCoverBytes) {
        finishCover(
            {},
            StorageError(StorageError::InvalidResponse,
                         QStringLiteral("封面文件过大：%1 字节").arg(entry.uncompressedSize)));
        return;
    }

    const auto alive = m_alive;
    m_zip->readEntry(entry, [this, alive, serial](QByteArray data, StorageError error) {
        if (!*alive || serial != m_coverSerial) {
            return;
        }
        finishCover(std::move(data), error);
    });
}

void EpubBook::finishLoad(const StorageError &error)
{
    LoadCallback callback = std::move(m_loadCallback);
    m_loadCallback = nullptr;
    if (!callback) {
        return;
    }
    EpubMetadata metadata;
    metadata.title = m_title;
    metadata.author = m_author;
    metadata.language = m_language;
    metadata.chapters = m_chapters;
    callback(std::move(metadata), error);
}

void EpubBook::finishChapter(QStringList paragraphs, const StorageError &error)
{
    ChapterCallback callback = std::move(m_chapterCallback);
    m_chapterCallback = nullptr;
    if (callback) {
        callback(std::move(paragraphs), error);
    }
}

void EpubBook::finishCover(QByteArray bytes, const StorageError &error)
{
    CoverCallback callback = std::move(m_coverCallback);
    m_coverCallback = nullptr;
    if (callback) {
        callback(std::move(bytes), error);
    }
}

QString EpubBook::resolveHref(const QString &baseDir, const QString &href)
{
    QString path = href.section(QLatin1Char('#'), 0, 0).trimmed();
    if (path.isEmpty()) {
        return QString();
    }
    // 外链（http/data）和绝对 URL 都不是 zip 条目
    if (path.contains(QLatin1String("://")) || path.startsWith(QLatin1String("data:"))) {
        return QString();
    }
    path = QUrl::fromPercentEncoding(path.toUtf8());

    const QString combined = path.startsWith(QLatin1Char('/')) ? path.mid(1) : baseDir + path;
    // 归一化 `.` 与 `..`：OPF 里的 href 常写成 ../Text/ch1.xhtml
    QStringList parts;
    const QStringList rawParts = combined.split(QLatin1Char('/'));
    for (const QString &part : rawParts) {
        if (part.isEmpty() || part == QLatin1String(".")) {
            continue;
        }
        if (part == QLatin1String("..")) {
            if (!parts.isEmpty()) {
                parts.removeLast();
            }
            continue;
        }
        parts.append(part);
    }
    return parts.join(QLatin1Char('/'));
}

QStringList EpubBook::htmlToParagraphs(const QString &xhtml)
{
    QString text = xhtml;

    // 源码里的换行/缩进不是段落边界，先压成空格，否则每个缩进都会切出一段
    text.replace(QRegularExpression(QStringLiteral("[\\r\\n\\t]+")), QStringLiteral(" "));

    static const QRegularExpression comment(QStringLiteral("<!--.*?-->"),
                                            QRegularExpression::DotMatchesEverythingOption);
    text.remove(comment);

    // head / script / style 整段摘掉，里面的 CSS 与脚本不是正文
    static const QRegularExpression headLike(
        QStringLiteral("<(head|script|style)\\b[^>]*>.*?</\\1\\s*>"),
        QRegularExpression::DotMatchesEverythingOption | QRegularExpression::CaseInsensitiveOption);
    text.remove(headLike);

    // 块级标签断段：开标签和闭标签都换成换行，避免段尾黏到下一段
    static const QRegularExpression blockOpen(
        QStringLiteral("<\\s*(?:p|div|br|li|h[1-6]|tr|section|article|blockquote|pre|hr)\\b[^>]*>"),
        QRegularExpression::CaseInsensitiveOption);
    text.replace(blockOpen, QStringLiteral("\n"));
    static const QRegularExpression blockClose(
        QStringLiteral("<\\s*/\\s*(?:p|div|li|h[1-6]|tr|section|article|blockquote|pre)\\s*>"),
        QRegularExpression::CaseInsensitiveOption);
    text.replace(blockClose, QStringLiteral("\n"));

    static const QRegularExpression anyTag(QStringLiteral("<[^>]*>"));
    text.remove(anyTag);
    text = decodeEntities(text);

    QStringList paragraphs;
    const QStringList rawLines = text.split(QLatin1Char('\n'));
    paragraphs.reserve(rawLines.size());
    static const QRegularExpression spaces(QStringLiteral("[\\x09\\x0B\\x0C\\x20]+"));
    for (const QString &raw : rawLines) {
        QString line = raw;
        line.replace(spaces, QStringLiteral(" "));
        line = line.trimmed();
        if (!line.isEmpty()) {
            paragraphs.append(line);
        }
    }
    return paragraphs;
}

} // namespace myhub
