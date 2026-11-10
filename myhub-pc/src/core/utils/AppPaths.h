#pragma once

#include <QString>

namespace myhub {

/**
 * 应用目录（需求文档 §2.3 本地数据存储）。
 *
 * Windows: %APPDATA%\MyHub（数据）/ %LOCALAPPDATA%\MyHub\Cache（缓存）/ %APPDATA%\MyHub\Logs
 * macOS:   ~/Library/Application Support/MyHub / ~/Library/Caches/MyHub / ~/Library/Logs/MyHub
 *
 * 纪律：进度等不可重建数据放 dataDir，可重建内容一律放 cacheDir。
 */
class AppPaths
{
public:
    /// 结构化数据目录（数据库、备份、偏好）
    static QString dataDir();
    /// 可重建缓存目录（分片 / 封面 / 漫画页 / 小说章节 / 目录列表）
    static QString cacheDir();
    /// 日志与崩溃报告
    static QString logDir();
    /// 数据库自动备份目录（保留 7 份）
    static QString backupDir();
    /// 默认下载落地目录（下载/MyHub）
    static QString defaultDownloadDir();

    /// 数据库文件完整路径
    static QString databaseFile();
    /// 偏好文件完整路径（QSettings INI 后端）
    static QString settingsFile();

    /// 缓存分区子目录（§5.5）
    static QString cachePartition(const QString &name);

    /// 确保目录存在，返回是否可用
    static bool ensureDir(const QString &path);

    /// 首次运行时创建全部目录
    static void initializeAll();
};

} // namespace myhub
