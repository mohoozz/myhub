import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/api/favorite_api.dart';
import 'package:myhub_flutter/core/api/file_api.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/data/repositories/progress_repository.dart';
import 'package:myhub_flutter/features/browse/providers/browse_provider.dart';
import 'package:myhub_flutter/features/reading/providers/reading_provider.dart';
import 'package:myhub_flutter/shared/providers/source_provider.dart';

/// 多选模式开关：与 [selectionProvider] 解耦，支持"一键进入多选但暂未选中任何项"。
final selectionModeProvider = NotifierProvider<SelectionModeNotifier, bool>(
  SelectionModeNotifier.new,
);

class SelectionModeNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  /// 进入多选模式（不预选任何条目）。
  void enter() => state = true;

  /// 退出多选模式。
  void exit() => state = false;
}

/// 多选状态：非空集合即处于多选模式。
final selectionProvider = NotifierProvider<SelectionNotifier, Set<String>>(
  SelectionNotifier.new,
);

class SelectionNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => {};

  /// 长按进入多选。
  void enter(String path) {
    ref.read(selectionModeProvider.notifier).enter();
    state = {path};
  }

  /// 多选模式下切换选中：全部取消选中后自动退出多选模式，
  /// 避免用户明明已经没勾选项、底部却仍占据一行 action bar。
  void toggle(String path) {
    final next = {...state};
    if (!next.remove(path)) {
      next.add(path);
    }
    if (next.isEmpty) {
      // 所有项都已取消，同时退出 selectionMode 让 toolbar 隐藏并恢复普通浏览。
      ref.read(selectionModeProvider.notifier).exit();
    }
    state = next;
  }

  /// 全选。
  void selectAll(List<FileItem> items) {
    ref.read(selectionModeProvider.notifier).enter();
    state = items.map((e) => e.path).toSet();
  }

  /// 退出多选。
  void clear() {
    ref.read(selectionModeProvider.notifier).exit();
    state = {};
  }
}

/// 上传任务状态。
enum UploadStatus { uploading, done, failed }

/// 上传任务。
class UploadTask {
  const UploadTask({
    required this.id,
    required this.name,
    this.sent = 0,
    this.total = 0,
    this.status = UploadStatus.uploading,
  });

  final int id;
  final String name;
  final int sent;
  final int total;
  final UploadStatus status;

  double get progress => total > 0 ? sent / total : 0;

  UploadTask copyWith({int? sent, int? total, UploadStatus? status}) {
    return UploadTask(
      id: id,
      name: name,
      sent: sent ?? this.sent,
      total: total ?? this.total,
      status: status ?? this.status,
    );
  }
}

/// 上传队列（多文件排队逐个上传）。
final uploadQueueProvider =
    NotifierProvider<UploadQueueNotifier, List<UploadTask>>(
      UploadQueueNotifier.new,
    );

class UploadQueueNotifier extends Notifier<List<UploadTask>> {
  int _nextId = 0;

  @override
  List<UploadTask> build() => [];

  void _update(int id, UploadTask Function(UploadTask) update) {
    state = [for (final t in state) t.id == id ? update(t) : t];
  }

  /// 清空已完成/失败任务。
  void clearFinished() {
    state = state.where((t) => t.status == UploadStatus.uploading).toList();
  }

  /// 入队并执行上传（由 FileActions 调用）。
  Future<void> enqueue(
    String filePath,
    Future<void> Function(UploadTask, void Function(int sent, int total))
    runner,
  ) async {
    final task = UploadTask(
      id: _nextId++,
      name: filePath.split(RegExp(r'[\\/]')).last,
    );
    state = [...state, task];
    try {
      await runner(task, (sent, total) {
        _update(task.id, (t) => t.copyWith(sent: sent, total: total));
      });
      _update(task.id, (t) => t.copyWith(status: UploadStatus.done));
    } catch (_) {
      _update(task.id, (t) => t.copyWith(status: UploadStatus.failed));
    }
  }
}

/// 文件操作封装：mkdir/rename/move/copy/delete/收藏/上传。
final fileActionsProvider = Provider<FileActions>(FileActions.new);

class FileActions {
  FileActions(this._ref);

  final Ref _ref;

  FileApi get _api => _ref.read(fileApiProvider);

  int? get _sourceId => _ref.read(effectiveSourceProvider)?.id;

  String get _dir => _ref.read(browsePathProvider);

  Future<void> _refresh() => _ref.read(fileListProvider.notifier).refresh();

  /// 路径最后一段文件名。
  String _base(String p) {
    final parts = p.split('/');
    return parts.isEmpty ? p : parts.last;
  }

  /// 拼接目录与文件名（与后端 path.Join 行为一致：规范结尾 `/`）。
  String _joinPath(String dir, String name) {
    var d = dir;
    while (d.length > 1 && d.endsWith('/')) {
      d = d.substring(0, d.length - 1);
    }
    if (d.isEmpty) d = '/';
    final n = name.startsWith('/') ? name.substring(1) : name;
    return '$d/$n';
  }

  /// 新建文件夹。
  Future<void> mkdir(String name) async {
    final sourceId = _sourceId;
    if (sourceId == null) return;
    final dir = _dir == '/' ? '' : _dir;
    await _api.mkdir(sourceId, '$dir/$name');
    await _refresh();
  }

  /// 重命名（同步改写阅读进度路径，避免历史失效）。
  Future<void> rename(FileItem item, String newName) async {
    final sourceId = _sourceId;
    if (sourceId == null) return;
    await _api.rename(sourceId, item.path, newName);
    final newPath = _joinPath(parentPathOf(item.path), newName);
    await _ref
        .read(progressRepositoryProvider)
        .movePath(sourceId, item.path, newPath);
    await _refresh();
    _ref.invalidate(readingListProvider);
  }

  /// 移动到目标目录（同步改写阅读进度路径，避免历史失效）。
  Future<void> move(List<String> paths, String targetDir) async {
    final sourceId = _sourceId;
    if (sourceId == null) return;
    await _api.moveFiles(sourceId, paths, targetDir);
    final progressRepo = _ref.read(progressRepositoryProvider);
    for (final p in paths) {
      await progressRepo.movePath(sourceId, p, _joinPath(targetDir, _base(p)));
    }
    _ref.read(selectionProvider.notifier).clear();
    await _refresh();
    _ref.invalidate(readingListProvider);
  }

  /// 复制到目标目录。
  Future<void> copy(List<String> paths, String targetDir) async {
    final sourceId = _sourceId;
    if (sourceId == null) return;
    await _api.copyFiles(sourceId, paths, targetDir);
    _ref.read(selectionProvider.notifier).clear();
    await _refresh();
  }

  /// 删除入回收站，并联动清理对应文件的阅读/播放历史记录。
  Future<void> delete(List<String> paths) async {
    final sourceId = _sourceId;
    if (sourceId == null) return;
    await _api.deleteFiles(sourceId, paths);
    // 清理被删文件（含目录子文件）的阅读进度：服务端由删除接口一并清理，
    // 此处同步清理本地缓存，避免"正在阅读"仍展示已删除文件。
    final progressRepo = _ref.read(progressRepositoryProvider);
    for (final p in paths) {
      await progressRepo.deleteByPath(sourceId, p);
    }
    _ref.read(selectionProvider.notifier).clear();
    await _refresh();
    // 若"正在阅读"页已加载，立即让其重新拉取（未加载则下次进入时生效）。
    _ref.invalidate(readingListProvider);
  }

  /// 收藏文件/文件夹。
  Future<void> favorite(FileItem item) async {
    final sourceId = _sourceId;
    if (sourceId == null) return;
    await _ref.read(favoriteApiProvider).add(sourceId, item.path);
  }

  /// 上传文件到当前目录（入队，支持进度回调）。
  Future<void> upload(List<String> filePaths) async {
    final sourceId = _sourceId;
    if (sourceId == null) return;
    final dir = _dir;
    final queue = _ref.read(uploadQueueProvider.notifier);
    for (final path in filePaths) {
      await queue.enqueue(path, (task, onProgress) async {
        await _api.uploadFiles(sourceId, dir, [path], onProgress: onProgress);
      });
    }
    await _refresh();
  }
}
