#pragma once

#include <QByteArray>
#include <QString>

namespace myhub {

/**
 * 回收站布局（PC-106）。
 *
 * 挂载点根下固定一个 `.trash/` 目录（各适配器列举时已将其排除，用户看不到）：
 *
 *   `.trash/<name>`            被删除的条目，保持原名
 *   `.trash/<name>.meta.json`  元数据（原路径 + 删除时间），还原与过期清理所需
 *
 * 纪律（iOS 实战经验）：
 *   - **同名不覆盖**：已存在则依次尝试 `<base> (1)<ext>`、`<base> (2)<ext>`…
 *     删除与还原两侧共用同一套命名规则，不会出现「删进去就还不了」
 *   - 元数据写失败**不回滚**已完成的移动：宁可留一个无主条目，也不能把用户文件弄丢
 *   - 时间一律 epoch 毫秒，跨时区/夏令时不会算错过期
 */
class TrashStore
{
public:
    /// 回收站目录的虚拟路径（挂载点根下）
    static QString trashDir();

    /// 回收站内某条目的虚拟路径
    static QString entryPath(const QString &trashName);

    /// 回收站内某条目元数据的虚拟路径
    static QString metaPath(const QString &trashName);

    /**
     * 冲突时依次尝试的名字。
     * @param originalName 原文件名（含扩展名）
     * @param attempt      0 表示原名；n 表示 `<base> (n)<ext>`（扩展名保留在序号之后）
     */
    static QString candidateName(const QString &originalName, int attempt);

    /// 元数据文件（列表与还原扫描时须跳过）
    static bool isMetaName(const QString &name);

    /// 是否为回收站目录本身
    static bool isTrashDir(const QString &path);

    struct Meta
    {
        QString connectionId;
        QString originalPath;
        qint64 deletedAtMs = 0;

        bool isValid() const { return !originalPath.isEmpty() && deletedAtMs > 0; }
    };

    static QByteArray encodeMeta(const Meta &meta);
    /// 解析失败返回 invalid Meta（调用方按「无主条目」处理，不猜测原路径）
    static Meta decodeMeta(const QByteArray &json);

    /// 名称冲突时的最大尝试次数（防御性上限，避免异常数据导致死循环）
    static constexpr int kMaxNameAttempts = 999;
};

} // namespace myhub
