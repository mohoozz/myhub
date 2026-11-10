#include "SubtitleMatcher.h"

#include <QFileInfo>

namespace myhub {

namespace {

const QStringList &subtitleExts()
{
    static const QStringList exts{QStringLiteral("srt"), QStringLiteral("ass"),
                                  QStringLiteral("ssa"), QStringLiteral("vtt"),
                                  QStringLiteral("sub")};
    return exts;
}

/// 中文常见标记：`zh` / `chs`（简）/ `cht`（繁）/ `zh-CN` / `gb` / `big5`
const QStringList &chineseTags()
{
    static const QStringList tags{
        QStringLiteral("zh"),    QStringLiteral("zho"),     QStringLiteral("chi"),
        QStringLiteral("chs"),   QStringLiteral("cht"),     QStringLiteral("zh-cn"),
        QStringLiteral("zh-tw"), QStringLiteral("zh-hans"), QStringLiteral("zh-hant"),
        QStringLiteral("gb"),    QStringLiteral("big5"),    QStringLiteral("sc"),
        QStringLiteral("tc")};
    return tags;
}

} // namespace

bool SubtitleMatcher::isSubtitleFile(const QString &fileName)
{
    if (fileName.isEmpty())
        return false;
    return subtitleExts().contains(QFileInfo(fileName).suffix().toLower());
}

int SubtitleMatcher::score(const QString &videoBaseName, const QString &subtitleFileName)
{
    if (videoBaseName.isEmpty() || !isSubtitleFile(subtitleFileName))
        return 0;

    // `影片.zh.srt` 的 completeBaseName 是 `影片.zh`，正好用来判断后缀段
    const QString stem = QFileInfo(subtitleFileName).completeBaseName();
    if (stem.compare(videoBaseName, Qt::CaseInsensitive) == 0)
        return 100;

    // 只认「影片名 + '.' 开头」的形态；`影片2.srt` / `影片-加长版.srt` 一律不认
    if (!stem.startsWith(videoBaseName + QLatin1Char('.'), Qt::CaseInsensitive))
        return 0;

    const QString suffix = stem.mid(videoBaseName.size() + 1);
    int s = 80;
    const QStringList tags = suffix.split(QLatin1Char('.'), Qt::SkipEmptyParts);
    for (const QString &tag : tags) {
        if (chineseTags().contains(tag.toLower())) {
            s += 10; // 中文优先于其它语言，但都排在精确同名之后
            break;
        }
    }
    return s;
}

QString SubtitleMatcher::pick(const QString &videoBaseName, const QStringList &fileNames)
{
    QString best;
    int bestScore = 0;
    for (const QString &name : fileNames) {
        const int s = score(videoBaseName, name);
        if (s <= 0)
            continue;
        // 同分按文件名升序取第一个：不依赖目录枚举顺序，结果可复现
        if (s > bestScore
            || (s == bestScore && QString::compare(name, best, Qt::CaseInsensitive) < 0)) {
            best = name;
            bestScore = s;
        }
    }
    return best;
}

} // namespace myhub
