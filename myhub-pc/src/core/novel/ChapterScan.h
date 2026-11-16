#pragma once

#include "core/novel/ChapterRules.h"
#include "core/text/TextCodec.h"

#include <QByteArray>
#include <QSet>
#include <QString>
#include <QVector>

#include <bitset>
#include <functional>
#include <optional>

namespace myhub {

/**
 * 任意偏移切片的「代码单元对齐」（需求文档 §2.5「码元对齐」）。
 *
 * 只对 UTF-8 / UTF-16 做**结构化**处理（这两种有自同步结构，能精确判断）：
 *   - UTF-8：续接字节 10xxxxxx 只可能出现在字符中间
 *   - UTF-16：单独出现的低位代理说明高位在前一块末尾
 *
 * GB18030 / Big5 没有可靠的自同步结构（双字节区间与单字节、四字节序列互相重叠），
 * 任何「试探解码」都可能在合法但错位的字符上停住 —— 与其猜错，不如不猜。
 * 本项目的章节偏移一律来自**行边界**，所以这两条路径只在外部传任意偏移时才用得上。
 */
class ChapterTextAlign
{
public:
    /// 代码单元宽度：UTF-16 = 2 字节，其余 = 1 字节
    static int unitSize(TextCodec::Encoding encoding);

    /// 头部对齐：需要跳过的字节数（0..3）
    static int headSkip(const QByteArray &data, TextCodec::Encoding encoding);

    /// 尾部对齐：末尾不完整、需要扣掉的字节数（0..3）
    static int tailDrop(const QByteArray &data, TextCodec::Encoding encoding);

    /**
     * 扣掉末尾不完整的 UTF-8 字符。
     *
     * 用于「探测编码」那一步：头块按 64KB 切，很可能切在一个三字节汉字中间，
     * 严格 UTF-8 校验会因此失败、把 UTF-8 文件误判成 GB18030（然后满屏乱码）。
     */
    static QByteArray trimIncompleteUtf8Tail(const QByteArray &data);
};

/**
 * 行级章名匹配：规则表 + 首字符预筛。
 *
 * 预筛是性能的关键：一本 20MB 的小说约 20 万行，不做预筛就是「11 条正则 × 20 万行」。
 * 预筛只看**去掉行首缩进后的首字节**（UTF-16 看首个代码单元），O(1) 就能把
 * 99% 的正文行挡在解码之前。
 */
class ChapterMatcher
{
public:
    struct Hit
    {
        QString title;  ///< 章名（正则命中的整行，已去首尾空白）
        QString ruleId; ///< 命中的规则
    };

    explicit ChapterMatcher(TextCodec::Encoding encoding);

    /// 一整行的字节（不含换行符）→ 命中项；不命中返回 nullopt
    std::optional<Hit> match(const char *data, qint64 size) const;

    /// 整行解码（**不**去首尾空白，标题需要保留原文；BOM 已跳过）
    QString decodeLine(const char *data, qint64 size) const;

    /// 该行开头属于本编码 BOM 的字节数（不是 BOM 返回 0）
    int bomLength(const char *data, qint64 size) const;

    /// 行首缩进（空格 / 制表符 / 全角空格）的字节数
    int indentLength(const char *data, qint64 size) const;

    TextCodec::Encoding encoding() const { return m_encoding; }

private:
    bool passesFilter(int ruleIndex, const char *data, qint64 size) const;

    TextCodec::Encoding m_encoding;
    int m_unit = 1;
    QVector<std::bitset<256>> m_firstBytes; ///< 1 字节编码：首字节位图
    QVector<QSet<quint16>> m_firstUnits;    ///< UTF-16：首个代码单元
    QVector<bool> m_filterEnabled;
    QVector<QByteArray> m_spacePrefixes; ///< 行首空白的字节形式
};

/**
 * 字节级「按行切分」扫描器（§5.1）。
 *
 * 只在**字节**上找行边界，绝不先解码再切行：章偏移必须能直接拿去 Range 读取，
 * 而解码后的字符下标无法可靠还原成字节偏移（非法字节、代理对、跨块拼接都会错位）。
 *
 * 分块任意切：切在行中间、切在多字节字符中间都不会漂移 —— 残余字节留在缓冲里，
 * 与下一块拼起来再切（UTF-16 会额外保证按代码单元对齐）。
 */
class ChapterLineScanner
{
public:
    /// 回调里的 data 指向行首字节，仅在回调期间有效；end - start = 行长（不含 \r\n）
    using LineCallback = std::function<void(const char *data, qint64 start, qint64 end)>;

    explicit ChapterLineScanner(TextCodec::Encoding encoding);

    /// 追加一块数据（必须按文件顺序）
    void append(const QByteArray &chunk, const LineCallback &onLine);

    /// 文件读完：把最后一行（没有换行结尾）也交出去
    void finish(const LineCallback &onLine);

    /// 已喂入的字节数（= 下一块的起始偏移）
    qint64 consumed() const { return m_consumed; }

    /// 还没凑成整行的字节数
    qint64 pendingBytes() const { return m_buffer.size(); }

private:
    TextCodec::Encoding m_encoding;
    int m_unit = 1;
    QByteArray m_buffer;      ///< 上一块留下的半行
    qint64 m_bufferStart = 0; ///< m_buffer[0] 的绝对字节偏移
    qint64 m_consumed = 0;    ///< 累计喂入字节数
};

} // namespace myhub
