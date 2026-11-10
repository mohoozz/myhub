#pragma once

#include <QString>
#include <QStringList>

namespace myhub {

/**
 * 虚拟路径工具（移植自 iOS 端 StoragePath）。
 *
 * 应用内一律使用以 '/' 开头的归一化虚拟路径，与平台分隔符无关；
 * 真实路径的拼装由各 StorageAdapter 自行完成。
 */
class StoragePath
{
public:
    /// 归一化：统一分隔符、折叠重复斜杠、解析 "." 与 ".."、去掉尾部斜杠（根除外）
    static QString normalize(const QString &path);

    /// 拼接子路径
    static QString join(const QString &base, const QString &child);

    /// 文件名（含扩展名）
    static QString fileName(const QString &path);

    /// 去掉扩展名的文件名
    static QString baseName(const QString &path);

    /// 父目录；根目录返回 "/"
    static QString parent(const QString &path);

    /// 小写扩展名，不含 '.'；无扩展名返回空
    static QString extension(const QString &path);

    /// 是否为根
    static bool isRoot(const QString &path);

    /// 拆分为各级片段（不含空片段）
    static QStringList segments(const QString &path);

    /// path 是否位于 ancestor 之下（或相等）
    static bool isDescendantOf(const QString &path, const QString &ancestor);

    /// 用于 URL 的百分号编码（逐段编码，保留 '/'）
    static QString percentEncoded(const QString &path);
};

} // namespace myhub
