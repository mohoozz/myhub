#pragma once

#include <QAbstractListModel>
#include <QHash>
#include <QQmlEngine>
#include <QStringList>
#include <QVector>
#include <memory>

#include "core/storage/StorageError.h"

namespace myhub {

class StorageAdapter;

/**
 * 回收站列表模型（§3.3）。
 *
 * 跨连接源聚合：遍历所有启用的连接源，读取各自挂载点下的 `.trash`
 * 与 `<name>.meta.json`，合成一张列表（每条携带所属连接源）。
 *
 * 纪律：
 *   - **元数据丢失的条目不可还原**（不猜测原路径），只能彻底删除
 *   - **过期静默清理**：进页/刷新时把超过保留天数的条目直接彻底删除，
 *     失败只记日志不弹窗（后台行为，不打扰用户）
 *   - **操作成功后本地立即移除行**，不整页刷新
 *   - 单测可直接构造本模型（需先把连接源与适配器准备好）
 */
class TrashModel : public QAbstractListModel
{
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(int count READ rowCount NOTIFY countChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(QString statusText READ statusText NOTIFY statusTextChanged)
    Q_PROPERTY(
        int retentionDays READ retentionDays WRITE setRetentionDays NOTIFY retentionDaysChanged)

public:
    enum Roles
    {
        TrashNameRole = Qt::UserRole + 1,
        NameRole,
        OriginalPathRole,
        OriginalDirRole,
        IsDirRole,
        SizeRole,
        DeletedAtRole, ///< epoch 毫秒；0 表示元数据缺失
        DaysLeftRole,  ///< 距自动清理的天数；-1 表示无元数据/不适用
        ConnectionIdRole,
        ConnectionNameRole,
        MediaKindRole, ///< 交给 FileTypeIcon 的图标分类
        RestorableRole,
        ExpiredRole,
    };
    Q_ENUM(Roles)

    explicit TrashModel(QObject *parent = nullptr);
    ~TrashModel() override;

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    bool loading() const { return m_loading; }
    /// 是否有文件操作在进行（还原/彻底删除共用 FileOperations 的忙碌态）
    bool busy() const;
    QString statusText() const { return m_statusText; }
    int retentionDays() const;

    /// 设置为 0 或负数时回落到默认保留天数
    void setRetentionDays(int days);

    /// 重新扫描所有连接源的回收站，并顺带静默清理过期条目
    Q_INVOKABLE void refresh();

    /// 单行数据（供 QML 取详情/确认框文案）
    Q_INVOKABLE QVariantMap get(int row) const;

    /// 还原一行（原路径已有同名条目时自动顺延序号）
    Q_INVOKABLE void restoreRow(int row);

    /// 彻底删除一行（不可恢复，UI 须二次确认）
    Q_INVOKABLE void purgeRow(int row);

    /// 清空全部（不可恢复，UI 须二次确认）
    Q_INVOKABLE void purgeAll();

signals:
    void countChanged();
    void loadingChanged();
    void busyChanged();
    void statusTextChanged();
    void retentionDaysChanged();

    /// 单行还原成功
    void restored(const QString &name, const QString &targetPath);
    /// 彻底删除成功（count 为条数）
    void purged(int count);
    /// 操作失败：title 是「哪个操作」，reason 是具体原因
    void failed(const QString &title, const QString &reason);

private:
    struct Item
    {
        QString trashName;
        QString name;
        QString originalPath;
        QString connectionId;
        QString connectionName;
        QString mediaKind;
        bool isDir = false;
        bool hasMeta = false;
        qint64 size = 0;
        qint64 deletedAtMs = 0;
        qint64 modTimeMs = 0;

        QString originalDir() const;
        bool restorable() const { return hasMeta; }
        int daysLeft(int retentionDays) const;
        bool expired(int retentionDays) const;
    };

    /// 一次扫描的共享状态（多连接源 × 多条目，回调跨多轮事件循环）
    struct Scan;
    using ScanPtr = std::shared_ptr<Scan>;

    void setLoading(bool loading);
    void setStatusText(const QString &text);

    void scanConnection(const ScanPtr &scan, int connectionIndex);
    void readEntryMeta(const ScanPtr &scan, int connectionIndex, int entryIndex);
    void finishScan(const ScanPtr &scan);

    void replaceItems(QVector<Item> items);
    void removeRowsAt(const QList<int> &rows);
    StorageAdapter *adapterFor(const QString &connectionId);
    int indexOfTrashName(const QString &connectionId, const QString &trashName) const;

    /// 静默清理过期条目（失败不打扰用户）
    void purgeExpired();

    QVector<Item> m_items;
    bool m_loading = false;
    QString m_statusText;
};

} // namespace myhub
