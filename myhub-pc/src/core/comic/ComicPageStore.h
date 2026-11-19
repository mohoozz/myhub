#pragma once

#include <QString>
#include <QStringList>

namespace myhub {

/**
 * 一本漫画的「页名清单」快照（压缩包里按阅读顺序排好的条目名）。
 *
 * 单独成一个结构体而不是裸 `QStringList`：清单必须和**指纹**一起用 ——
 * 页码只是「打开那一刻的顺序」，压缩包被重新打包过，同样的第 3 页可能已经是另一张图。
 */
struct ComicPageList
{
    QStringList pages;
    qint64 fileSize = 0;
    qint64 modTime = 0;

    bool isValid() const { return !pages.isEmpty(); }

    /// 清单还对不对得上这个文件（大小相等 + 修改时间差不超过 2 秒）
    bool matchesFile(qint64 size, qint64 modTimeMs) const;
};

/**
 * 页名清单的持久化（§5、§6 PC-207 的「页名清单持久化」）。
 *
 * 为什么值得存：页名只能从压缩包里读出来 —— zip 要读尾部队列表，
 * 远程 cbr 干脆要整包在手。存下来之后：
 *   · 重开同一本，页数与页序**立刻**就有，续读页只要在盘上就直接上屏；
 *     归档在后台照旧打开，只为「还没缓存的那几页」服务；
 *   · 源够不着（离线 / 超时）时还能靠它 + 页缓存进降级阅读，读过的页一本不会少。
 *
 * 与 `NovelIndexStore` 同一套约定：一张表、一行一本书、指纹冗余在行上，
 * 文件一变旧行自然失配（离线时反而能用它把指纹**恢复**出来）。
 */
class ComicPageStore
{
public:
    /// 写清单（有则覆盖）。失败只记日志，不影响阅读
    static bool save(const QString &connectionId, const QString &path, const QStringList &pages,
                     qint64 fileSize, qint64 modTimeMs);

    /// 按指纹取清单：文件已变（或被重新打包）返回 false
    static bool load(const QString &connectionId, const QString &path, qint64 fileSize,
                     qint64 modTimeMs, ComicPageList *out);

    /// 只按「连接源 + 路径」取，**不校验指纹**：离线打不开文件时，指纹从这一行里恢复
    static bool find(const QString &connectionId, const QString &path, ComicPageList *out);

    static bool remove(const QString &connectionId, const QString &path);
    /// 删目录时连带清掉子树下的清单；返回清掉的行数
    static int removeSubtree(const QString &connectionId, const QString &path);
    static int renamePath(const QString &connectionId, const QString &oldPath,
                          const QString &newPath);
    static int count();

    /// JSON 编解码（`["p/1.png","p/2.png"]`）；坏数据一律当未命中
    static QString encode(const QStringList &pages);
    static bool decode(const QString &json, QStringList *out);
};

} // namespace myhub
