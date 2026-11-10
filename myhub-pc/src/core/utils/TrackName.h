#pragma once

#include <QString>

namespace myhub {

/**
 * 「作者 - 标题」文件名解析（§4.3 AudioCoverView / §4.5 系统媒体信息共用）。
 *
 * 这里只做**文件名层面**的启发式解析：真正的标签（ID3 / FLAC Vorbis / MP4 ilst）
 * 要等标签库接入，本类只保证「文件名里已经有的信息不丢」，且同一部音频在
 * 全屏封面、mini 条、系统媒体信息三处显示一致——三处都调这一个函数。
 *
 * 支持写法（先去目录与扩展名，再去前导音轨号）：
 *   `01. Artist - Title`  → artist=Artist, title=Title
 *   `Artist – Title`      → 同上（en dash）
 *   `Artist — Title`      → 同上（em dash）
 *   `Artist－Title`       → 同上（全角连字符，允许无空格）
 *   `01 - Title`          → artist 为空（左侧纯数字视为音轨号）
 *   `Title`               → artist 为空，title=Title
 *
 * 不切分的写法：`AC-DC - Back In Black` 只按带空格的破折号切，
 * 因此乐队名里的连字符不会被吃掉。
 */
class TrackName
{
public:
    struct Parts
    {
        QString artist;
        /// 总有值：解析不出标题时回退为去扩展名的文件名
        QString title;
    };

    /// @param fileName 文件名或完整路径（含扩展名也可以）
    static Parts parse(const QString &fileName);
};

} // namespace myhub
