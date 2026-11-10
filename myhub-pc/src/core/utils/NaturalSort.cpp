#include "NaturalSort.h"

namespace myhub {

int NaturalSort::compare(const QString &a, const QString &b, Qt::CaseSensitivity cs)
{
    const int na = a.size();
    const int nb = b.size();
    int i = 0, j = 0;

    while (i < na && j < nb) {
        const QChar ca = a.at(i);
        const QChar cb = b.at(j);

        if (ca.isDigit() && cb.isDigit()) {
            // 跳过前导零后按数值长度与字典序比较，避免大整数溢出
            int si = i;
            while (si < na && a.at(si) == QLatin1Char('0'))
                ++si;
            int sj = j;
            while (sj < nb && b.at(sj) == QLatin1Char('0'))
                ++sj;

            int ei = si;
            while (ei < na && a.at(ei).isDigit())
                ++ei;
            int ej = sj;
            while (ej < nb && b.at(ej).isDigit())
                ++ej;

            const int lenA = ei - si;
            const int lenB = ej - sj;
            if (lenA != lenB)
                return lenA < lenB ? -1 : 1;

            const QStringView va = QStringView(a).mid(si, lenA);
            const QStringView vb = QStringView(b).mid(sj, lenB);
            const int cmp = va.compare(vb);
            if (cmp != 0)
                return cmp < 0 ? -1 : 1;

            i = ei;
            j = ej;
            continue;
        }

        const int cmp = QStringView(a).mid(i, 1).compare(QStringView(b).mid(j, 1), cs);
        if (cmp != 0)
            return cmp < 0 ? -1 : 1;
        ++i;
        ++j;
    }

    if (i < na)
        return 1;
    if (j < nb)
        return -1;
    return 0;
}

} // namespace myhub
