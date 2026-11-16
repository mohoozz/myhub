#include "TxtChapterLoader.h"

#include "core/novel/ChapterScan.h"

#include <QStringList>

namespace myhub {

namespace {

/// 去掉首尾空白与全角空格，用于「首行是不是章名」的比较
QString normalized(const QString &text)
{
    QString result = text;
    result.remove(QChar(0xFEFF));
    return result.simplified();
}

/// 把自己截断到「最后一个换行之后」，避免末尾多出半行
void trimToLineEnd(QByteArray *data, TextCodec::Encoding encoding)
{
    if (!data || data->isEmpty()) {
        return;
    }
    if (ChapterTextAlign::unitSize(encoding) == 2) {
        int cut = -1;
        for (int i = data->size() - 2; i >= 0; i -= 2) {
            const quint16 unit = encoding == TextCodec::Utf16BE
                ? static_cast<quint16>((static_cast<quint8>(data->at(i)) << 8)
                                       | static_cast<quint8>(data->at(i + 1)))
                : static_cast<quint16>(static_cast<quint8>(data->at(i))
                                       | (static_cast<quint8>(data->at(i + 1)) << 8));
            if (unit == 0x000A) {
                cut = i + 2;
                break;
            }
        }
        if (cut > 0) {
            data->truncate(cut);
        }
        return;
    }
    const int newline = data->lastIndexOf('\n');
    if (newline >= 0) {
        data->truncate(newline + 1);
    }
}

} // namespace

QString TxtChapterText::bodyText() const
{
    QStringList parts;
    parts.reserve(lines.size());
    for (int i = qMax(0, firstBodyLine); i < lines.size(); ++i) {
        parts.append(lines.at(i).text);
    }
    return parts.join(QLatin1Char('\n'));
}

int TxtChapterText::paragraphCount() const
{
    return qMax(0, lines.size() - qMax(0, firstBodyLine));
}

QStringList TxtChapterText::paragraphs() const
{
    QStringList out;
    out.reserve(paragraphCount());
    for (int i = qMax(0, firstBodyLine); i < lines.size(); ++i) {
        out.append(lines.at(i).text);
    }
    return out;
}

int TxtChapterText::paragraphAtByte(qint64 offset) const
{
    const int base = qMax(0, firstBodyLine);
    if (base >= lines.size()) {
        return -1;
    }
    if (offset < lines.at(base).start) {
        return 0; // 锚点落在章名行/缩进里，从第一段开始看
    }
    for (int i = lines.size() - 1; i >= base; --i) {
        if (offset >= lines.at(i).start) {
            return i - base;
        }
    }
    return 0;
}

qint64 TxtChapterText::byteAtParagraph(int index) const
{
    const int base = qMax(0, firstBodyLine);
    const int line = base + index;
    if (index < 0 || line >= lines.size()) {
        return -1;
    }
    return lines.at(line).start;
}

QVector<TxtLine> TxtChapterLoader::parseLines(const QByteArray &data, qint64 baseOffset,
                                              TextCodec::Encoding encoding)
{
    QVector<TxtLine> lines;
    if (data.isEmpty()) {
        return lines;
    }

    ChapterLineScanner scanner(encoding);
    // scanner 给出的 start/end 是**块内相对**偏移，对外必须换算成文件绝对偏移
    const auto collect = [&lines, encoding, baseOffset](const char *bytes, qint64 start,
                                                        qint64 end) {
        TxtLine line;
        line.start = baseOffset + start;
        line.end = baseOffset + end;
        const QByteArray raw(bytes, static_cast<int>(end - start));
        line.text = TextCodec::decodeAs(raw, encoding).text;
        // 只去行尾空白：行首缩进是排版信息，不能动
        while (!line.text.isEmpty() && line.text.at(line.text.size() - 1).isSpace()) {
            line.text.chop(1);
        }
        lines.append(line);
    };

    scanner.append(data, collect);
    scanner.finish(collect);

    // 文件末尾的空行不占版面：不去掉的话最后一页会有一半是空白
    while (!lines.isEmpty() && lines.constLast().text.trimmed().isEmpty()) {
        lines.removeLast();
    }
    return lines;
}

TxtChapterText TxtChapterLoader::parseChapter(const QByteArray &data, qint64 baseOffset,
                                              TextCodec::Encoding encoding, const QString &title)
{
    TxtChapterText chapter;
    chapter.title = title;
    chapter.encoding = encoding;
    chapter.start = baseOffset;
    chapter.end = baseOffset + data.size();
    chapter.lines = parseLines(data, baseOffset, encoding);

    if (!title.isEmpty() && !chapter.lines.isEmpty()
        && normalized(chapter.lines.constFirst().text) == normalized(title)) {
        chapter.firstBodyLine = 1; // 章名行已经作为标题渲染过，正文里不再重复
    }
    return chapter;
}

void TxtChapterLoader::load(RangeSource *source, const NovelIndex &index, int chapter,
                            std::function<void(TxtChapterText, StorageError)> callback,
                            qint64 maxBytes)
{
    if (!source || !callback) {
        return;
    }
    if (!index.isValid() || chapter < 0 || chapter >= index.count()) {
        callback(TxtChapterText(),
                 StorageError(StorageError::InvalidPath, QStringLiteral("章节目录为空或下标越界")));
        return;
    }

    const qint64 start = index.chapterStart(chapter);
    const qint64 end = index.chapterEnd(chapter);
    qint64 length = end - start;
    if (length <= 0) {
        callback(TxtChapterText(),
                 StorageError(StorageError::InvalidPath, QStringLiteral("章节区间非法")));
        return;
    }

    const bool truncated = length > maxBytes;
    if (truncated) {
        length = maxBytes;
    }

    const QString title = index.chapterTitle(chapter);
    const TextCodec::Encoding encoding = index.encoding;

    source->readRange(
        start, length,
        [callback, start, encoding, title, truncated](QByteArray data, StorageError error) {
            if (!error.isNull()) {
                callback(TxtChapterText(), error);
                return;
            }
            if (data.isEmpty()) {
                callback(TxtChapterText(),
                         StorageError(StorageError::InvalidResponse,
                                      QStringLiteral("章节内容为空：文件可能已被修改")));
                return;
            }

            // 章节起点来自行边界，正常情况下不需要对齐；这里兜的「外部传入任意偏移」
            qint64 chapterStart = start;
            const int skip = ChapterTextAlign::headSkip(data, encoding);
            if (skip > 0 && skip < data.size()) {
                data.remove(0, skip);
                chapterStart += skip;
            }
            if (truncated) {
                trimToLineEnd(&data, encoding);
            }

            TxtChapterText text = parseChapter(data, chapterStart, encoding, title);
            text.truncated = truncated;
            callback(text, StorageError());
        });
}

} // namespace myhub
