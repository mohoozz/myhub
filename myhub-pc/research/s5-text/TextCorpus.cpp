#include "TextCorpus.h"

namespace {

// 固定种子 LCG：语料必须可逐字节复现，否则「重排耗时」这类判定无法对照。
class Lcg {
public:
    explicit Lcg(quint32 seed = 0x5EED2026u) : m_s(seed) {}
    quint32 next() { m_s = m_s * 1664525u + 1013904223u; return m_s; }
    int range(int lo, int hi) { return lo + int(next() % quint32(hi - lo + 1)); }
private:
    quint32 m_s;
};

const QString &cjkPool()
{
    static const QString pool = QStringLiteral(
        "春江花月夜山水风林火云雾雨雪花鸟鱼虫天地人和日月星辰山河湖海川原野村城镇"
        "街巷楼阁亭台书房笔墨纸砚琴棋书画诗词歌赋文武君臣子民家国天下情思念忆梦醒"
        "醉愁喜悲欢离合阴晴圆缺盈亏盛衰兴旺败落进退取舍得失荣辱沉浮昼夜寒暑晨昏"
        "松竹梅兰菊荷柳桃李杏梨枫桐柏槐桑榆稻麦菽粟丝麻帛絮釜甑鼎彝钟磬鼓瑟笙箫");
    return pool;
}

const QStringList &asciiPool()
{
    static const QStringList words = {
        QStringLiteral("the"),    QStringLiteral("quick"),   QStringLiteral("brown"),
        QStringLiteral("fox"),    QStringLiteral("jumps"),   QStringLiteral("over"),
        QStringLiteral("lazy"),   QStringLiteral("dog"),     QStringLiteral("Qt"),
        QStringLiteral("QTextLayout"), QStringLiteral("line"), QStringLiteral("break"),
        QStringLiteral("anchor"), QStringLiteral("pagination"), QStringLiteral("e-ink"),
        QStringLiteral("M1"),     QStringLiteral("v1.0"),
    };
    return words;
}

const QStringList &emojiPool()
{
    static const QStringList emojis = {
        QStringLiteral("\U0001F600"),  // 😀
        QStringLiteral("\U0001F389"),  // 🎉
        QStringLiteral("\U0001F680"),  // 🚀
        QStringLiteral("\U0001F525"),  // 🔥
        QStringLiteral("\U0001F4DA"),  // 📚
        QStringLiteral("\U0001F3A7"),  // 🎧
        QStringLiteral("\U0001F31F"),  // 🌟
        QStringLiteral("\U0001F4A1"),  // 💡
    };
    return emojis;
}

const QString &punctPool()
{
    static const QString pool = QStringLiteral("，。！？；：、（）「」《》");
    return pool;
}

void countStats(const QStringList &paras, CorpusStats *stats)
{
    if (!stats) return;
    CorpusStats s;
    s.paragraphs = int(paras.size());
    for (const QString &p : paras) {
        s.maxParaLen = qMax(s.maxParaLen, int(p.size()));
        s.utf16Length += int(p.size());
        for (int i = 0; i < p.size(); ++i) {
            const ushort u = p.at(i).unicode();
            if (u >= 0xD800 && u <= 0xDBFF) {
                ++s.emojiChars;
                ++i;                       // 跳过低位代理
            } else if (u >= 0x4E00 && u <= 0x9FFF) {
                ++s.cjkChars;
            } else if (u >= 0x20 && u <= 0x7E) {
                ++s.asciiChars;
            }
        }
    }
    *stats = s;
}

} // namespace

QStringList TextCorpus::chapter100k(CorpusStats *stats)
{
    constexpr int kTarget = 100000;

    Lcg rng;
    QStringList paras;
    int total = 0;

    while (total < kTarget) {
        const int targetLen = rng.range(120, 240);
        QString p;
        while (p.size() < targetLen) {
            switch (rng.range(0, 9)) {
            case 0: case 1: case 2: case 3: {          // 中文短句
                const int n = rng.range(6, 18);
                for (int i = 0; i < n; ++i)
                    p += cjkPool().at(rng.range(0, int(cjkPool().size()) - 1));
                if (rng.range(0, 2) == 0)
                    p += punctPool().at(rng.range(0, int(punctPool().size()) - 1));
                break;
            }
            case 4: case 5: {                          // 标点/引号
                p += punctPool().at(rng.range(0, int(punctPool().size()) - 1));
                break;
            }
            case 6: case 7: {                          // ASCII 英文词
                p += asciiPool().at(rng.range(0, int(asciiPool().size()) - 1));
                p += QLatin1Char(' ');
                break;
            }
            case 8:                                    // emoji（代理对）
                p += emojiPool().at(rng.range(0, int(emojiPool().size()) - 1));
                break;
            default: {                                 // 数字
                p += QString::number(rng.range(1, 9999));
                break;
            }
            }
        }
        // 段落不得以空白开头/结尾：否则行首尾空白是否计入 textLength 会干扰覆盖性校验
        while (p.endsWith(QLatin1Char(' '))) p.chop(1);
        paras << p;
        total += int(p.size());
    }

    // 精确裁到 10 万 UTF-16 单元，且不许把代理对切一半
    while (total > kTarget && !paras.isEmpty()) {
        QString &last = paras.last();
        int over = total - kTarget;
        if (over >= last.size()) {
            total -= int(last.size());
            paras.removeLast();
            continue;
        }
        int keep = int(last.size()) - over;
        if (keep > 0 && keep < last.size()
            && last.at(keep).isLowSurrogate())
            --keep;                     // 回退一个单元，避免切在代理对中间
        total -= int(last.size()) - keep;
        last.truncate(keep);
        if (last.isEmpty()) paras.removeLast();
    }
    // 裁多了用普通 CJK 字符补齐（单个 UTF-16 单元，安全）
    while (total < kTarget) {
        const int need = kTarget - total;
        if (paras.isEmpty()) {
            paras << QString();
        }
        QString &last = paras.last();
        for (int i = 0; i < need; ++i)
            last += cjkPool().at(rng.range(0, int(cjkPool().size()) - 1));
        total = kTarget;
    }

    countStats(paras, stats);
    return paras;
}

QString TextCorpus::giantParagraph100k(int *utf16Length)
{
    CorpusStats stats;
    const QStringList paras = chapter100k(&stats);
    // 把所有段落拼成一段：模拟「整章无换行」的 txt，压测单块 QTextLayout
    QString big;
    big.reserve(stats.utf16Length);
    for (const QString &p : paras) big += p;
    while (big.size() > 100000) {
        int keep = 100000;
        if (big.at(keep).isLowSurrogate()) --keep;
        big.truncate(keep);
    }
    if (utf16Length) *utf16Length = int(big.size());
    return big;
}

bool TextCorpus::splitsSurrogatePair(const QString &text, int pos)
{
    if (pos <= 0 || pos >= text.size()) return false;
    return text.at(pos - 1).isHighSurrogate() && text.at(pos).isLowSurrogate();
}

int TextCorpus::safePrefixLength(const QString &text, int pos)
{
    int p = pos;
    while (p > 0 && p < text.size() && splitsSurrogatePair(text, p)) --p;
    return p;
}
