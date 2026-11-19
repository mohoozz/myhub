#pragma once

namespace myhub {

class AppDatabase;

/**
 * 版本化迁移器（需求文档 §2.3 / §5.3）。
 *
 * Schema 与 iOS 端完全同构（9 张表、唯一约束、外键级联、索引一致），
 * 保证两端数据模型一致、配置可互导。
 *
 * 版本历史：
 *   v1 v1_initial              —— 9 张表与索引
 *   v2 v2_reading_fingerprint  —— readingProgress 增加 fileSize / modTime 指纹列
 *   v3 v3_novel_chapter_cache  —— novelChapter 章节解码产物缓存表
 *   v4 v4_comic_page_list      —— comicPages 漫画页名清单
 *   v5 v5_epub_meta            —— epubMeta 的 epub 目录 / 元数据快照
 */
class Migrations
{
public:
    /// 目标 schema 版本
    static constexpr int kTargetVersion = 5;

    /// 执行迁移至最新版本；返回是否成功
    static bool migrate(AppDatabase &db);

private:
    static bool v1_initial(AppDatabase &db);
    static bool v2_reading_fingerprint(AppDatabase &db);
    static bool v3_novel_chapter_cache(AppDatabase &db);
    /// v4：漫画页名清单（`comicPages`），支撑秒开与离线阅读
    static bool v4_comic_page_list(AppDatabase &db);
    /// v5：epub 目录 / 元数据快照（`epubMeta`），支撑离线打开
    static bool v5_epub_meta(AppDatabase &db);
};

} // namespace myhub
