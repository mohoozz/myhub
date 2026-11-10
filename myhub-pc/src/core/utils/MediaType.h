#pragma once

#include <QString>

namespace myhub {

/**
 * 文件类型识别（需求文档 §8.1 支持的文件格式）。
 *
 * 打开方式分发规则（§14.1）：
 *   txt           → 纯文本阅读器（右键可改小说阅读器）
 *   epub          → 按图集判定：图集 → 漫画阅读器，普通 → 小说阅读器
 *   zip/cbz/rar/cbr → 漫画阅读器
 *   图片           → 独立图片预览器（区别于漫画阅读器）
 */
class MediaType
{
public:
    enum Kind
    {
        Unknown = 0,
        Directory,
        Video,
        Audio,
        Novel, ///< txt / epub（非图集）
        Comic, ///< zip / cbz / rar / cbr / epub（图集）
        Image,
        Subtitle,
        Text, ///< 纯文本（txt 默认走这里）
    };

    static Kind fromExtension(const QString &ext);
    static Kind fromPath(const QString &path, bool isDir = false);

    static bool isVideo(const QString &ext);
    static bool isAudio(const QString &ext);
    static bool isImage(const QString &ext);
    static bool isComicArchive(const QString &ext);
    static bool isNovel(const QString &ext);
    static bool isSubtitle(const QString &ext);

    /// 是否为可播放媒体（音视频）
    static bool isPlayable(const QString &ext);

    /**
     * 是否支持「在线编辑并保存回源」（PC-103）。
     *
     * 正文类（txt/md/log…）+ 字幕 + 常见配置/代码文本；二进制与影音一律不可编辑。
     */
    static bool isEditableText(const QString &path, bool isDir = false);

    /// 类型的中文名（用于属性面板 / 徽标）
    static QString displayName(Kind kind);

    /// 类型徽标标识（QML 侧按此选图标）
    static QString badgeId(Kind kind);

    /// 徽标标识反查类型（收藏表只存徽标串，读回时用）
    static Kind fromBadgeId(const QString &badge);

    /// 徽标标识直接取中文名（收藏页行数据用，避免调用方自己 switch）
    static QString displayNameForBadge(const QString &badge);
};

} // namespace myhub
