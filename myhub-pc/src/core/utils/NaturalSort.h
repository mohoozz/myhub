#pragma once

#include <QString>

namespace myhub {

/**
 * 自然排序：让 "page2" 排在 "page10" 之前（漫画页名、文件列表均需要）。
 */
class NaturalSort
{
public:
    /// 返回 <0 / 0 / >0
    static int compare(const QString &a, const QString &b,
                       Qt::CaseSensitivity cs = Qt::CaseInsensitive);

    static bool lessThan(const QString &a, const QString &b) { return compare(a, b) < 0; }
};

} // namespace myhub
