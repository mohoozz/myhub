#include "ChapterScan.h"

#include <QStringDecoder>

#include <cstring>

namespace myhub {

namespace {

/// 一行超过这个长度还没换行 → 基本可以断定不是文本（二进制/日志），
/// 直接当一行交出去，避免把整个文件读进内存
constexpr int kMaxLineBytes = 1 << 20;

const QByteArray &utf8Bom()
{
    static const QByteArray bom("\xEF\xBB\xBF", 3);
    return bom;
}

/// 读一个代码单元（不检查边界，调用方保证 size 够）
quint16 unitAt(const char *data, qint64 offset, TextCodec::Encoding encoding)
{
    const auto *bytes = reinterpret_cast<const uchar *>(data + offset);
    if (encoding == TextCodec::Utf16BE) {
        return static_cast<quint16>((bytes[0] << 8) | bytes[1]);
    }
    return static_cast<quint16>(bytes[0] | (bytes[1] << 8));
}

/// 行首缩进的字节表示（含全角空格）。GBK 的全角空格是 A1 A1，Big5 是 A1 40，
/// UTF-8 是 E3 80 80 —— 都是 2~3 字节，不能按「跳过 0x20」一概而论。
QVector<QByteArray> spacePrefixes(TextCodec::Encoding encoding)
{
    switch (encoding) {
    case TextCodec::Utf16LE:
        return {QByteArray("\x20\x00", 2), QByteArray("\x09\x00", 2), QByteArray("\x00\x30", 2),
                QByteArray("\x00\xA0", 2)};
    case TextCodec::Utf16BE:
        return {QByteArray("\x00\x20", 2), QByteArray("\x00\x09", 2), QByteArray("\x30\x00", 2),
                QByteArray("\xA0\x00", 2)};
    case TextCodec::Gb18030:
        return {QByteArray(" ", 1), QByteArray("\x09", 1), QByteArray("\xA1\xA1", 2)};
    case TextCodec::Big5:
        return {QByteArray(" ", 1), QByteArray("\x09", 1), QByteArray("\xA1\x40", 2)};
    default:
        return {QByteArray(" ", 1), QByteArray("\x09", 1), QByteArray("\xE3\x80\x80", 3),
                QByteArray("\xC2\xA0", 2)};
    }
}

/// 换行符的查找：1 字节编码找 '\n'，UTF-16 找 0x000A 单元
int findNewline(const QByteArray &buffer, int from, int limit, TextCodec::Encoding encoding)
{
    if (encoding == TextCodec::Utf16LE || encoding == TextCodec::Utf16BE) {
        for (int i = from; i + 2 <= limit; i += 2) {
            if (unitAt(buffer.constData(), i, encoding) == 0x000A) {
                return i;
            }
        }
        return -1;
    }
    const char *found = static_cast<const char *>(
        std::memchr(buffer.constData() + from, '\n', static_cast<size_t>(limit - from)));
    return found ? static_cast<int>(found - buffer.constData()) : -1;
}

/// 行尾若是 \r（UTF-16 则是 000D 单元），去掉它
int trimCarriageReturn(const QByteArray &buffer, int start, int end, TextCodec::Encoding encoding)
{
    if (encoding == TextCodec::Utf16LE || encoding == TextCodec::Utf16BE) {
        if (end - start >= 2 && unitAt(buffer.constData(), end - 2, encoding) == 0x000D) {
            return end - 2;
        }
        return end;
    }
    if (end > start && buffer.at(end - 1) == '\r') {
        return end - 1;
    }
    return end;
}

} // namespace

// ---------------------------------------------------------------- ChapterTextAlign

int ChapterTextAlign::unitSize(TextCodec::Encoding encoding)
{
    return (encoding == TextCodec::Utf16LE || encoding == TextCodec::Utf16BE) ? 2 : 1;
}

int ChapterTextAlign::headSkip(const QByteArray &data, TextCodec::Encoding encoding)
{
    if (data.isEmpty()) {
        return 0;
    }

    if (encoding == TextCodec::Utf8 || encoding == TextCodec::Unknown) {
        // 续接字节只可能出现在「被切开的字符」中间
        int skip = 0;
        while (skip < 3 && skip < data.size()
               && (static_cast<quint8>(data.at(skip)) & 0xC0) == 0x80) {
            ++skip;
        }
        return skip;
    }

    if (unitSize(encoding) == 2) {
        if (data.size() < 2) {
            return data.size();
        }
        const quint16 first = unitAt(data.constData(), 0, encoding);
        if (first >= 0xDC00 && first <= 0xDFFF) {
            return 2; // 低位代理单独出现：它的高位在前一块末尾
        }
        return 0;
    }

    // GB18030 / Big5：不做试探（见头文件说明）
    return 0;
}

int ChapterTextAlign::tailDrop(const QByteArray &data, TextCodec::Encoding encoding)
{
    if (data.isEmpty()) {
        return 0;
    }

    if (encoding == TextCodec::Utf8 || encoding == TextCodec::Unknown) {
        int lead = data.size() - 1;
        int back = 0;
        while (lead >= 0 && back < 3 && (static_cast<quint8>(data.at(lead)) & 0xC0) == 0x80) {
            --lead;
            ++back;
        }
        if (lead < 0) {
            return 0;
        }
        const quint8 first = static_cast<quint8>(data.at(lead));
        int need = 0;
        if (first < 0x80) {
            need = 1;
        } else if ((first & 0xE0) == 0xC0) {
            need = 2;
        } else if ((first & 0xF0) == 0xE0) {
            need = 3;
        } else if ((first & 0xF8) == 0xF0) {
            need = 4;
        } else {
            return 0; // 非法首字节：交给解码器的替换符兜底
        }
        const int have = static_cast<int>(data.size()) - lead;
        return have < need ? have : 0;
    }

    if (unitSize(encoding) == 2) {
        if (data.size() % 2 != 0) {
            return 1; // 半个代码单元
        }
        const quint16 last = unitAt(data.constData(), data.size() - 2, encoding);
        if (last >= 0xD800 && last <= 0xDBFF) {
            return 2; // 高位代理没有配对的低位
        }
        return 0;
    }

    // GB18030 / Big5：不做试探（见头文件说明）
    return 0;
}

QByteArray ChapterTextAlign::trimIncompleteUtf8Tail(const QByteArray &data)
{
    const int drop = tailDrop(data, TextCodec::Utf8);
    if (drop <= 0) {
        return data;
    }
    return data.left(data.size() - drop);
}

// ---------------------------------------------------------------- ChapterMatcher

ChapterMatcher::ChapterMatcher(TextCodec::Encoding encoding)
    : m_encoding(encoding == TextCodec::Unknown ? TextCodec::Utf8 : encoding)
    , m_unit(ChapterTextAlign::unitSize(encoding))
    , m_spacePrefixes(spacePrefixes(m_encoding))
{
    const QVector<ChapterRule> &rules = ChapterRules::rules();
    m_firstBytes.resize(rules.size());
    m_firstUnits.resize(rules.size());
    m_filterEnabled.resize(rules.size());

    for (int i = 0; i < rules.size(); ++i) {
        const ChapterRule &rule = rules.at(i);
        if (rule.firstChars.isEmpty()) {
            m_filterEnabled[i] = false; // 没给首字符集：只能全量解码
            continue;
        }
        m_filterEnabled[i] = true;
        for (const QChar ch : rule.firstChars) {
            if (m_unit == 2) {
                m_firstUnits[i].insert(ch.unicode());
                continue;
            }
            const TextCodec::Encoded encoded = TextCodec::encode(QString(ch), m_encoding);
            if (encoded.fellBackToUtf8 || encoded.data.isEmpty()) {
                // 该字符在目标编码里表示不出来 → 预筛不可信，这条规则只能全量匹配
                m_filterEnabled[i] = false;
                break;
            }
            m_firstBytes[i].set(static_cast<quint8>(encoded.data.at(0)));
        }
    }
}

int ChapterMatcher::bomLength(const char *data, qint64 size) const
{
    if (size >= 3 && std::memcmp(data, utf8Bom().constData(), 3) == 0 && m_unit == 1
        && m_encoding != TextCodec::Gb18030 && m_encoding != TextCodec::Big5) {
        return 3;
    }
    if (size >= 2) {
        const quint16 first = unitAt(data, 0, m_encoding);
        if (m_encoding == TextCodec::Utf16LE && first == 0xFEFF) {
            return 2;
        }
        if (m_encoding == TextCodec::Utf16BE && first == 0xFEFF) {
            return 2;
        }
    }
    return 0;
}

int ChapterMatcher::indentLength(const char *data, qint64 size) const
{
    qint64 offset = 0;
    bool matched = true;
    while (matched && offset < size) {
        matched = false;
        for (const QByteArray &prefix : m_spacePrefixes) {
            if (size - offset >= prefix.size()
                && std::memcmp(data + offset, prefix.constData(),
                               static_cast<size_t>(prefix.size()))
                    == 0) {
                offset += prefix.size();
                matched = true;
                break;
            }
        }
    }
    return static_cast<int>(offset);
}

bool ChapterMatcher::passesFilter(int ruleIndex, const char *data, qint64 size) const
{
    if (!m_filterEnabled.at(ruleIndex)) {
        return true;
    }
    if (size <= 0) {
        return false;
    }
    if (m_unit == 2) {
        if (size < 2) {
            return false;
        }
        return m_firstUnits.at(ruleIndex).contains(unitAt(data, 0, m_encoding));
    }
    return m_firstBytes.at(ruleIndex).test(static_cast<quint8>(data[0]));
}

QString ChapterMatcher::decodeLine(const char *data, qint64 size) const
{
    const QByteArray bytes(data, static_cast<int>(size));
    return TextCodec::decodeAs(bytes, m_encoding).text;
}

std::optional<ChapterMatcher::Hit> ChapterMatcher::match(const char *data, qint64 size) const
{
    if (size <= 0) {
        return std::nullopt;
    }
    const qint64 bom = bomLength(data, size);
    if (bom >= size) {
        return std::nullopt;
    }
    const char *body = data + bom;
    const qint64 bodySize = size - bom;

    // 缩进不参与匹配：「　　第一章 初入宗门」是中文 txt 最常见的排版，
    // 规则只管内容，否则一半的文件会「识别不出章节」
    const qint64 indent = indentLength(body, bodySize);
    const qint64 contentSize = bodySize - indent;
    if (contentSize <= 0) {
        return std::nullopt;
    }
    const qint64 firstByteOffset = bom + indent;

    const QVector<ChapterRule> &rules = ChapterRules::rules();
    for (int i = 0; i < rules.size(); ++i) {
        if (!passesFilter(i, data + firstByteOffset, size - firstByteOffset)) {
            continue;
        }
        const ChapterRule &rule = rules.at(i);
        const QString line = decodeLine(data + firstByteOffset, size - firstByteOffset).trimmed();
        if (line.isEmpty()) {
            continue;
        }
        const QRegularExpressionMatch found =
            rule.regex.match(line, 0, QRegularExpression::NormalMatch,
                             QRegularExpression::AnchorAtOffsetMatchOption);
        if (!found.hasMatch()) {
            continue;
        }
        Hit hit;
        hit.title = found.captured(0).trimmed();
        if (hit.title.isEmpty()) {
            hit.title = line;
        }
        hit.ruleId = rule.id;
        return hit;
    }
    return std::nullopt;
}

// ---------------------------------------------------------------- ChapterLineScanner

ChapterLineScanner::ChapterLineScanner(TextCodec::Encoding encoding)
    : m_encoding(encoding == TextCodec::Unknown ? TextCodec::Utf8 : encoding)
    , m_unit(ChapterTextAlign::unitSize(encoding))
{}

void ChapterLineScanner::append(const QByteArray &chunk, const LineCallback &onLine)
{
    if (m_buffer.isEmpty()) {
        m_bufferStart = m_consumed;
    }
    m_buffer.append(chunk);
    m_consumed += chunk.size();

    // UTF-16：总量为奇数时，末尾 1 字节构不成代码单元，留给下一块
    int limit = static_cast<int>(m_buffer.size());
    if (m_unit == 2 && limit % 2 != 0) {
        --limit;
    }

    int lineStart = 0;
    while (lineStart < limit) {
        const int newline = findNewline(m_buffer, lineStart, limit, m_encoding);
        if (newline < 0) {
            break;
        }
        const int lineEnd = trimCarriageReturn(m_buffer, lineStart, newline, m_encoding);
        onLine(m_buffer.constData() + lineStart, m_bufferStart + lineStart,
               m_bufferStart + lineEnd);
        lineStart = newline + m_unit;
    }

    if (lineStart > 0) {
        m_buffer.remove(0, lineStart);
        m_bufferStart += lineStart;
    }

    // 超长无换行（二进制文件被当成 txt 打开）：不再攒内存，当一行交出去
    if (m_buffer.size() > kMaxLineBytes) {
        onLine(m_buffer.constData(), m_bufferStart, m_bufferStart + m_buffer.size());
        m_bufferStart += m_buffer.size();
        m_buffer.clear();
    }
}

void ChapterLineScanner::finish(const LineCallback &onLine)
{
    if (m_buffer.isEmpty()) {
        return;
    }
    const int end = trimCarriageReturn(m_buffer, 0, static_cast<int>(m_buffer.size()), m_encoding);
    onLine(m_buffer.constData(), m_bufferStart, m_bufferStart + end);
    m_bufferStart += m_buffer.size();
    m_buffer.clear();
}

} // namespace myhub
