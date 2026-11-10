#pragma once

#include <QDateTime>
#include <QString>

namespace myhub {

/// 展示层格式化
class Formatters
{
public:
    /// 1.2 GB / 345 MB / 12 KB
    static QString fileSize(qint64 bytes);

    /// 01:23:45 或 23:45
    static QString duration(qint64 seconds);

    /// 「3 分钟前 / 昨天 / 10月12日」—— 用于「正在阅读」最后阅读时间（PC-209）
    static QString relativeTime(const QDateTime &time);

    /// 2026-10-14 15:30
    static QString absoluteTime(const QDateTime &time);

    /// 百分比整数（0~100）
    static QString percent(double ratio);
};

} // namespace myhub
