// S5 预研：QTextLayout 对 10 万字章节的行级分页 + 排版无关锚点换算
//
// 判定尽量落到可量化证据上：
//   「不截断行」  = 每个页边界都落在行边界上，同一段落的行区间**精确铺满**段文本
//                   （无空洞、无重叠、无字符丢失），且没有一行横向溢出列宽
//   「重排 <200ms」= 10 万字章节全量重排的实测毫秒数（含整章无换行的极端情况）
//   「锚点往返」  = (段序 + 段内偏移) -> 行 -> (段序 + 段内偏移) 恒等
//   「排版无关」  = 同一锚点在 3 组字号/行距/列宽下都落在包含该偏移的行上
//   「一步定位」  = 锚点直接给出页码，无需「先跳章节再找偏移」两步

#include "TextCorpus.h"
#include "TextLayoutEngine.h"

#include <QElapsedTimer>
#include <QFile>
#include <QFontDatabase>
#include <QFontInfo>
#include <QFontMetricsF>
#include <QGuiApplication>
#include <QRandomGenerator>
#include <QTextStream>

#include <algorithm>
#include <cmath>

namespace {

QTextStream *g_file = nullptr;
QTextStream *g_console = nullptr;
int g_pass = 0;
int g_fail = 0;

void report(const QString &line)
{
    if (g_file) { *g_file << line << '\n'; g_file->flush(); }
    if (g_console) { *g_console << line << '\n'; g_console->flush(); }
}

void check(bool ok, const QString &label, const QString &detail)
{
    if (ok) ++g_pass; else ++g_fail;
    report(QStringLiteral("  %1 %2 %3")
               .arg(ok ? QStringLiteral("[OK]") : QStringLiteral("[FAIL]"),
                    label.leftJustified(30, QLatin1Char(' ')), detail));
}

} // namespace

int main(int argc, char *argv[])
{
    // 不强制 offscreen：offscreen 平台插件下字体数据库是空的，
    // QFontMetricsF 拿不到真实行高，量出来的行数/耗时全是假数据。
    // 探针不创建任何窗口，用默认平台插件也不会弹窗。
    QGuiApplication app(argc, argv);

    QFile file(QStringLiteral("s5-text-report.txt"));
    file.open(QIODevice::WriteOnly | QIODevice::Text);
    QTextStream fileStream(&file);
    QTextStream console(stdout);
    g_file = &fileStream;
    g_console = &console;

    report(QStringLiteral("=== S5: QTextLayout line-level pagination + anchor ==="));

    // ---- 语料 ----
    CorpusStats stats;
    const QStringList paras = TextCorpus::chapter100k(&stats);
    const int totalUnits = stats.utf16Length;

    TypoConfig cfg;
    cfg.fontFamily = QStringLiteral("Microsoft YaHei");
    const QStringList families = QFontDatabase::families();
    if (!families.contains(cfg.fontFamily)) {
        const QStringList prefer = { QStringLiteral("SimSun"), QStringLiteral("Source Han Serif SC"),
                                     QStringLiteral("Songti SC"), QStringLiteral("PingFang SC") };
        for (const QString &f : prefer) {
            if (families.contains(f)) { cfg.fontFamily = f; break; }
        }
    }

    QFont probeFont(cfg.fontFamily);
    probeFont.setPixelSize(cfg.fontSize);
    const QFontInfo fontInfo(probeFont);
    const QFontMetricsF probeFm(probeFont);

    report(QStringLiteral("  font db          : %1 families available").arg(families.size()));
    report(QStringLiteral("  corpus           : %1 UTF-16 units, %2 paragraphs, "
                          "max paragraph %3 units")
               .arg(totalUnits).arg(stats.paragraphs).arg(stats.maxParaLen));
    report(QStringLiteral("  mix              : CJK %1 / ASCII %2 / emoji pairs %3")
               .arg(stats.cjkChars).arg(stats.asciiChars).arg(stats.emojiChars));
    report(QStringLiteral("  font             : %1 (requested '%2') %3 px, lineSpacing %4")
               .arg(fontInfo.family(), cfg.fontFamily).arg(cfg.fontSize).arg(cfg.lineSpacing));
    report(QStringLiteral("  viewport         : %1x%2, padding %3")
               .arg(cfg.viewportWidth).arg(cfg.viewportHeight).arg(cfg.padding));

    // 字体必须真的解析到，否则行高/行宽全是假的，后面所有耗时与行数都没有意义
    check(!fontInfo.family().isEmpty() && probeFm.height() > 0,
          QStringLiteral("font really resolved"),
          QStringLiteral("'%1' -> '%2', height %3 px, ascent %4 px")
              .arg(cfg.fontFamily, fontInfo.family())
              .arg(probeFm.height(), 0, 'f', 2).arg(probeFm.ascent(), 0, 'f', 2));
    report(QStringLiteral("  emoji glyph      : U+1F600 %1 in '%2' "
                          "(CJK 字体通常不含 emoji，M3 需显式字体回退)")
               .arg(probeFm.inFontUcs4(0x1F600) ? QStringLiteral("present")
                                               : QStringLiteral("MISSING"))
               .arg(fontInfo.family()));

    TextLayoutEngine engine;
    engine.setParagraphs(paras);
    engine.setTypo(cfg);

    // 首次重排会带上字形缓存预热，单次数字不可信；跑 3 轮取中位/最大
    QVector<qint64> layoutRuns;
    for (int i = 0; i < 3; ++i) {
        engine.relayout();
        layoutRuns << engine.lastLayoutMs();
    }
    std::sort(layoutRuns.begin(), layoutRuns.end());
    const qint64 layoutMedian = layoutRuns.at(1);
    const qint64 layoutWorst = layoutRuns.last();

    const qreal availWidth = qreal(cfg.viewportWidth - 2 * cfg.padding);
    const qreal pageHeight = qreal(cfg.viewportHeight - 2 * cfg.padding);

    report(QString());
    report(QStringLiteral("--- phase 1: paginate 100k chars ---"));
    report(QStringLiteral("     pages=%1 lines=%2 layout=%3 ms (median of 3; worst %4 ms)")
               .arg(engine.pageCount()).arg(engine.lineCount())
               .arg(layoutMedian).arg(layoutWorst));

    check(totalUnits == 100000,
          QStringLiteral("corpus is 100k units"),
          QStringLiteral("%1 UTF-16 units in %2 paragraphs")
              .arg(totalUnits).arg(stats.paragraphs));

    check(engine.pageCount() > 1 && engine.lineCount() > 500,
          QStringLiteral("pagination produced"),
          QStringLiteral("%1 pages / %2 lines").arg(engine.pageCount()).arg(engine.lineCount()));

    check(layoutWorst < 200,
          QStringLiteral("full relayout < 200ms"),
          QStringLiteral("%1 units: median %2 ms, worst of 3 %3 ms (budget 200 ms)")
              .arg(totalUnits).arg(layoutMedian).arg(layoutWorst));

    // ---- 不截断行（1）：同一段落的行区间精确铺满段文本 ----
    {
        bool ok = true;
        QString detail;
        for (int pi = 0; pi < paras.size() && ok; ++pi) {
            const QString &para = paras.at(pi);
            const int begin = engine.paraLineBegin(pi);
            const int count = engine.paraLineCount(pi);
            if (begin < 0 || count <= 0) {
                ok = false;
                detail = QStringLiteral("paragraph %1 has no line").arg(pi);
                break;
            }
            int expect = 0;
            for (int k = 0; k < count; ++k) {
                const LineBox &box = engine.lines().at(begin + k);
                if (box.start != expect) {
                    ok = false;
                    detail = QStringLiteral("para %1 line %2 starts at %3, expected %4")
                                 .arg(pi).arg(k).arg(box.start).arg(expect);
                    break;
                }
                expect = box.start + box.length;
            }
            if (ok && expect != para.size()) {
                ok = false;
                detail = QStringLiteral("para %1 covered %2 of %3 units")
                             .arg(pi).arg(expect).arg(para.size());
            }
        }
        check(ok,
              QStringLiteral("lines tile paragraphs exactly"),
              ok ? QStringLiteral("%1 paragraphs split into %2 lines: no gap / no overlap / "
                                  "no dropped char")
                       .arg(paras.size()).arg(engine.lineCount())
                 : detail);
    }

    // ---- 不截断行（2）：行首行尾不得切在代理对中间 ----
    {
        int badStart = 0, badEnd = 0;
        QString firstBad;
        for (const LineBox &box : engine.lines()) {
            const QString &para = paras.at(box.paragraph);
            if (TextCorpus::splitsSurrogatePair(para, box.start)) {
                if (firstBad.isEmpty())
                    firstBad = QStringLiteral("line start %1 in para %2")
                                   .arg(box.start).arg(box.paragraph);
                ++badStart;
            }
            if (TextCorpus::splitsSurrogatePair(para, box.start + box.length)) {
                if (firstBad.isEmpty())
                    firstBad = QStringLiteral("line end %1 in para %2")
                                   .arg(box.start + box.length).arg(box.paragraph);
                ++badEnd;
            }
        }
        check(badStart == 0 && badEnd == 0,
              QStringLiteral("no emoji split at line edge"),
              badStart == 0 && badEnd == 0
                  ? QStringLiteral("%1 line boundaries vs %2 emoji pairs: 0 split")
                        .arg(engine.lineCount()).arg(stats.emojiChars)
                  : QStringLiteral("badStart=%1 badEnd=%2 (%3)")
                        .arg(badStart).arg(badEnd).arg(firstBad));
    }

    // ---- 不截断行（3）：行宽不得溢出列宽 ----
    {
        int overflow = 0;
        qreal worst = 0;
        for (const LineBox &box : engine.lines()) {
            if (box.width > availWidth + 0.5) {
                ++overflow;
                worst = qMax(worst, box.width);
            }
        }
        check(overflow == 0,
              QStringLiteral("no line overflows column"),
              overflow == 0
                  ? QStringLiteral("0 of %1 lines exceed %2 px")
                        .arg(engine.lineCount()).arg(availWidth, 0, 'f', 1)
                  : QStringLiteral("%1 lines overflow, worst %2 px > %3 px")
                        .arg(overflow).arg(worst, 0, 'f', 1).arg(availWidth, 0, 'f', 1));
    }

    // ---- 分页完整性：页首尾相接、无空页、页高不超界 ----
    {
        bool ok = true;
        QString detail;
        int expectLine = 0;
        qreal maxUsed = 0;
        for (int i = 0; i < engine.pageCount(); ++i) {
            const PageBox &p = engine.pages().at(i);
            if (p.lineBegin != expectLine) {
                ok = false;
                detail = QStringLiteral("page %1 starts at line %2, expected %3")
                             .arg(i).arg(p.lineBegin).arg(expectLine);
                break;
            }
            if (p.lineCount <= 0) {
                ok = false;
                detail = QStringLiteral("page %1 is empty").arg(i);
                break;
            }
            if (p.usedHeight > pageHeight + 0.5) {
                ok = false;
                detail = QStringLiteral("page %1 used %2 px > %3 px")
                             .arg(i).arg(p.usedHeight).arg(pageHeight);
                break;
            }
            maxUsed = qMax(maxUsed, p.usedHeight);
            expectLine = p.lineBegin + p.lineCount;
        }
        if (ok && expectLine != engine.lineCount()) {
            ok = false;
            detail = QStringLiteral("pages cover %1 of %2 lines")
                         .arg(expectLine).arg(engine.lineCount());
        }
        check(ok,
              QStringLiteral("pages contiguous, no overflow"),
              ok ? QStringLiteral("%1 pages, max page height %2 / %3 px")
                       .arg(engine.pageCount()).arg(maxUsed, 0, 'f', 1).arg(pageHeight, 0, 'f', 1)
                 : detail);
    }

    // ---- 最坏情况：整章无换行，10 万字挤进单块 QTextLayout ----
    int giantLen = 0;
    const QString giant = TextCorpus::giantParagraph100k(&giantLen);
    int giantLines = 0;
    QVector<qint64> giantRuns;
    for (int i = 0; i < 3; ++i)
        giantRuns << TextLayoutEngine::layoutSingleParagraphMs(giant, cfg, &giantLines);
    std::sort(giantRuns.begin(), giantRuns.end());
    const qint64 giantMedian = giantRuns.at(1);
    const qint64 giantWorst = giantRuns.last();
    check(giantWorst < 200,
          QStringLiteral("giant paragraph < 200ms"),
          QStringLiteral("%1 units in ONE paragraph -> %2 lines, median %3 ms / worst %4 ms")
              .arg(giantLen).arg(giantLines).arg(giantMedian).arg(giantWorst));

    // ---- 改字号/行距/列宽后重排 ----
    TypoConfig big = cfg;
    big.fontSize = 24;
    big.lineSpacing = 1.9;
    TextLayoutEngine engineBig;
    engineBig.setParagraphs(paras);
    engineBig.setTypo(big);
    engineBig.relayout();
    check(engineBig.lastLayoutMs() < 200 && engineBig.pageCount() != engine.pageCount(),
          QStringLiteral("relayout on typography < 200ms"),
          QStringLiteral("%1 px / %2x -> %3 pages in %4 ms (18 px gave %5 pages)")
              .arg(big.fontSize).arg(big.lineSpacing).arg(engineBig.pageCount())
              .arg(engineBig.lastLayoutMs()).arg(engine.pageCount()));

    // ---- 锚点往返恒等 ----
    report(QString());
    report(QStringLiteral("--- phase 2: anchor round-trip ---"));
    int anchorCount = 0;
    qint64 seekNs = 0;
    {
        QElapsedTimer seekTimer;
        seekTimer.start();

        int firstBadLine = -1;
        bool ok = true;

        auto verify = [&](int pi, int offset) -> bool {
            Anchor a;
            if (!engine.anchorAt(pi, offset, &a)) return false;
            int rp = -1, ro = -1;
            if (!engine.paragraphOffsetAtLine(a.lineIndex, &rp, &ro)) return false;
            Anchor b;
            if (!engine.anchorAt(rp, ro, &b)) return false;
            int page = -1;
            if (!engine.pageForAnchor(a, &page)) return false;
            ++anchorCount;
            if (b.paragraph != a.paragraph || b.offset != a.offset
                || b.page != a.page || b.lineIndex != a.lineIndex) {
                if (firstBadLine < 0) firstBadLine = a.lineIndex;
                return false;
            }
            return true;
        };

        for (int pi = 0; pi < paras.size() && ok; ++pi) {
            const int len = int(paras.at(pi).size());
            ok = verify(pi, 0) && verify(pi, len);
        }
        for (int li = 0; li < engine.lineCount() && ok; ++li) {
            int pi = -1, off = -1;
            engine.paragraphOffsetAtLine(li, &pi, &off);
            ok = verify(pi, off);
        }
        seekNs = seekTimer.nsecsElapsed();

        check(ok,
              QStringLiteral("anchor round-trip identity"),
              ok ? QStringLiteral("%1 anchors (paragraph head/tail + every line head): "
                                  "offset -> line -> offset is identity")
                       .arg(anchorCount)
                 : QStringLiteral("first mismatch at line %1 of %2")
                       .arg(firstBadLine).arg(engine.lineCount()));
    }
    const double avgUs = anchorCount > 0 ? double(seekNs) / 1000.0 / anchorCount : 0.0;
    check(anchorCount > 0 && avgUs < 1000.0,
          QStringLiteral("one-step locate"),
          QStringLiteral("anchor yields page directly (no chapter-then-offset two-step), "
                         "avg %1 us over %2 lookups")
              .arg(avgUs, 0, 'f', 2).arg(anchorCount));

    // ---- 随机偏移 / emoji 内部偏移 ----
    {
        QRandomGenerator rng(20261012);
        int probes = 0;
        int bad = 0;
        QString firstBad;

        for (int n = 0; n < 2000; ++n) {
            const int pi = int(rng.bounded(int(paras.size())));
            const QString &para = paras.at(pi);
            const int off = int(rng.bounded(int(para.size()) + 1));
            Anchor a;
            if (!engine.anchorAt(pi, off, &a)) { ++bad; continue; }
            ++probes;
            const LineBox &box = engine.lines().at(a.lineIndex);
            if (box.paragraph != pi || off < box.start || off > box.start + box.length) {
                if (!bad++ && firstBad.isEmpty())
                    firstBad = QStringLiteral("para %1 off %2 -> line %3 [%4,%5)")
                                   .arg(pi).arg(off).arg(a.lineIndex)
                                   .arg(box.start).arg(box.start + box.length);
            }
        }
        check(bad == 0,
              QStringLiteral("random offsets stay in line"),
              bad == 0 ? QStringLiteral("%1 random offsets: all normalise into their own line")
                             .arg(probes)
                       : firstBad);

        int emojiChecked = 0, emojiBad = 0;
        for (int pi = 0; pi < paras.size(); ++pi) {
            const QString &para = paras.at(pi);
            for (int i = 0; i + 1 < para.size(); ++i) {
                if (!para.at(i).isHighSurrogate() || !para.at(i + 1).isLowSurrogate())
                    continue;
                ++emojiChecked;
                Anchor head, mid;
                if (!engine.anchorAt(pi, i, &head)) { ++emojiBad; continue; }
                if (!engine.anchorAt(pi, i + 1, &mid)) { ++emojiBad; continue; }
                // 落进代理对中间必须归一化到同一行同一偏移
                if (mid.offset != head.offset || mid.page != head.page) ++emojiBad;
            }
        }
        check(emojiBad == 0,
              QStringLiteral("emoji mid-pair offset safe"),
              QStringLiteral("%1 emoji positions (incl. offset+1 inside the pair): "
                             "%2 anomalies").arg(emojiChecked).arg(emojiBad));
    }

    // ---- 排版无关：同一锚点在 3 组排版下都落在含该偏移的行上 ----
    {
        TypoConfig c2 = cfg;
        c2.fontSize = 20;
        c2.lineSpacing = 1.75;

        TypoConfig c3 = cfg;
        c3.fontSize = 15;
        c3.lineSpacing = 2.0;
        c3.viewportWidth = 560;

        TextLayoutEngine e2, e3;
        e2.setParagraphs(paras);
        e2.setTypo(c2);
        e2.relayout();
        e3.setParagraphs(paras);
        e3.setTypo(c3);
        e3.relayout();

        struct Saved { int pi; int off; QString snippet; int page; };
        QVector<Saved> saved;
        for (int pi = 0; pi < paras.size(); ++pi) {
            Anchor a;
            if (engine.anchorAt(pi, 0, &a))
                saved << Saved{ pi, a.offset, a.snippet, a.page };
            if (pi % 7 == 0) {
                Anchor b;
                const int mid = int(paras.at(pi).size()) / 2;
                if (engine.anchorAt(pi, mid, &b))
                    saved << Saved{ pi, b.offset, b.snippet, b.page };
            }
        }

        int bad = 0, pageMoved = 0;
        QString firstBad;
        for (const Saved &s : saved) {
            for (TextLayoutEngine *e : { &e2, &e3 }) {
                Anchor restored;
                if (!e->anchorAt(s.pi, s.off, &restored)) {
                    if (!bad++ && firstBad.isEmpty())
                        firstBad = QStringLiteral("para %1 off %2 dropped").arg(s.pi).arg(s.off);
                    continue;
                }
                const LineBox &box = e->lines().at(restored.lineIndex);
                const QString text = e->paragraphs().at(s.pi);
                const bool contains = (s.off >= box.start && s.off <= box.start + box.length);
                const bool snippetSame = TextLayoutEngine::snippetAt(text, s.off) == s.snippet;
                if (!contains || !snippetSame) {
                    if (!bad++ && firstBad.isEmpty())
                        firstBad = QStringLiteral("para %1 off %2 -> line [%3,%4) snippet=%5")
                                       .arg(s.pi).arg(s.off).arg(box.start)
                                       .arg(box.start + box.length)
                                       .arg(snippetSame ? QStringLiteral("same")
                                                        : QStringLiteral("differs"));
                }
                if (restored.page != s.page) ++pageMoved;
            }
        }
        check(bad == 0,
              QStringLiteral("anchor survives relayout"),
              bad == 0
                  ? QStringLiteral("%1 anchors re-located under 15/20 px, 1.6~2.0x spacing, "
                                   "560/760 px width: all on the line containing the offset "
                                   "(%2 hit a different page, offset unchanged)")
                        .arg(saved.size()).arg(pageMoved)
                  : firstBad);
    }

    // ---- 首尾边界 + 百分比兜底 ----
    {
        Anchor first, last;
        const bool okFirst = engine.anchorAt(0, 0, &first);
        const int lastPara = int(paras.size()) - 1;
        const bool okLast = engine.anchorAt(lastPara, int(paras.at(lastPara).size()), &last);
        check(okFirst && first.page == 0 && first.lineIndex == 0,
              QStringLiteral("chapter head -> page 0"),
              QStringLiteral("page=%1 line=%2").arg(first.page).arg(first.lineIndex));
        check(okLast && last.page == engine.pageCount() - 1,
              QStringLiteral("chapter tail -> last page"),
              QStringLiteral("page=%1 of %2").arg(last.page).arg(engine.pageCount() - 1));

        int prevPct = -1;
        int lastPct = -1;
        int nonMonotonic = 0;
        qint64 base = 0;
        for (int pi = 0; pi < paras.size(); ++pi) {
            const int p = totalUnits > 0 ? int(100.0 * double(base) / totalUnits) : 0;
            if (p < prevPct) ++nonMonotonic;
            prevPct = p;
            lastPct = p;
            base += paras.at(pi).size();
        }
        check(nonMonotonic == 0 && lastPct < 100,
              QStringLiteral("percent fallback monotonic"),
              QStringLiteral("paragraph-relative percent non-decreasing; last paragraph "
                             "starts at %1%, so a percent fallback never claims "
                             "100% early").arg(lastPct));
    }

    report(QString());
    report(QStringLiteral("--- summary ---"));
    report(QStringLiteral("  pages / lines    : %1 / %2").arg(engine.pageCount()).arg(engine.lineCount()));
    report(QStringLiteral("  layout time      : %1 ms median / %2 ms worst (budget 200)")
               .arg(layoutMedian).arg(layoutWorst));
    report(QStringLiteral("  giant paragraph  : %1 ms median / %2 ms worst (one 100k-unit paragraph)")
               .arg(giantMedian).arg(giantWorst));
    report(QStringLiteral("  anchor lookups   : %1, avg %2 us").arg(anchorCount).arg(avgUs, 0, 'f', 2));
    report(QStringLiteral("  checks           : %1 passed, %2 failed").arg(g_pass).arg(g_fail));
    report(QStringLiteral("  RESULT: %1").arg(g_fail == 0 ? QStringLiteral("S5 PASSED")
                                                           : QStringLiteral("S5 HAS FAILURES")));

    return g_fail == 0 ? 0 : 1;
}
