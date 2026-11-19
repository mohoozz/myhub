#pragma once

#include <QString>
#include <QStringList>

namespace myhub {
namespace BundledFonts {

/// 字体分组：正文黑体用 Sans 组，宋体用 Serif 组（两组各自独立，互不顶替）
enum class Group
{
    Sans,
    Serif,
};

/**
 * 内置字体（「消除跨平台字形差异」）。
 *
 * 为什么要内置：宋体回退链 `Source Han Serif SC → Songti SC → SimSun` 在每个平台上
 * 命中的都是**不同的字**——Windows 是 SimSun，macOS 是 Songti SC，Linux 可能直接落到
 * sans-serif。同一本书排版结果不一样，行数/页数就跟着变，跨端续读的锚点也会漂。
 *
 * 做法：把 OFL 授权的思源宋体子集打进 qrc（`:/fonts/serif/`，见 resources/fonts.qrc），
 * 启动时注册一次，并把注册到的族名**插到回退链最前面**（`NovelBridge::familiesForStyle`）。
 * 这样即使系统里一个中文字体都没有，也还有一套确定的字形可用。
 *
 * 另外支持「投递目录」（`<dataDir>/fonts/serif|sans`）：用户自己丢一个 .otf 进去重启
 * 即生效，不必重新打包。qrc 优先于投递目录（同一族名只留先注册的结果）。
 */

/// 用户投递目录（可能不存在）
QString dropInDir(Group group);

/**
 * 注册一个目录下的全部字体文件（`*.ttf/*.otf/*.ttc/*.otc`，按文件名排序保证确定性）。
 *
 * 返回**本次新拿到**的族名；目录不存在或文件坏掉都只记日志、不抛错 ——
 * 字体是锦上添花，绝不能因为它起不来。
 */
QStringList registerFontDir(const QString &dirPath, Group group);

/// 启动时扫一遍：qrc 内置 → 用户投递目录。幂等，重复调用不会重复注册
void initialize();

/// 已注册的族名（内置在前）
QStringList families(Group group);
QStringList serifFamilies();
QStringList sansFamilies();

} // namespace BundledFonts
} // namespace myhub
