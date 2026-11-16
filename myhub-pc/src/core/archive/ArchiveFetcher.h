#pragma once

#include "core/storage/StorageError.h"

#include <QString>

#include <functional>

namespace myhub {

class StorageAdapter;

/**
 * 把远程归档整包落到本地（PC-207 的 rar 分支）。
 *
 * 为什么要单独一层：rar 没有 zip 那样的尾部署引，条目只能顺序解压到达，
 * 所以远程 cbr **必须先整包在手**；这条路径有几个容易写错又必须「能单测」的点：
 *   - 按固定块顺序请求，边下边报进度（弱网下用户要知道是在动还是死了）；
 *   - 先写 `<target>.part`，完整落完再 `rename`：中途失败不会留下半个「看起来能打开」的包；
 *   - 任何失败都清掉 `.part`，不留垃圾。
 *
 * 线程：与 `StorageAdapter` 一致 —— 回调在调用方线程，多个块之间是**串行**的。
 */
class ArchiveFetcher
{
public:
    /// 单次请求的块大小：太小请求数爆炸，太大弱网下进度条一顿一顿
    static constexpr qint64 kChunkBytes = 4 * 1024 * 1024;

    using ProgressCallback = std::function<void(qint64 done, qint64 total)>;
    /// 成功回 `localPath`（= targetPath）与空 error；失败回空路径与 error
    using DoneCallback = std::function<void(QString localPath, StorageError error)>;

    static void fetch(StorageAdapter *adapter, const QString &remotePath, qint64 size,
                      const QString &targetPath, ProgressCallback onProgress, DoneCallback onDone);
};

} // namespace myhub
