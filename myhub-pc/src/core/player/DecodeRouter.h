#pragma once

#include <QString>
#include <QStringList>

namespace myhub {

/**
 * 影响**硬件解码可行性**的容器粗分类。
 *
 * 不做完整格式识别（那是 MediaType 与 mpv 的事）：这里只关心
 * 「这个容器里常见的主视频流有没有硬件解码器」。
 */
enum class MediaContainer
{
    Unknown = 0,
    Mp4,      ///< mp4 / mov / m4v
    Matroska, ///< mkv / mka
    Webm,
    Avi,
    Flv,
    MpegTs, ///< ts / m2ts / mts
    MpegPs, ///< mpg / mpeg（含 VCD/SVCD）
    Vob,    ///< DVD 视频对象
    RealMedia,
    Asf, ///< wmv / asf
    Ogg,
};

/// 一次解码路由的结论
struct DecodeDecision
{
    QString hwdec;       ///< 直接写给 mpv 的 `hwdec` 选项值
    bool forced = false; ///< 用户强制偏好：不得再被自动回退改判
    QString reason;      ///< 诊断用：`preference:software` / `container:rmvb` / `auto`
};

/**
 * 解码路由（《需求分析文档》§4.3「双引擎解码策略」）。
 *
 * 决策优先级：**用户偏好强制** > **已知无硬解/硬解不可靠的容器** > 默认硬解优先。
 *
 * 为什么要有这一层：
 *  1. `hwdec=auto-safe` 只解决「没有硬解器就软解」，解决不了「硬解器存在但
 *     解出来没声音」（DTS/TrueHD/E-AC-3）——那种情况只能靠运行期回退重载，
 *     代价是黑屏一次、起播慢一截；
 *  2. rmvb/avi/flv/wmv 这类容器的主视频流（RealVideo / Xvid / VP6 / VC-1）
 *     基本没有可用硬解器，提前判软解可省掉这次重载。
 *
 * 探测方式：本地文件读前 200 字节魔数（一次同步读，失败即按扩展名兜底）；
 * 远程 URL（回环代理 / WebDAV）不做网络探测，只按扩展名判断——
 * 读远端会引入超时与额外请求，收益不足以抵消。
 */
class DecodeRouter
{
public:
    /// 已知「就地软解更稳」的扩展名（不含点，小写）
    static QStringList softwareOnlySuffixes();

    /// 仅按扩展名判断容器
    static MediaContainer fromSuffix(const QString &source);

    /// 本地文件按魔数、远程只按扩展名
    static MediaContainer probe(const QString &source);

    static QString containerName(MediaContainer container);

    /// 是否需要（可以）让 mpv 用硬解：判据见类注释的优先级
    static DecodeDecision decide(const QString &preference, const QString &source);
};

} // namespace myhub
