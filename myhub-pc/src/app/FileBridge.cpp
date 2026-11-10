#include "FileBridge.h"

#include "core/files/FileOperations.h"
#include "core/player/PlayerCore.h"
#include "core/storage/StorageAdapter.h"
#include "core/storage/StorageAdapterFactory.h"
#include "core/storage/StoragePath.h"
#include "core/transfer/TransferManager.h"
#include "features/connections/ConnectionStore.h"

#include <QClipboard>
#include <QDesktopServices>
#include <QDir>
#include <QGuiApplication>
#include <QFileInfo>
#include <QUrl>

namespace myhub {

FileBridge::FileBridge(QObject *parent)
    : QObject(parent)
{
    auto &ops = FileOperations::instance();
    connect(&ops, &FileOperations::created, this, &FileBridge::created);
    connect(&ops, &FileOperations::renamed, this, &FileBridge::renamed);
    connect(&ops, &FileOperations::removed, this, &FileBridge::removed);
    connect(&ops, &FileOperations::failed, this, &FileBridge::failed);
    connect(&ops, &FileOperations::busyChanged, this, &FileBridge::busyChanged);
    connect(&ops, &FileOperations::transferProgress, this, &FileBridge::transferProgress);
    connect(&ops, &FileOperations::transferred, this, &FileBridge::transferred);
    connect(&ops, &FileOperations::transferFinished, this, &FileBridge::transferFinished);
    connect(&ops, &FileOperations::textLoaded, this, &FileBridge::textLoaded);
    connect(&ops, &FileOperations::textSaved, this, &FileBridge::textSaved);
    connect(&ops, &FileOperations::inspectFailed, this, &FileBridge::propertiesFailed);

    // 核心层不知道连接源名称/类型，属性面板需要，这里补齐后再交给 QML
    connect(&ops, &FileOperations::inspected, this,
            [this](const QString &connectionId, const QString &path, const QVariantMap &raw) {
                QVariantMap info = raw;
                const ConnectionRecord connection = ConnectionStore::instance().byId(connectionId);
                info.insert(QStringLiteral("connectionAvailable"), connection.isValid());
                info.insert(QStringLiteral("connectionName"),
                            connection.isValid() ? connection.name : QString());
                info.insert(QStringLiteral("connectionLocal"),
                            connection.type == ConnectionType::Local);
                info.insert(QStringLiteral("connectionTypeName"),
                            connection.isValid()
                                ? StorageAdapterFactory::typeDisplayName(connection.type)
                                : QString());
                info.insert(QStringLiteral("filePath"), path);
                emit propertiesReady(info);
            });

    // 上传完成后让浏览页就地插入条目（复用「新建成功」这条通路）
    auto &transfers = TransferManager::instance();
    connect(&transfers, &TransferManager::uploaded, this,
            [this](const QString &, const QString &parentPath, const QString &remotePath) {
                emit created(parentPath, remotePath, false);
            });
    connect(&transfers, &TransferManager::downloaded, this,
            [this](const QString &, const QString &, const QString &localPath) {
                emit downloadFinished(localPath);
            });
}

bool FileBridge::busy() const
{
    return FileOperations::instance().busy();
}

void FileBridge::createFolder(const QString &connectionId, const QString &parentPath,
                              const QString &name)
{
    StorageAdapter *adapter = resolve(connectionId, tr("新建文件夹失败"));
    if (!adapter) {
        return;
    }
    FileOperations::instance().createFolder(adapter, connectionId, parentPath, name);
}

void FileBridge::rename(const QString &connectionId, const QString &path, const QString &newName)
{
    StorageAdapter *adapter = resolve(connectionId, tr("重命名失败"));
    if (!adapter) {
        return;
    }
    FileOperations::instance().rename(adapter, connectionId, path, newName);
}

void FileBridge::removeToTrash(const QString &connectionId, const QStringList &paths)
{
    StorageAdapter *adapter = resolve(connectionId, tr("删除失败"));
    if (!adapter) {
        return;
    }
    stopPlaybackFor(connectionId, paths);
    FileOperations::instance().removeToTrash(adapter, connectionId, paths);
}

void FileBridge::removePermanently(const QString &connectionId, const QStringList &paths)
{
    StorageAdapter *adapter = resolve(connectionId, tr("永久删除失败"));
    if (!adapter) {
        return;
    }
    stopPlaybackFor(connectionId, paths);
    FileOperations::instance().removePermanently(adapter, connectionId, paths);
}

QString FileBridge::validateName(const QString &name) const
{
    return FileOperations::validateName(name);
}

void FileBridge::uploadLocalFiles(const QString &connectionId, const QString &dirPath,
                                  const QStringList &localPaths)
{
    StorageAdapter *adapter = resolve(connectionId, tr("上传失败"));
    if (!adapter) {
        return;
    }
    const ConnectionRecord record = ConnectionStore::instance().byId(connectionId);
    TransferManager::instance().enqueueUploads(adapter, connectionId, record.name, dirPath,
                                               localPaths);
}

void FileBridge::download(const QString &connectionId, const QStringList &remotePaths)
{
    StorageAdapter *adapter = resolve(connectionId, tr("下载失败"));
    if (!adapter) {
        return;
    }
    const ConnectionRecord record = ConnectionStore::instance().byId(connectionId);
    TransferManager::instance().enqueueDownloads(adapter, connectionId, record.name, remotePaths);
}

void FileBridge::downloadAs(const QString &connectionId, const QString &remotePath,
                            const QString &targetPath)
{
    StorageAdapter *adapter = resolve(connectionId, tr("下载失败"));
    if (!adapter) {
        return;
    }
    const ConnectionRecord record = ConnectionStore::instance().byId(connectionId);
    // QML 的 FileDialog 交回的是 file:// URL，这里统一转成本地路径
    const QUrl url(targetPath);
    const QString localPath = url.isLocalFile() ? url.toLocalFile() : targetPath;
    if (localPath.isEmpty()) {
        return;
    }
    TransferManager::instance().enqueueDownloadAs(adapter, connectionId, record.name, remotePath,
                                                  localPath);
}

QString FileBridge::suggestedDownloadPath(const QString &connectionId,
                                          const QString &remotePath) const
{
    const ConnectionRecord record = ConnectionStore::instance().byId(connectionId);
    const QString root = TransferManager::defaultDownloadDir();
    return QDir::cleanPath(root + QLatin1Char('/') + record.name + remotePath);
}

void FileBridge::revealInFolder(const QString &localPath) const
{
    if (localPath.isEmpty()) {
        return;
    }
    const QFileInfo info(localPath);
    const QString folder = info.isDir() ? info.absoluteFilePath() : info.absolutePath();
    QDesktopServices::openUrl(QUrl::fromLocalFile(folder));
}

bool FileBridge::moveOrCopy(const QString &sourceConnectionId, const QStringList &paths,
                            const QString &targetConnectionId, const QString &targetDir, bool copy)
{
    const QString title = copy ? tr("复制失败") : tr("移动失败");
    StorageAdapter *source = resolve(sourceConnectionId, title);
    if (!source) {
        return false;
    }
    StorageAdapter *target = resolve(targetConnectionId, title);
    if (!target) {
        return false;
    }

    FileOperations::TransferRequest request;
    request.source = source;
    request.sourceConnectionId = sourceConnectionId;
    request.paths = paths;
    request.copy = copy;
    request.target.adapter = target;
    request.target.connectionId = targetConnectionId;
    request.target.directory = targetDir;

    // 目标就是当前目录且不是复制时没有意义：交给 core 判（同目录移动=无操作），这里只挡明显无效的
    return FileOperations::instance().moveOrCopy(request);
}

void FileBridge::cancelMoveCopy()
{
    FileOperations::instance().cancelTransfer();
}

void FileBridge::loadText(const QString &connectionId, const QString &path)
{
    StorageAdapter *adapter = resolve(connectionId, tr("打开文本失败"));
    if (!adapter) {
        return;
    }
    FileOperations::instance().loadText(adapter, connectionId, path);
}

void FileBridge::saveText(const QString &connectionId, const QString &path, const QString &text,
                          const QString &encodingName, bool withBom)
{
    StorageAdapter *adapter = resolve(connectionId, tr("保存失败"));
    if (!adapter) {
        return;
    }
    FileOperations::instance().saveText(adapter, connectionId, path, text, encodingName, withBom);
}

void FileBridge::requestProperties(const QString &connectionId, const QString &path)
{
    StorageAdapter *adapter = resolve(connectionId, tr("读取属性失败"));
    if (!adapter) {
        return;
    }
    FileOperations::instance().inspect(adapter, connectionId, path);
}

void FileBridge::copyToClipboard(const QString &text) const
{
    if (text.isEmpty()) {
        return;
    }
    // 窗口未就绪时 QGuiApplication::clipboard() 仍可用（Qt 内部自行延迟）
    QGuiApplication::clipboard()->setText(text);
}

StorageAdapter *FileBridge::resolve(const QString &connectionId, const QString &title)
{
    StorageError error;
    StorageAdapter *adapter = ConnectionStore::instance().adapterFor(connectionId, &error);
    if (!adapter) {
        emit failed(title, error.isNull() ? tr("连接源不存在或已被删除") : error.userMessage());
    }
    return adapter;
}

void FileBridge::stopPlaybackFor(const QString &connectionId, const QStringList &paths)
{
    PlayerCore &core = PlayerCore::instance();
    const PlaybackRequest &request = core.currentRequest();
    if (request.path.isEmpty()) {
        return;
    }
    if (!request.connectionId.isEmpty() && request.connectionId != connectionId) {
        return;
    }
    for (const QString &path : paths) {
        if (request.path == path || StoragePath::isDescendantOf(request.path, path)) {
            core.close();
            return;
        }
    }
}

} // namespace myhub
