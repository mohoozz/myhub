#pragma once

#include "core/storage/FileEntry.h"

#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantMap>
#include <functional>
#include <memory>

namespace myhub {

class StorageAdapter;
class StorageError;
class RelayStream;

/**
 * 文件操作服务（PC-103 ~ PC-106 的核心逻辑，不含 UI）。
 *
 * 分层理由：本类只依赖 QtCore + 适配器 + 缓存 + 进度仓库，
 * 因此能被 QTest 直接覆盖；QML 侧经 app 层 `Files` 桥接转发。
 *
 * 纪律（iOS 实战经验）：
 *   - **操作成功后本地立即更新**：本类在成功后失效目录缓存并广播结果，
 *     由模型就地改写（不依赖网络刷新，弱网下界面依然正确，§3.2）
 *   - **占用/瞬时错误自动退避重试 2 次**（0.6s / 1.2s，§3.3）
 *   - **失败提示携带具体原因**，不得只说「删除失败」
 *   - **回收站同名不覆盖**，删除与还原共用同一套命名规则（TrashStore）
 *   - **文件操作联动阅读记录**：删除清记录、重命名改路径（§3.2）
 *   - 批量删除**只对未成功的剩余项**报失败，已移走的不重复处理（§3.3）
 */
class FileOperations : public QObject
{
    Q_OBJECT
public:
    static FileOperations &instance();

    /**
     * 名称合法性校验（纯函数，不做 IO）。
     * @return 空字符串表示合法，否则是可直接展示给用户的原因
     */
    static QString validateName(const QString &name);

    /// 冲突候选名：attempt 0 → 原名，n → `<base> (n)<ext>`
    static QString uniqueName(const QString &name, int attempt);

    /// 新建文件夹（parentPath 下的 name）
    void createFolder(StorageAdapter *adapter, const QString &connectionId,
                      const QString &parentPath, const QString &name);

    /// 就地重命名（同目录改名）
    void rename(StorageAdapter *adapter, const QString &connectionId, const QString &path,
                const QString &newName);

    /// 删除到回收站（`.trash` + 元数据）；连接源不支持回收站时直接报失败并给出原因
    void removeToTrash(StorageAdapter *adapter, const QString &connectionId,
                       const QStringList &paths);

    /// 永久删除（回收站不可用时的降级路径，UI 须二次确认）
    void removePermanently(StorageAdapter *adapter, const QString &connectionId,
                           const QStringList &paths);

    /**
     * 从回收站还原（§3.3）。
     *
     * 落盘位置为 meta 里记录的原路径；原父目录已被删则尝试重建；
     * 目标处已有同名条目时按 `name (1).ext` 顺延，**绝不覆盖**。
     */
    void restoreFromTrash(StorageAdapter *adapter, const QString &connectionId,
                          const QString &trashName, const QString &originalPath);

    /// 彻底删除回收站条目（连同 `.meta.json`），逐条进行并汇总失败原因
    void purgeTrash(StorageAdapter *adapter, const QString &connectionId,
                    const QStringList &trashNames);

    // ---------------- 文本在线读写（PC-103）----------------

    /**
     * 读取整个文本文件并自动识别编码（UTF-8 / GB18030 / Big5 / UTF-16）。
     *
     * 纪律：超过 8MB **直接报失败**，绝不静默截断（截断等于吞掉用户内容）；
     * 检测结果随 `textLoaded` 回传，保存时按原编码回写。
     */
    void loadText(StorageAdapter *adapter, const QString &connectionId, const QString &path);

    /**
     * 保存编辑后的文本。
     *
     * **沿用原编码**（`encodingName` 来自 `textLoaded`）；该编码无法表示新字符时
     * 回退 UTF-8，并通过 `textSaved` 的 `fellBackToUtf8` 告知 UI，不写问号、不丢字。
     */
    void saveText(StorageAdapter *adapter, const QString &connectionId, const QString &path,
                  const QString &text, const QString &encodingName, bool withBom);

    // ---------------- 属性面板（PC-110）----------------

    /**
     * 查询单个条目的属性。
     *
     * **现场 stat**：不复用目录列表里的行数据（可能是几分钟前的缓存），
     * 显示的大小/修改时间必须是此刻的真实值；再叠加该条目的阅读进度。
     *
     * 结果经 `inspected` 回传（info 已含可直接展示的格式化文案）；失败发 `inspectFailed`。
     * 连接源名称等只有 features 层知道的字段由调用方补齐。
     */
    void inspect(StorageAdapter *adapter, const QString &connectionId, const QString &path);

    // ---------------- 移动 / 复制（PC-104）----------------

    /// 移动/复制的目标位置（可与源是同一个连接源）
    struct TransferTarget
    {
        StorageAdapter *adapter = nullptr;
        QString connectionId;
        QString directory; ///< 目标目录（归一化虚拟路径）
    };

    struct TransferRequest
    {
        StorageAdapter *source = nullptr;
        QString sourceConnectionId;
        QStringList paths; ///< 源路径（文件或文件夹）
        TransferTarget target;
        bool copy = false; ///< true 复制，false 移动
    };

    /**
     * 移动 / 复制（PC-104）。
     *
     * 两条路线：
     *   - **同源**：文件交给适配器的 move / copy；文件夹递归展开
     *   - **跨源**：本机流式中转，逐文件 `readRange` 分块 → `RelayStream` → 目标 `writeFrom`，
     *     **不落大临时文件**；文件夹同样递归
     *
     * 纪律：目标同名**绝不覆盖**（`name (1).ext` 顺延）；单项失败不打断其余项，结束时汇总原因；
     * 移动成功后改写阅读记录路径，并失效两侧目录缓存（§3.2「操作后本地立即更新」）。
     *
     * @return 是否受理。false 表示未开始（已有任务在跑 / 连接源不可用 / 无有效路径），
     *         此时已发出 `failed` 但不发 `transferFinished`，UI 不得进入进度态。
     */
    bool moveOrCopy(const TransferRequest &request);

    /// 取消正在进行的移动/复制（已完成的项不回滚）
    void cancelTransfer();

    bool transferring() const { return m_transferring; }

    bool busy() const { return m_active > 0; }

signals:
    /// 新建成功：parentPath 下出现了 path
    void created(const QString &parentPath, const QString &path, bool isDir);
    /// 重命名成功（同目录，oldPath → newPath）
    void renamed(const QString &oldPath, const QString &newPath);
    /// 删除成功（toTrash 为 false 表示永久删除）
    void removed(const QStringList &paths, bool toTrash);
    /// 还原成功：targetPath 为实际落盘位置（同名时已顺延，可能不同于原路径）
    void restored(const QString &connectionId, const QString &trashName, const QString &targetPath);
    /// 彻底删除完成：trashNames 为成功删除的条目（供列表就地移除）
    void purged(const QString &connectionId, const QStringList &trashNames);
    /// 文本读取完成：encodingName 为检测出的编码，hadBom 供保存时原样回写
    void textLoaded(const QString &connectionId, const QString &path, const QString &text,
                    const QString &encodingName, bool hadBom);
    /// 文本保存完成：fellBackToUtf8 表示原编码表示不了新内容，已按纪律回退 UTF-8
    void textSaved(const QString &connectionId, const QString &path, bool fellBackToUtf8,
                   const QString &encodingName);
    /// 属性查询完成（PC-110）：info 见 inspect() 的字段说明
    void inspected(const QString &connectionId, const QString &path, const QVariantMap &info);
    /// 属性查询失败（条目已被删除 / 连接源不可用），reason 可直接展示
    void inspectFailed(const QString &connectionId, const QString &path, const QString &reason);
    /// 移动/复制推进：done/total 为顶层条目数，bytesDone/bytesTotal 为当前条目的字节进度
    void transferProgress(int done, int total, const QString &currentName, qint64 bytesDone,
                          qint64 bytesTotal);
    /// 移动/复制结束：moved 为已移动的源路径，created 为目标处实际落点（同名已顺延）
    void transferred(const QString &sourceConnectionId, const QStringList &moved,
                     const QString &targetConnectionId, const QString &targetDir,
                     const QStringList &created, bool copy);
    /// 移动/复制整体结束（成功 / 部分失败 / 取消都发；UI 据此收起进度）
    void transferFinished();
    /// 操作失败：title 是「哪个操作」，reason 是具体原因
    void failed(const QString &title, const QString &reason);
    void busyChanged();

private:
    explicit FileOperations(QObject *parent = nullptr);
    ~FileOperations() override;
    Q_DISABLE_COPY_MOVE(FileOperations)

    /// 批量删除的共享状态（回调链跨多轮事件循环，必须堆上）
    struct Batch;
    using BatchPtr = std::shared_ptr<Batch>;

    void begin();
    void end();

    /// 瞬时错误退避重试（最多 2 次，600ms / 1200ms）
    void runWithRetry(std::function<void(std::function<void(StorageError)>)> op,
                      std::function<void(StorageError)> done, int attempt = 0);

    void startRemove(const BatchPtr &batch);
    void probeTrashName(const BatchPtr &batch, const QString &src, const QString &originalName,
                        int attempt);
    void moveIntoTrash(const BatchPtr &batch, const QString &src, const QString &trashName);
    void writeTrashMeta(const BatchPtr &batch, const QString &src, const QString &trashName);
    void removePermanentItem(const BatchPtr &batch, const QString &src);
    void advanceRemove(const BatchPtr &batch, const QString &src, const StorageError &error);
    void finishRemove(const BatchPtr &batch);

    /// 还原的共享状态（stat → mkdir → 冲突探测 → move 跨多轮事件循环）
    struct RestoreOp;
    using RestoreOpPtr = std::shared_ptr<RestoreOp>;

    void startRestore(const RestoreOpPtr &op);
    void probeRestoreTarget(const RestoreOpPtr &op, int attempt);
    void moveOutOfTrash(const RestoreOpPtr &op, const QString &targetPath);
    void failRestore(const RestoreOpPtr &op, const StorageError &error);

    /// 彻底删除（回收站清理）的共享状态
    struct PurgeOp;
    using PurgeOpPtr = std::shared_ptr<PurgeOp>;

    void startPurge(const PurgeOpPtr &op);
    void purgeItem(const PurgeOpPtr &op);
    void advancePurge(const PurgeOpPtr &op, const StorageError &error);
    void finishPurge(const PurgeOpPtr &op);

    /// 移动/复制：逐项串行、每项内部递归；跨源逐文件中转
    struct TransferOp;
    using TransferOpPtr = std::shared_ptr<TransferOp>;

    void startTransferItem(const TransferOpPtr &op);
    void planTransferItem(const TransferOpPtr &op, const QString &src, const FileEntry &entry,
                          int attempt);
    void runTransferItem(const TransferOpPtr &op, const QString &src, const QString &dst,
                         const FileEntry &entry);
    void transferTree(const TransferOpPtr &op, const QString &src, const QString &dst,
                      const FileEntry &entry, std::function<void(StorageError)> done);
    void transferChildren(const TransferOpPtr &op, const QString &srcDir, const QString &dstDir,
                          const FileEntryList &children, int index,
                          std::function<void(StorageError)> done);
    void relayFile(const TransferOpPtr &op, const QString &src, const QString &dst, qint64 size,
                   std::function<void(StorageError)> done);
    void pullRelayChunk(const TransferOpPtr &op, const QString &src, RelayStream *stream,
                        qint64 offset, qint64 total);
    void failTransferItem(const TransferOpPtr &op, const QString &src, const StorageError &error);
    void finishTransfer(const TransferOpPtr &op);

    int m_active = 0;
    bool m_transferring = false;
    TransferOpPtr m_transferOp;
};

} // namespace myhub
