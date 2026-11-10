#pragma once

#include <QDateTime>
#include <QList>
#include <QString>

namespace myhub {

/// 目录条目（与 iOS 端 FileEntry 同构，见需求文档 §4.4）
struct FileEntry
{
    QString name;
    QString path; ///< 归一化虚拟路径
    bool isDir = false;
    qint64 size = 0;
    QDateTime modTime;
    QString ext; ///< 小写扩展名，不含 '.'

    /// 文件指纹（size + modTime）—— 用于校验文件是否被替换（需求文档 §1.5）
    QString fingerprint() const
    {
        return QStringLiteral("%1:%2").arg(size).arg(modTime.isValid() ? modTime.toSecsSinceEpoch()
                                                                       : 0);
    }

    bool isValid() const { return !path.isEmpty(); }
};

using FileEntryList = QList<FileEntry>;

} // namespace myhub

Q_DECLARE_TYPEINFO(myhub::FileEntry, Q_RELOCATABLE_TYPE);
