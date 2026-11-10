#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QString>
#include <QStringList>
#include <QVariantMap>

namespace myhub {

class StorageAdapter;

/**
 * 文件操作的 QML 桥接（QML 侧单例名 `Files`）。
 *
 * 与 PlayerBridge / SettingsBridge 同样的分层理由：核心逻辑在 myhub_core
 * （`FileOperations`，不依赖 QtQml，可被 QTest 覆盖），本类负责
 * 「按连接 id 解析适配器」这件只有 app 层才知道的事（ConnectionStore 在 features）。
 */
class FileBridge : public QObject
{
    Q_OBJECT
    QML_NAMED_ELEMENT(Files)
    QML_SINGLETON

    /// 是否有操作正在进行（UI 据此显示忙碌态并禁用重复提交）
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)

public:
    explicit FileBridge(QObject *parent = nullptr);

    bool busy() const;

    Q_INVOKABLE void createFolder(const QString &connectionId, const QString &parentPath,
                                  const QString &name);
    Q_INVOKABLE void rename(const QString &connectionId, const QString &path,
                            const QString &newName);
    Q_INVOKABLE void removeToTrash(const QString &connectionId, const QStringList &paths);
    Q_INVOKABLE void removePermanently(const QString &connectionId, const QStringList &paths);

    /// 名称校验：返回空串表示合法，否则是可直接展示的原因（纯本地，不发请求）
    Q_INVOKABLE QString validateName(const QString &name) const;

    // ---- 上传 / 下载（PC-103）----

    /// 上传本地文件或文件夹到 dirPath（文件夹递归展开，同名自动顺延）
    Q_INVOKABLE void uploadLocalFiles(const QString &connectionId, const QString &dirPath,
                                      const QStringList &localPaths);
    /// 下载到默认目录：下载/MyHub/<连接名>/<远端路径>
    Q_INVOKABLE void download(const QString &connectionId, const QStringList &remotePaths);
    /// 另存为（targetPath 来自系统保存对话框）
    Q_INVOKABLE void downloadAs(const QString &connectionId, const QString &remotePath,
                                const QString &targetPath);
    /// 另存为对话框的默认路径建议
    Q_INVOKABLE QString suggestedDownloadPath(const QString &connectionId,
                                              const QString &remotePath) const;
    /// 在系统文件管理器中定位文件
    Q_INVOKABLE void revealInFolder(const QString &localPath) const;

    // ---- 移动 / 复制（PC-104）----

    /// 移动/复制到目标连接源的 targetDir（copy=true 复制）；返回是否已受理
    Q_INVOKABLE bool moveOrCopy(const QString &sourceConnectionId, const QStringList &paths,
                                const QString &targetConnectionId, const QString &targetDir,
                                bool copy);
    /// 取消正在进行的移动/复制（已完成的项不回滚）
    Q_INVOKABLE void cancelMoveCopy();

    // ---- 文本在线编辑（PC-103）----

    /// 读取文本并自动识别编码；结果经 textLoaded 回传（超 8MB 直接报失败，不截断）
    Q_INVOKABLE void loadText(const QString &connectionId, const QString &path);
    /// 保存文本：沿用 encodingName 编码，不可表示字符时回退 UTF-8（textSaved 会告知）
    Q_INVOKABLE void saveText(const QString &connectionId, const QString &path, const QString &text,
                              const QString &encodingName, bool withBom);

    // ---- 属性面板（PC-110）----

    /// 查询属性（现场 stat + 阅读进度 + 连接源信息），结果经 propertiesReady 回传
    Q_INVOKABLE void requestProperties(const QString &connectionId, const QString &path);
    /// 复制到剪贴板（属性面板「复制路径」用）
    Q_INVOKABLE void copyToClipboard(const QString &text) const;

signals:
    void created(const QString &parentPath, const QString &path, bool isDir);
    void renamed(const QString &oldPath, const QString &newPath);
    void removed(const QStringList &paths, bool toTrash);
    void failed(const QString &title, const QString &reason);
    void busyChanged();
    /// 单个下载完成（横幅据此显示「在文件夹中显示」）
    void downloadFinished(const QString &localPath);
    /// 移动/复制进度：currentName 为当前条目名
    void transferProgress(int done, int total, const QString &currentName, qint64 bytesDone,
                          qint64 bytesTotal);
    /// 移动/复制整体结束（成功 / 部分失败 / 取消都发）
    void transferFinished();
    /// 移动/复制有成功项：moved 为已移动的源，created 为目标处实际落点
    void transferred(const QString &sourceConnectionId, const QStringList &moved,
                     const QString &targetConnectionId, const QString &targetDir,
                     const QStringList &created, bool copy);
    /// 文本读取完成：encodingName 为检测出的编码（保存时原样回写）
    void textLoaded(const QString &connectionId, const QString &path, const QString &text,
                    const QString &encodingName, bool hadBom);
    /// 文本保存完成：fellBackToUtf8 表示原编码表示不了新内容，已按纪律回退 UTF-8
    void textSaved(const QString &connectionId, const QString &path, bool fellBackToUtf8,
                   const QString &encodingName);
    /// 属性查询完成（已补齐连接源名称与本地标记）
    void propertiesReady(const QVariantMap &info);
    /// 属性查询失败：reason 可直接展示（条目可能已被删除）
    void propertiesFailed(const QString &connectionId, const QString &path, const QString &reason);

private:
    /// 解析适配器；失败时已发出 failed，返回 nullptr
    StorageAdapter *resolve(const QString &connectionId, const QString &title);

    /**
     * 删除前先停掉正在播放的条目。
     *
     * Windows 下被解码器占用的文件会删除失败（共享冲突），
     * 与其让用户看到「删除失败：文件被占用」，不如先停播（§3.3 占用处理）。
     */
    void stopPlaybackFor(const QString &connectionId, const QStringList &paths);
};

} // namespace myhub
