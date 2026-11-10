#pragma once

#include <QByteArray>
#include <QString>

namespace myhub {

/**
 * 文本编码检测与转换（PC-103「txt 在线编辑」、PC-108「纯文本查看器」共用）。
 *
 * 纪律（需求文档 §2.5「编码检测（重要）」）：
 *   - **BOM 优先**；无 BOM 时按「UTF-8 严格校验 → UTF-16 零字节启发式 → GB18030 / Big5 打分」判定
 *   - **保存沿用原编码**；编辑后的字符原编码无法表示时回退 UTF-8（并告知调用方，不静默丢字）
 *   - 纯函数、不触网、不依赖 QtGui，可被 QTest 直接覆盖
 *
 * GB18030 与 Big5 的双字节区间大量重叠（如 A4 40 两边都合法），
 * 单靠「能否解码」无法区分，故用常用字命中率打分择优（错解出来的多是生僻字串）。
 */
class TextCodec
{
public:
    enum Encoding
    {
        Unknown = 0,
        Utf8,
        Utf16LE,
        Utf16BE,
        Gb18030,
        Big5,
    };

    struct Decoded
    {
        QString text;
        Encoding encoding = Unknown;
        bool hadBom = false;
        /// 解码过程中遇到非法字节（已用替换符兜底，不应视为「检测失败」）
        bool hadErrors = false;
    };

    struct Encoded
    {
        QByteArray data;
        /// 实际写入用的编码（回退时为 Utf8）
        Encoding encoding = Utf8;
        /// 要求的编码无法表示部分字符，已按纪律回退 UTF-8
        bool fellBackToUtf8 = false;
    };

    /// 展示名：UTF-8 / GB18030 / Big5 / UTF-16 LE / UTF-16 BE
    static QString name(Encoding encoding);

    /// 按展示名反查（未知名称 → Unknown）
    static Encoding fromName(const QString &name);

    /// 仅检测编码（不产出文本）
    static Encoding detect(const QByteArray &data);

    /// 检测 + 解码
    static Decoded decode(const QByteArray &data);

    /**
     * 按指定编码编码。
     *
     * @param withBom 是否写 BOM（沿用原文是否带 BOM 的判定）
     * 编码失败（含不可表示字符）时自动回退 UTF-8 并置 fellBackToUtf8。
     */
    static Encoded encode(const QString &text, Encoding encoding, bool withBom = false);

    /// 供 UI 预判：该编码能否无损表示这段文本
    static bool canEncode(const QString &text, Encoding encoding);
};

} // namespace myhub
