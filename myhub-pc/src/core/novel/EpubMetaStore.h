#pragma once

#include "core/novel/EpubBook.h"

#include <QString>
#include <QVector>

namespace myhub {

/**
 * 一本 epub 的「目录 + 元数据」快照（书名 / 作者 / 语言 / 封面条目 / 章节清单）。
 *
 * 单独成一个结构体而不是裸 `EpubMetadata`：快照必须和**指纹**一起用 ——
 * 目录是「打开那一刻的 OPF 内容」，文件被换过之后同名章节可能已经是另一篇。
 */
struct EpubMeta
{
    QString title;
    QString author;
    QString language;
    /// OPF 声明过的封面条目（zip 内路径）；没声明时为空
    QString coverHref;
    QVector<EpubChapterRef> chapters;
    qint64 fileSize = 0;
    qint64 modTime = 0;

    bool isValid() const { return !chapters.isEmpty(); }
};

/**
 * epub 目录快照的持久化（§5「epub 元数据快照」、§13 离线阅读）。
 *
 * 为什么值得存：epub 的目录不在正文里，要先 stat 到长度才能按 Range 读 zip 条目表 →
 * container.xml → OPF → NAV/NCX。源够不着（离线 / 超时 / 文件被移走）时第一步就失败，
 * 阅读器连「这本书有几章」都答不上来，只能开一个没有目录的空壳。
 *
 * 存下来之后：
 *   · 源够不着时靠这一行还原章数与章名，进降级阅读，在已缓存的章之间照常翻；
 *   · 指纹一并存下，离线时把它恢复出来，章节缓存键（`NovelChapterCache`）仍然对得上。
 *
 * 与 `ComicPageStore` / `NovelIndexStore` 同一套约定：一张表、一行一本书、
 * 指纹冗余在行上；任何异常都退化成「未命中」，绝不让缓存问题打断阅读。
 */
class EpubMetaStore
{
public:
    /// 写快照（有则覆盖）。失败只记日志，不影响阅读
    static bool save(const QString &connectionId, const QString &path, const EpubMeta &meta);

    /// 只按「连接源 + 路径」取，**不校验指纹**：离线打不开文件时，指纹从这一行里恢复
    static bool find(const QString &connectionId, const QString &path, EpubMeta *out);

    static bool remove(const QString &connectionId, const QString &path);
    /// 删目录时连带清掉子树下的快照；返回清掉的行数
    static int removeSubtree(const QString &connectionId, const QString &path);
    static int renamePath(const QString &connectionId, const QString &oldPath,
                          const QString &newPath);
    static int count();

    /// JSON 编解码（`{title, author, language, cover, chapters:[{title,href,level}]}`）
    static QString encode(const EpubMeta &meta);
    static bool decode(const QString &json, EpubMeta *out);
};

} // namespace myhub
