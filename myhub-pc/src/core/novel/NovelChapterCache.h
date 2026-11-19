#pragma once

#include "core/novel/TxtChapterLoader.h"

#include <QList>
#include <QString>
#include <QStringList>

namespace myhub {

/**
 * 章节解码产物落盘（§5 `NovelChapterCache`、§13「小说章节缓存本地化」）。
 *
 * 缓存的是**解码后的成品**，不是原始字节：
 *   - txt：整张行表（每行的文本 + 起止字节偏移）。行表一起存是硬要求 ——
 *     进度锚点是全局字节偏移，没有行表就换算不出段落下标，命中缓存也定不了位；
 *   - epub：段落数组。epub 的锚点是「章号 + 段落下标」，本来就不依赖字节坐标。
 *
 * 指纹：`fileSize + modTime`，与 `NovelIndexStore` 同语义。任一不符即当未命中：
 * 文件被追加过、章节边界全变，旧章节正文拿来显示只会让读者读到别人的段落。
 * 例外是**调用方拿不到指纹**（离线、stat 失败）：这时按「宁可信其有」放行，
 * 因为离线阅读本来就是这条缓存的头号用途。
 *
 * 写入则**要求指纹已知**：离线时读到的新章没法打指纹，写进去的行以后永远对不上号。
 *
 * 一切异常都退化成「未命中」，绝不让缓存问题打断阅读：
 * 解压失败、JSON 坏掉、偏移不递增、版本号不认识 —— 全部返回 false，上层重读文件。
 */
class NovelChapterCache
{
public:
    /// 文件指纹；`fileSize <= 0` 表示「不知道」（离线 / stat 失败）
    struct Fingerprint
    {
        qint64 fileSize = 0;
        qint64 modTime = 0;

        bool known() const { return fileSize > 0; }
        bool matches(qint64 size, qint64 modTimeMs) const;
        /// 调用方指纹未知时放行：离线场景没有别的依据可用
        bool accepts(qint64 size, qint64 modTimeMs) const
        {
            return !known() || matches(size, modTimeMs);
        }
    };

    /**
     * 单章写入上限（压缩前）。
     *
     * 正常一章 3~10KB；只有「未识别章节、按整本单章」的兜底会到几十 MB ——
     * 那种情况读一次就要 4MB，落库既慢又没意义（用户不会反复重开整本）。
     */
    static constexpr int kMaxPayloadBytes = 1 * 1024 * 1024;

    /// 缓存行总量上限：超过就按最后访问时间淘汰（一页约 10KB，400 行 ≈ 4MB）
    static constexpr int kMaxRows = 400;

    /// txt：命中则还原整章（行偏移原样保留，锚点照常工作）
    static bool loadTxt(const QString &connectionId, const QString &path,
                        const Fingerprint &fingerprint, int chapter, TxtChapterText *out);
    static bool saveTxt(const QString &connectionId, const QString &path,
                        const Fingerprint &fingerprint, int chapter, const TxtChapterText &text);

    /// epub：命中则还原这一章的段落
    static bool loadEpub(const QString &connectionId, const QString &path,
                         const Fingerprint &fingerprint, int chapter, QStringList *out);
    static bool saveEpub(const QString &connectionId, const QString &path,
                         const Fingerprint &fingerprint, int chapter,
                         const QStringList &paragraphs);

    /// 丢掉这本书指纹已变的行（换版本 / 换设备后重扫时调用，防止旧行堆到上限把新行挤掉）
    static int dropStale(const QString &connectionId, const QString &path,
                         const Fingerprint &fingerprint);

    /// 按 updatedAt 淘汰超量行；返回删掉的行数
    static int trim(int keep = kMaxRows);

    /// 整本书的章节缓存（删单本时用）
    static int remove(const QString &connectionId, const QString &path);

    /// 删除目录时连同子孙缓存一并清掉；返回删掉的行数
    static int removeSubtree(const QString &connectionId, const QString &path);

    /**
     * 重命名 / 移动后同步缓存路径（目录则连同子孙前缀一起改写）；返回改写的行数。
     *
     * 覆盖式移动（目标路径已有同书的旧缓存）时，目标行先被删掉再让位 ——
     * 唯一键是 `(connectionID, filePath, chapterIndex)`，硬 UPDATE 会撞键；
     * 而目标那份缓存本来也属于被覆盖掉的那个文件，留着只会按指纹失配被当垃圾。
     */
    static int renamePath(const QString &connectionId, const QString &oldPath,
                          const QString &newPath);

    /**
     * 这本书已经有缓存的章号（升序）。
     *
     * 只给「文件不可用」那条路用：离线打开时靠它判断「至少还有一章能读」，
     * 以及续读章恰好没缓存时退到隔壁。**不校验指纹** —— 都离线了，没有指纹可比，
     * 有正文总比空白屏强（缓存在线时写入，指纹由当时的 stat 决定）。
     */
    static QList<int> cachedChapters(const QString &connectionId, const QString &path);

    static int count();

private:
    /// 行写入（payload 已编码）
    static bool store(const QString &connectionId, const QString &path,
                      const Fingerprint &fingerprint, int chapter, const QString &title,
                      const QByteArray &payload);

    /// 行读出（指纹校验通过才返回 payload）
    static QByteArray fetch(const QString &connectionId, const QString &path,
                            const Fingerprint &fingerprint, int chapter);
};

} // namespace myhub
