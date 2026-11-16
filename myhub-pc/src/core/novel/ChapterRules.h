#pragma once

#include "core/novel/NovelIndex.h"

#include <QRegularExpression>
#include <QString>
#include <QVector>

namespace myhub {

/// 一条分章规则（数据驱动，一行一条）
struct ChapterRule
{
    QString id;
    QString name;    ///< 展示名（设置里「手动指定规则」时给人看）
    QString pattern; ///< 正则；自带 `^`/`$`，只对**单行**文本匹配
    /**
     * 首字符预筛集（空 = 不筛）。
     *
     * 必须覆盖规则可能匹配的全部首字符，**宁多勿少**：漏一个字符就是漏一批章节。
     * 有了它，正文行（占 99% 以上）连解码都不用做。
     */
    QString firstChars;
    QRegularExpression regex;
};

/**
 * txt 分章规则表（§5.1 PC-201，规则体系移植自 iOS 端 `ChapterRuleTable`）。
 *
 * 三个设计决定，都是有代价换来的：
 *
 * 1. **两级匹配**：先用 `firstChars` 做 O(1) 首字符预筛，只对候选行解码 + 跑正则。
 *    否则「10 条规则 × 几十万行」在 20MB 文本上会退化成数十秒。
 * 2. **选规则而不是取并集**：每条规则各自收集候选章，最后挑一条。
 *    取并集会把「正文里偶然出现的『第一章』」也当成真章节，把书切碎。
 * 3. **顺序即可信度**：章节数相同时，表里靠前的规则胜（更严格的规则优先）。
 */
class ChapterRules
{
public:
    static const QVector<ChapterRule> &rules();

    /// 按 id 找规则；没有返回 nullptr（读缓存时规则表可能已改）
    static const ChapterRule *find(const QString &id);

    /// 单条规则的候选上限：异常规则（如纯数字行）可能命中十几万行，超过即丢弃尾部
    static int maxCandidates();

    /**
     * 候选章节是否可信（Legado 校验思路的轻量实现）。
     *
     * 任一条件不满足即判该规则误报过多：
     *   - 至少 2 章（1 章等于没切）
     *   - 起点严格递增，且相邻间隔 ≥ 32 字节（同一行附近连续命中是正则误报）
     *   - 平均章长 ≥ 64 字节（把正文行/列表行都当标题的规则会立刻露馅）
     *   - ≥8 章时标题重复度过半淘汰；只有 1 个标题却切出 3 章以上淘汰
     */
    static bool isPlausible(const QVector<NovelChapter> &chapters, qint64 fileSize);

    /**
     * 择优：通过校验者中取章节数最多的，并列按规则表顺序。
     *
     * @param byRule 下标与 `rules()` 一一对应的候选列表
     * @param rejectedRuleId 出参：被校验否掉、但候选数最多的那条（日志里能看出为什么没选它）
     * @return 选中的规则；全部不通过时返回 nullptr（调用方按「无章节」处理）
     */
    static const ChapterRule *selectBest(const QVector<QVector<NovelChapter>> &byRule,
                                         qint64 fileSize, QString *rejectedRuleId = nullptr);

    /// 「第x章 / Chapter n」家族，用于自检日志
    static bool isNumberedHeading(const QString &title);
    /// 楔子/序章/前言/引子 这类合法开头
    static bool isOpeningHeading(const QString &title);
};

} // namespace myhub
