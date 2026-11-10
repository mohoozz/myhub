#include "TrackName.h"

#include <QFileInfo>
#include <QRegularExpression>

namespace myhub {

namespace {

/// 带括号的音轨号：`[01]` / `(02)` / `【03】`，后面通常跟一个空格
const QRegularExpression &bracketedTrackRe()
{
    static const QRegularExpression re(
        QStringLiteral("^\\s*(?:\\[|\\(|（|【)\\s*\\d{1,3}\\s*(?:\\]|\\)|）|】)\\s*"));
    return re;
}

/// 裸音轨号：`01.` / `3 -` / `4_` / `05、`
const QRegularExpression &bareTrackRe()
{
    static const QRegularExpression re(QStringLiteral("^\\s*\\d{1,3}\\s*[\\.\\-_、]\\s*"));
    return re;
}

/// 带空格的破折号：` - ` / ` – ` / ` — ` / ` － `
const QRegularExpression &spacedDashRe()
{
    static const QRegularExpression re(QStringLiteral("\\s+[-\\x{2013}\\x{2014}\\x{FF0D}]\\s+"));
    return re;
}

/// 不带空格的宽破折号（全角/长破折号才认，普通 `-` 不认，避免切坏 `AC-DC`）
const QRegularExpression &bareWideDashRe()
{
    static const QRegularExpression re(QStringLiteral("[\\x{2013}\\x{2014}\\x{FF0D}]"));
    return re;
}

const QRegularExpression &digitsOnlyRe()
{
    static const QRegularExpression re(QStringLiteral("^\\d+$"));
    return re;
}

} // namespace

TrackName::Parts TrackName::parse(const QString &fileName)
{
    Parts parts;

    // 远程路径也是 `/` 分隔，QFileInfo 能正确取末段
    QString base = QFileInfo(fileName).completeBaseName();
    if (base.isEmpty())
        base = QFileInfo(fileName).fileName();
    base = base.trimmed();

    QString rest = base;
    rest.remove(bracketedTrackRe());
    rest.remove(bareTrackRe());
    rest = rest.trimmed();
    if (rest.isEmpty())
        rest = base;

    int split = -1;
    int sepLen = 0;
    const auto spaced = spacedDashRe().match(rest);
    if (spaced.hasMatch()) {
        split = static_cast<int>(spaced.capturedStart());
        sepLen = static_cast<int>(spaced.capturedLength());
    } else {
        const auto bare = bareWideDashRe().match(rest);
        if (bare.hasMatch()) {
            split = static_cast<int>(bare.capturedStart());
            sepLen = static_cast<int>(bare.capturedLength());
        }
    }

    if (split > 0) {
        const QString left = rest.left(split).trimmed();
        const QString right = rest.mid(split + sepLen).trimmed();
        // 两侧都非空才是一次有效切分；左侧纯数字是音轨号，不算作者
        if (!left.isEmpty() && !right.isEmpty()) {
            if (!digitsOnlyRe().match(left).hasMatch())
                parts.artist = left;
            parts.title = right;
            return parts;
        }
    }

    parts.title = rest.isEmpty() ? base : rest;
    return parts;
}

} // namespace myhub
