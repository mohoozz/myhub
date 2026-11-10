#include "TextCodec.h"

#include <QStringDecoder>
#include <QStringEncoder>
#include <QVector>

#ifdef Q_OS_WIN
#include <windows.h>
#elif defined(Q_OS_MACOS)
#include <CoreFoundation/CoreFoundation.h>
#endif

namespace myhub {

namespace {

const QByteArray &utf8Bom()
{
    static const QByteArray bom = QByteArray::fromHex("EFBBBF");
    return bom;
}
const QByteArray &utf16LeBom()
{
    static const QByteArray bom = QByteArray::fromHex("FFFE");
    return bom;
}
const QByteArray &utf16BeBom()
{
    static const QByteArray bom = QByteArray::fromHex("FEFF");
    return bom;
}

/**
 * 常用字表：仅用于 GB18030 / Big5 的**择优打分**（错解出来多是生僻字串）。
 *
 * 两类编码的双字节区间大量重叠（如 A4 40 两边都合法），「能否解码」无法区分；
 * 命中率能把真实文本与乱码拉开数量级差距，表不必完备。
 */
const QString &commonChars()
{
    static const QString s = QStringLiteral(
        "的一是不了在人有我他这个们中来上大为和国地到以说时要就出会可也你对生能而子那得"
        "于着下自之年过发后作里用道行所然家种事成方多经去法学如都同现当没动面起看定天分"
        "还进好小部其些主样理心她本前开但因只从想实日军者意无力它与长把机十民第公此已工"
        "使情明性知全三又关点正业外将两高间由问很最重并物手应战向头文体政美相见被利什二"
        "等产或新己制身果加西斯月话合回特代内信表化老给世位次度门任常先海通教儿原东声提"
        "立及比员解水名真论处走义各入几口认条平系气题活尔更别打女变四神总何电数安少报才"
        "结反受目太量再感建务做接必场件计管期市直德资命山金指克许统区保至队形社便空决治"
        "展马科司五基眼书非则听白却界达光放强即像难且权思王象完设式色路记南品住告类求据"
        "程北边死张该交规万取拉格望觉术领共确传师观清今切院让识候带导争运笑飞风步改收根"
        "干造言联持组每济车亲极林服快办议往元英士证近失转夫令准布始怎呢存未远叫台单影具"
        "罗字爱击流备兵连调深商算质团集百需价花党华城石级整府离况亚请技际约示复病息究线"
        "似官火断精满支视消越器容照须九增研写称企八功吗包片史委乎查轻易早曾除农找装广显"
        "這們來為國說時會對於著過發後裡學現當沒還進樣開從實軍無與長機關點業將兩間問並應"
        "戰頭體見產語給東聲員處義認條氣題變總電報結場計區隊書則聽達強難權設類據規萬覺領"
        "傳師觀讓帶導爭風辦議證轉準單羅擊備連質價黨華級離請復線斷視須寫嗎圖歷醫專費號盡"
        "較僅隨選紅響雖參眾構節劃陳態護興驗責營夠嚴續講終緊絕");
    return s;
}

/// 常用字命中分（错解乱码命中极少）
int commonScore(const QString &text)
{
    const QString &table = commonChars();
    int score = 0;
    for (const QChar ch : text) {
        if (ch == QChar(0xFFFD)) {
            score -= 10; // 替换符：解码没完全成功
            continue;
        }
        if (ch.unicode() < 0x80) {
            continue; // ASCII 两边一致，不参与区分
        }
        if (table.contains(ch)) {
            score += 4;
        } else if (ch.unicode() >= 0x4E00 && ch.unicode() <= 0x9FFF) {
            score += 1;
        }
    }
    return score;
}

/// 双字节序列中「低位 < 0x80」的比例（×100）：Big5 常见汉字大量落此区间，GBK 极少
int trailingAsciiPercent(const QByteArray &data)
{
    int pairs = 0;
    int asciiTrail = 0;
    for (int i = 0; i + 1 < data.size(); ++i) {
        const auto lead = static_cast<unsigned char>(data.at(i));
        if (lead < 0x81 || lead > 0xFE) {
            continue;
        }
        const auto trail = static_cast<unsigned char>(data.at(i + 1));
        ++pairs;
        if (trail < 0x80) {
            ++asciiTrail;
        }
        ++i;
    }
    return pairs == 0 ? 0 : asciiTrail * 100 / pairs;
}

bool looksLikeUtf16(const QByteArray &data, bool *littleEndian)
{
    if (data.size() < 4 || data.size() % 2 != 0) {
        return false;
    }
    const int units = data.size() / 2;
    int evenZeros = 0;
    int oddZeros = 0;
    for (int i = 0; i < units; ++i) {
        if (data.at(qsizetype(i) * 2) == '\0') {
            ++evenZeros;
        }
        if (data.at(qsizetype(i) * 2 + 1) == '\0') {
            ++oddZeros;
        }
    }
    if (oddZeros * 3 > units && evenZeros * 10 < units) {
        *littleEndian = true;
        return true;
    }
    if (evenZeros * 3 > units && oddZeros * 10 < units) {
        *littleEndian = false;
        return true;
    }
    return false;
}

QString decodeAs(const QByteArray &data, const char *codec, bool *hadErrors)
{
    QStringDecoder decoder(codec);
    if (!decoder.isValid()) {
        if (hadErrors) {
            *hadErrors = true;
        }
        return {};
    }
    QString text = decoder.decode(data);
    if (hadErrors) {
        *hadErrors = decoder.hasError();
    }
    return text;
}

/// GB18030 / Big5：Qt 未内置这两族（无 ICU 时 QStringConverter 不支持），走平台转码
bool decodeMultibyte(const QByteArray &data, TextCodec::Encoding encoding, QString *text,
                     bool *hadErrors)
{
    if (data.isEmpty()) {
        text->clear();
        return true;
    }
#ifdef Q_OS_WIN
    const UINT codePage = encoding == TextCodec::Gb18030 ? 54936 : 950; // GB18030 / Big5
    int units = ::MultiByteToWideChar(codePage, MB_ERR_INVALID_CHARS, data.constData(), data.size(),
                                      nullptr, 0);
    if (units <= 0) {
        if (hadErrors) {
            *hadErrors = true; // 含非法字节：转宽松模式，由调用方决定是否采信
        }
        units = ::MultiByteToWideChar(codePage, 0, data.constData(), data.size(), nullptr, 0);
    }
    if (units <= 0) {
        return false;
    }
    QVector<wchar_t> buffer(units);
    const int written =
        ::MultiByteToWideChar(codePage, 0, data.constData(), data.size(), buffer.data(), units);
    if (written <= 0) {
        return false;
    }
    *text = QString::fromWCharArray(buffer.constData(), written);
    return true;
#elif defined(Q_OS_MACOS)
    const CFStringEncoding cfEncoding =
        encoding == TextCodec::Gb18030 ? kCFStringEncodingGB_18030_2000 : kCFStringEncodingBig5;
    CFStringRef string = CFStringCreateWithBytes(kCFAllocatorDefault,
                                                 reinterpret_cast<const UInt8 *>(data.constData()),
                                                 data.size(), cfEncoding, false);
    if (!string) {
        if (hadErrors) {
            *hadErrors = true;
        }
        return false;
    }
    const CFIndex length = CFStringGetLength(string);
    QVector<UniChar> buffer(length);
    CFStringGetCharacters(string, CFRangeMake(0, length), buffer.data());
    *text = QString::fromUtf16(reinterpret_cast<const char16_t *>(buffer.constData()), length);
    CFRelease(string);
    return true;
#else
    Q_UNUSED(data)
    Q_UNUSED(encoding)
    Q_UNUSED(text)
    Q_UNUSED(hadErrors)
    return false;
#endif
}

bool encodeMultibyte(const QString &text, TextCodec::Encoding encoding, QByteArray *data)
{
    if (text.isEmpty()) {
        data->clear();
        return true;
    }
#ifdef Q_OS_WIN
    const UINT codePage = encoding == TextCodec::Gb18030 ? 54936 : 950;
    const auto *wide = reinterpret_cast<const wchar_t *>(text.utf16());
    const int bytes =
        ::WideCharToMultiByte(codePage, 0, wide, text.size(), nullptr, 0, nullptr, nullptr);
    if (bytes <= 0) {
        return false;
    }
    QByteArray buffer(bytes, Qt::Uninitialized);
    const int written = ::WideCharToMultiByte(codePage, 0, wide, text.size(), buffer.data(), bytes,
                                              nullptr, nullptr);
    if (written <= 0) {
        return false;
    }
    buffer.resize(written);
    *data = buffer;
#elif defined(Q_OS_MACOS)
    const CFStringEncoding cfEncoding =
        encoding == TextCodec::Gb18030 ? kCFStringEncodingGB_18030_2000 : kCFStringEncodingBig5;
    CFStringRef string = CFStringCreateWithCharacters(
        kCFAllocatorDefault, reinterpret_cast<const UniChar *>(text.utf16()), text.size());
    if (!string) {
        return false;
    }
    const CFIndex capacity = text.size() * 4 + 16;
    QByteArray buffer(capacity, Qt::Uninitialized);
    CFIndex usedBytes = 0;
    Boolean lossy = false;
    const CFIndex converted =
        CFStringGetBytes(string, CFRangeMake(0, text.size()), cfEncoding, 0, false,
                         reinterpret_cast<UInt8 *>(buffer.data()), capacity, &usedBytes, &lossy);
    CFRelease(string);
    if (converted == 0 || lossy) {
        return false;
    }
    buffer.resize(usedBytes);
    *data = buffer;
#else
    Q_UNUSED(text)
    Q_UNUSED(encoding)
    Q_UNUSED(data)
    return false;
#endif

    // 统一用「回读比对」判定是否无损：Windows 的 CP54936 对 lpUsedDefaultChar 上报不可靠
    // （合法的 GB18030 汉字也可能置位），故不依赖它，直接解码回来比一遍。
    QString roundTrip;
    bool errored = false;
    if (!decodeMultibyte(*data, encoding, &roundTrip, &errored) || errored) {
        return false;
    }
    return roundTrip == text;
}

TextCodec::Decoded decodeBody(const QByteArray &body, TextCodec::Encoding encoding, bool hadBom)
{
    TextCodec::Decoded decoded;
    decoded.encoding = encoding;
    decoded.hadBom = hadBom;
    bool errored = false;
    switch (encoding) {
    case TextCodec::Utf16LE:
        decoded.text = decodeAs(body, "UTF-16LE", &errored);
        decoded.hadErrors = errored;
        break;
    case TextCodec::Utf16BE:
        decoded.text = decodeAs(body, "UTF-16BE", &errored);
        decoded.hadErrors = errored;
        break;
    case TextCodec::Gb18030:
    case TextCodec::Big5:
        if (!decodeMultibyte(body, encoding, &decoded.text, &errored)) {
            decoded.text = decodeAs(body, "UTF-8", &errored);
            decoded.encoding = TextCodec::Utf8;
            decoded.hadErrors = true;
            break;
        }
        decoded.hadErrors = errored;
        break;
    default:
        decoded.text = decodeAs(body, "UTF-8", &errored);
        decoded.encoding = TextCodec::Utf8;
        decoded.hadErrors = errored;
        break;
    }
    return decoded;
}

} // namespace

QString TextCodec::name(Encoding encoding)
{
    switch (encoding) {
    case Utf8:
        return QStringLiteral("UTF-8");
    case Utf16LE:
        return QStringLiteral("UTF-16 LE");
    case Utf16BE:
        return QStringLiteral("UTF-16 BE");
    case Gb18030:
        return QStringLiteral("GB18030");
    case Big5:
        return QStringLiteral("Big5");
    case Unknown:
        break;
    }
    return QStringLiteral("UTF-8");
}

TextCodec::Encoding TextCodec::fromName(const QString &name)
{
    const QString key = name.trimmed().toUpper().remove(QLatin1Char(' ')).remove(QLatin1Char('-'));
    if (key == QLatin1String("UTF8")) {
        return Utf8;
    }
    if (key == QLatin1String("UTF16LE")) {
        return Utf16LE;
    }
    if (key == QLatin1String("UTF16BE")) {
        return Utf16BE;
    }
    if (key == QLatin1String("GB18030") || key == QLatin1String("GBK")
        || key == QLatin1String("GB2312")) {
        return Gb18030;
    }
    if (key == QLatin1String("BIG5")) {
        return Big5;
    }
    return Unknown;
}

TextCodec::Encoding TextCodec::detect(const QByteArray &data)
{
    return decode(data).encoding;
}

TextCodec::Decoded TextCodec::decode(const QByteArray &data)
{
    if (data.isEmpty()) {
        Decoded empty;
        empty.encoding = Utf8;
        return empty;
    }

    // 1) BOM 优先：字节序确定，不再猜
    if (data.startsWith(utf8Bom())) {
        return decodeBody(data.mid(utf8Bom().size()), Utf8, true);
    }
    if (data.startsWith(utf16LeBom())) {
        return decodeBody(data.mid(utf16LeBom().size()), Utf16LE, true);
    }
    if (data.startsWith(utf16BeBom())) {
        return decodeBody(data.mid(utf16BeBom().size()), Utf16BE, true);
    }

    // 2) 无 BOM 的 UTF-16：零字节集中在同一侧
    bool littleEndian = false;
    if (looksLikeUtf16(data, &littleEndian)) {
        const Decoded candidate = decodeBody(data, littleEndian ? Utf16LE : Utf16BE, false);
        if (!candidate.hadErrors) {
            return candidate;
        }
    }

    // 3) 严格 UTF-8：非法即不是 UTF-8（纯 ASCII 也走这里，两侧等价）
    bool utf8Errored = false;
    const QString utf8Text = decodeAs(data, "UTF-8", &utf8Errored);
    if (!utf8Errored) {
        Decoded decoded;
        decoded.text = utf8Text;
        decoded.encoding = Utf8;
        return decoded;
    }

    // 4) GB18030 / Big5：能否解码 + 常用字命中率择优
    bool gbError = false;
    bool big5Error = false;
    QString gbText;
    QString big5Text;
    const bool gbOk = decodeMultibyte(data, Gb18030, &gbText, &gbError) && !gbError;
    const bool big5Ok = decodeMultibyte(data, Big5, &big5Text, &big5Error) && !big5Error;

    if (gbOk && !big5Ok) {
        return decodeBody(data, Gb18030, false);
    }
    if (big5Ok && !gbOk) {
        return decodeBody(data, Big5, false);
    }
    if (gbOk && big5Ok) {
        const int gbScore = commonScore(gbText);
        const int big5Score = commonScore(big5Text);
        if (big5Score > gbScore) {
            return decodeBody(data, Big5, false);
        }
        if (big5Score == gbScore && trailingAsciiPercent(data) > 15) {
            return decodeBody(data, Big5, false);
        }
        return decodeBody(data, Gb18030, false);
    }

    // 5) 都解不开：UTF-8 带替换符兜底（宁可显示乱码，也不拒绝打开）
    Decoded fallback;
    fallback.text = decodeAs(data, "UTF-8", nullptr);
    fallback.encoding = Utf8;
    fallback.hadErrors = true;
    return fallback;
}

bool TextCodec::canEncode(const QString &text, Encoding encoding)
{
    if (encoding == Utf8 || encoding == Utf16LE || encoding == Utf16BE) {
        return true;
    }
    QByteArray discarded;
    return encodeMultibyte(text, encoding, &discarded);
}

TextCodec::Encoded TextCodec::encode(const QString &text, Encoding encoding, bool withBom)
{
    Encoded encoded;
    QByteArray body;

    switch (encoding) {
    case Utf16LE:
    case Utf16BE: {
        QStringEncoder encoder(encoding == Utf16LE ? "UTF-16LE" : "UTF-16BE");
        if (!encoder.isValid()) {
            encoded.fellBackToUtf8 = true;
            encoded.data = text.toUtf8();
            return encoded;
        }
        body = encoder(text);
        if (encoder.hasError()) {
            encoded.fellBackToUtf8 = true;
            encoded.data = text.toUtf8();
            return encoded;
        }
        if (withBom) {
            encoded.data = (encoding == Utf16LE ? utf16LeBom() : utf16BeBom()) + body;
        } else {
            encoded.data = body;
        }
        encoded.encoding = encoding;
        return encoded;
    }
    case Gb18030:
    case Big5: {
        if (!encodeMultibyte(text, encoding, &body)) {
            // 纪律：原编码表示不了 → 回退 UTF-8（不写问号、不静默丢字）
            encoded.encoding = Utf8;
            encoded.fellBackToUtf8 = true;
            encoded.data = text.toUtf8();
            return encoded;
        }
        encoded.encoding = encoding;
        encoded.data = body; // GB18030/Big5 没有 BOM 概念
        return encoded;
    }
    default: {
        body = text.toUtf8();
        encoded.encoding = Utf8;
        encoded.data = withBom ? utf8Bom() + body : body;
        return encoded;
    }
    }
}

} // namespace myhub
