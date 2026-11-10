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
 */
class Migrations
{
public:
    /// 目标 schema 版本
    static constexpr int kTargetVersion = 2;

    /// 执行迁移至最新版本；返回是否成功
    static bool migrate(AppDatabase &db);

private:
    static bool v1_initial(AppDatabase &db);
    static bool v2_reading_fingerprint(AppDatabase &db);
};

} // namespace myhub
