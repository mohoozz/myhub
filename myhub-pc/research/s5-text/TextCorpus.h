#pragma once

#include <QString>
#include <QStringList>

// 确定性语料生成：同一个种子必然产出同一份文本，便于逐字节复现判定。
struct CorpusStats {
    int paragraphs = 0;
    int utf16Length = 0;
    int cjkChars = 0;
    int asciiChars = 0;
    int emojiChars = 0;    // 代理对个数（每对占 2 个 UTF-16 单元）
    int maxParaLen = 0;
};

class TextCorpus {
public:
    // 10 万 UTF-16 单元的小说章节：CJK + 中文标点 + ASCII 单词 + emoji 混排。
    static QStringList chapter100k(CorpusStats *stats);

    // 最坏情况：整章没有换行，10 万字挤在一个 QTextLayout 里。
    static QString giantParagraph100k(int *utf16Length);

    // pos 是否落在代理对中间（即 text[pos] 是低代理、text[pos-1] 是高代理）
    static bool splitsSurrogatePair(const QString &text, int pos);

    // 该位置之后最长的、不切断代理对的分段长度
    static int safePrefixLength(const QString &text, int pos);
};
