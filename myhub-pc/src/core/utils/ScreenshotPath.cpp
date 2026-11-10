#include "ScreenshotPath.h"

#include "AppPaths.h"

#include <QDir>
#include <QFileInfo>
#include <QStandardPaths>

namespace myhub {

namespace {

constexpr auto kAppFolder = "MyHub";
constexpr auto kFallbackName = "screenshot";
/// 同一秒内的重名上限：再往后就是无限循环了，宁可覆盖也不要卡死
constexpr int kMaxDupSuffix = 100;

/// 文件名里必须剔除的字符：Windows 保留字符 + 三个在 macOS/Linux 上也同样惹事的
bool isForbidden(QChar ch)
{
    switch (ch.unicode()) {
    case '/':
    case '\\':
    case ':':
    case '*':
    case '?':
    case '"':
    case '<':
    case '>':
    case '|':
        return true;
    default:
        return ch.unicode() < 0x20 || ch.unicode() == 0x7F;
    }
}

} // namespace

QString ScreenshotPath::defaultDirectory()
{
    const QString pictures = QStandardPaths::writableLocation(QStandardPaths::PicturesLocation);
    if (pictures.isEmpty()) {
        // 少数精简系统/容器里没有「图片」目录，退回应用数据目录，不要在""下拼路径
        return AppPaths::dataDir() + QStringLiteral("/screenshots");
    }
    return pictures + QLatin1Char('/') + QLatin1String(kAppFolder);
}

QString ScreenshotPath::sanitizeTitle(const QString &title)
{
    QString cleaned;
    cleaned.reserve(title.size());
    bool lastWasSpace = false;
    bool lastWasPlaceholder = false;
    for (const QChar ch : title) {
        QChar out = isForbidden(ch) ? QChar(u'_') : ch;
        // 控制字符已在 isForbidden 里判过，这里只处理制表/换行这类「看得见但怪」的空白
        if (out.isSpace()) {
            if (lastWasSpace || cleaned.isEmpty()) {
                continue; // 折叠连续空白，去掉前导空白
            }
            out = QLatin1Char(' ');
        }
        // 连续非法字符压成一个下划线：`a//b` 不该变成 `a__b`
        if (out == QLatin1Char('_')) {
            if (lastWasPlaceholder) {
                continue;
            }
            lastWasPlaceholder = true;
        } else {
            lastWasPlaceholder = false;
        }
        lastWasSpace = out == QLatin1Char(' ');
        cleaned.append(out);
    }
    while (cleaned.endsWith(QLatin1Char(' ')) || cleaned.endsWith(QLatin1Char('.'))) {
        cleaned.chop(1); // 尾随空格/点在 Windows 上会被静默丢弃，导致实际文件名与预期不符
    }
    return cleaned.isEmpty() ? QLatin1String(kFallbackName) : cleaned;
}

QString ScreenshotPath::build(const QString &directory, const QString &title, const QDateTime &now)
{
    const QString base = sanitizeTitle(title) + QLatin1Char('_')
        + now.toString(QStringLiteral("yyyy-MM-dd_HH-mm-ss"));
    const QDir dir(directory);

    QString candidate = dir.filePath(base + QStringLiteral(".png"));
    for (int suffix = 2; suffix <= kMaxDupSuffix && QFileInfo::exists(candidate); ++suffix) {
        candidate = dir.filePath(base + QStringLiteral("-%1.png").arg(suffix));
    }
    return candidate;
}

} // namespace myhub
