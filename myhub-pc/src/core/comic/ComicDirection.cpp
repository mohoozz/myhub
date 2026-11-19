#include "core/comic/ComicDirection.h"

#include <QRegularExpression>
#include <QVector>

namespace myhub {
namespace {

/// 平假名 / 片假名 / 半角片假名：出现即按日文作品处理
bool hasKana(const QString &text)
{
    for (const QChar ch : text) {
        const ushort code = ch.unicode();
        if ((code >= 0x3040 && code <= 0x30FF) || (code >= 0xFF66 && code <= 0xFF9D)) {
            return true;
        }
    }
    return false;
}

/// 一次性编译，避免每本书都重建正则
struct Matcher
{
    QRegularExpression pattern;
    ComicDirection direction;
};

const QVector<Matcher> &explicitMatchers()
{
    static const QVector<Matcher> table{
        // 发布者自己写明了方向：最可信，排在假名之前（日文标题也可能带「左→右」）
        {QRegularExpression(
             QStringLiteral(
                 "右\\s*[→>\\-–]*\\s*左|从右向左|從右向左|right[\\s_-]*to[\\s_-]*left|\\brtl\\b"),
             QRegularExpression::CaseInsensitiveOption),
         ComicDirection::RightToLeft},
        {QRegularExpression(
             QStringLiteral(
                 "左\\s*[→>\\-–]*\\s*右|从左向右|從左向右|left[\\s_-]*to[\\s_-]*right|\\bltr\\b"),
             QRegularExpression::CaseInsensitiveOption),
         ComicDirection::LeftToRight},
    };
    return table;
}

const QVector<Matcher> &japaneseMatchers()
{
    static const QVector<Matcher> table{
        // 巻 / 話（繁体）是日文写法；简体「话」归中韩那组
        {QRegularExpression(QStringLiteral("第\\s*\\d+\\s*[巻話]")), ComicDirection::RightToLeft},
        {QRegularExpression(
             QStringLiteral("巻|同人|コミック|サークル|成年向|単行本|エロ|DL版|分冊版")),
         ComicDirection::RightToLeft},
        // 同人展会标签 (C99) / [C102]：只有日系同人本会这么写
        {QRegularExpression(QStringLiteral("[（(\\[]\\s*[Cc]\\d{2,3}\\s*[)）\\]]")),
         ComicDirection::RightToLeft},
    };
    return table;
}

const QVector<Matcher> &chineseKoreanMatchers()
{
    static const QVector<Matcher> table{
        // 现代条漫一律从左向右；第 N 话（简体）是中文/韩漫写法
        {QRegularExpression(QStringLiteral("条漫|條漫|webtoon|国漫|國漫|韩漫|韓漫"),
                            QRegularExpression::CaseInsensitiveOption),
         ComicDirection::LeftToRight},
        {QRegularExpression(QStringLiteral("第\\s*\\d+\\s*[话回]")), ComicDirection::LeftToRight},
    };
    return table;
}

template <typename Table>
ComicDirection firstMatch(const Table &table, const QString &text)
{
    for (const Matcher &matcher : table) {
        if (matcher.pattern.match(text).hasMatch()) {
            return matcher.direction;
        }
    }
    return ComicDirection::Unknown;
}

ComicDirection classify(const QString &text)
{
    if (text.isEmpty()) {
        return ComicDirection::Unknown;
    }
    const ComicDirection explicitDirection = firstMatch(explicitMatchers(), text);
    if (explicitDirection != ComicDirection::Unknown) {
        return explicitDirection;
    }
    if (hasKana(text)) {
        return ComicDirection::RightToLeft;
    }
    const ComicDirection japanese = firstMatch(japaneseMatchers(), text);
    if (japanese != ComicDirection::Unknown) {
        return japanese;
    }
    return firstMatch(chineseKoreanMatchers(), text);
}

} // namespace

ComicDirection detectComicDirection(const QString &title, const QStringList &pageNames)
{
    const ComicDirection byTitle = classify(title);
    if (byTitle != ComicDirection::Unknown) {
        return byTitle;
    }

    // 页名补刀：日文包偶尔只有条目名带假名；最多看首尾各三页，不为判定去遍历整本
    const int count = static_cast<int>(pageNames.size());
    const int tail = qMin(3, count);
    for (int i = 0; i < tail; ++i) {
        const ComicDirection byHead = classify(pageNames.at(i));
        if (byHead != ComicDirection::Unknown) {
            return byHead;
        }
        const ComicDirection byTail = classify(pageNames.at(count - 1 - i));
        if (byTail != ComicDirection::Unknown) {
            return byTail;
        }
    }
    return ComicDirection::Unknown;
}

} // namespace myhub
