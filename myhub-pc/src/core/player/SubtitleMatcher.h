#pragma once

#include <QString>
#include <QStringList>

namespace myhub {

/**
 * 外挂字幕的「同目录同名」匹配（§4.3 SubtitleManager）。
 *
 * 规则与 mpv 的 `--sub-auto=fuzzy` 对齐，但只在**同目录**里找，且只认两种形态：
 *
 *   `影片.mkv` + `影片.srt`            → 精确同名，最高优先
 *   `影片.mkv` + `影片.zh.srt`         → 语言后缀，次优先；中文标记再加权
 *   `影片.mkv` + `影片.chs.forced.ass` → 多段标记同样认
 *
 * 明确**不认** `影片2.srt`、`影片-导演剪辑.srt` 这类「以影片名开头但不是后缀」的写法：
 * 宁可让用户手动选，也不能给他配一部错位的字幕。
 *
 * 纯静态工具，不碰 IO：目录列举由调用方（本地 QDir / 远程适配器）完成，便于单测。
 */
class SubtitleMatcher
{
public:
    /// 扩展名是否属于支持的文本字幕（srt / ass / ssa / vtt / sub）
    static bool isSubtitleFile(const QString &fileName);

    /**
     * 给一份字幕打分。
     * @param videoBaseName 影片去扩展名的文件名（不带目录）
     * @return 0 = 不匹配；100 = 精确同名；80 + 10 = 带中文标记的语言后缀
     */
    static int score(const QString &videoBaseName, const QString &subtitleFileName);

    /**
     * 从同目录清单里挑最合适的一份。
     * @param fileNames 同目录下的文件名（只给文件名即可，带路径也能处理）
     * @return 命中的文件名（与传入形式一致）；无匹配返回空串
     */
    static QString pick(const QString &videoBaseName, const QStringList &fileNames);
};

} // namespace myhub
