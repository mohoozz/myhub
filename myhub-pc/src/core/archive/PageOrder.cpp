#include "PageOrder.h"

#include "core/utils/NaturalSort.h"

#include <QFileInfo>

#include <algorithm>

namespace myhub {
namespace pageorder {

namespace {

bool isImageSuffix(const QString &suffix)
{
    static const QStringList kSuffixes = {QStringLiteral("jpg"),  QStringLiteral("jpeg"),
                                          QStringLiteral("png"),  QStringLiteral("webp"),
                                          QStringLiteral("gif"),  QStringLiteral("bmp"),
                                          QStringLiteral("avif"), QStringLiteral("jxl")};
    return kSuffixes.contains(suffix);
}

QString baseNameOf(const QString &path)
{
    return path.mid(path.lastIndexOf(QLatin1Char('/')) + 1);
}

} // namespace

bool isPageName(const QString &name)
{
    if (name.isEmpty() || name.endsWith(QLatin1Char('/'))) {
        return false;
    }
    if (name.startsWith(QLatin1String("__MACOSX/"))) {
        return false;
    }
    const QString base = baseNameOf(name);
    if (base.startsWith(QLatin1Char('.'))) {
        return false; // macOS 的 ._xxx 资源叉
    }
    return isImageSuffix(QFileInfo(base).suffix().toLower());
}

QVector<int> sortedPageIndexes(const QStringList &names)
{
    // 页序只认自然排序：page2 必须排在 page10 前面，按底层顺序翻页会在第 10 页开始错乱
    QVector<QPair<QString, int>> candidates;
    candidates.reserve(names.size());
    for (int i = 0; i < names.size(); ++i) {
        if (isPageName(names.at(i))) {
            candidates.append({names.at(i), i});
        }
    }
    std::sort(candidates.begin(), candidates.end(),
              [](const QPair<QString, int> &a, const QPair<QString, int> &b) {
                  return NaturalSort::lessThan(a.first, b.first);
              });

    QVector<int> indexes;
    indexes.reserve(candidates.size());
    for (const auto &candidate : candidates) {
        indexes.append(candidate.second);
    }
    return indexes;
}

} // namespace pageorder
} // namespace myhub
