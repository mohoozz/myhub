import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/data/database/tables.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'app_database.g.dart';

/// 本地数据库 Provider（随 ProviderScope 生命周期关闭）。
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

/// drift 本地数据库：离线进度缓存 + 离线下载队列（二期）。
@DriftDatabase(tables: [LocalProgress, DownloadTask])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _openConnection());

  /// 测试用内存数据库。
  AppDatabase.memory() : super(NativeDatabase.memory());

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.addColumn(localProgress, localProgress.deleted);
          }
        },
      );

  static QueryExecutor _openConnection() {
    return LazyDatabase(() async {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, 'myhub_local.db'));
      return NativeDatabase.createInBackground(file);
    });
  }

  // --- 离线进度 ---

  /// 保存/更新本地进度（synced 置 false 等待同步）。
  Future<void> upsertProgress(LocalProgressCompanion entry) {
    return into(localProgress).insert(
      entry,
      onConflict: DoUpdate(
        (_) => entry,
        target: [localProgress.sourceId, localProgress.filePath],
      ),
    );
  }

  /// 单条进度查询。
  Future<LocalProgressData?> getProgress(int sourceId, String filePath) {
    return (select(localProgress)
          ..where((t) => t.sourceId.equals(sourceId))
          ..where((t) => t.filePath.equals(filePath)))
        .getSingleOrNull();
  }

  /// 全部进度（按更新时间降序，排除本地已删除待同步的记录）。
  Future<List<LocalProgressData>> allProgress() {
    return (select(localProgress)
          ..where((t) => t.deleted.equals(false))
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
        .get();
  }

  /// 监听指定路径源的进度变化（浏览页进度圆环展示用）。
  ///
  /// 返回的流在本地进度表发生任何写入（播放器上报/阅读器保存/
  /// 远端合并回写）时自动推送最新数据，UI 据此实时刷新进度圆环。
  Stream<List<LocalProgressData>> watchProgressBySource(int sourceId) {
    return (select(localProgress)
          ..where((t) => t.sourceId.equals(sourceId))
          ..where((t) => t.deleted.equals(false)))
        .watch();
  }

  /// 本地已删除待同步的记录（离线删除后联网时据此补删后端）。
  Future<List<LocalProgressData>> deletedProgress() {
    return (select(localProgress)..where((t) => t.deleted.equals(true)))
        .get();
  }

  /// 待同步进度（含删除待同步）。
  Future<List<LocalProgressData>> unsyncedProgress() {
    return (select(localProgress)..where((t) => t.synced.equals(false)))
        .get();
  }

  /// 标记本地进度为已删除（待同步删除）。
  Future<int> markProgressDeleted(
    int sourceId,
    String filePath, {
    DateTime? updatedAt,
  }) {
    return (update(localProgress)
          ..where(
            (t) => t.sourceId.equals(sourceId) & t.filePath.equals(filePath),
          ))
        .write(
          LocalProgressCompanion(
            deleted: const Value(true),
            synced: const Value(false),
            updatedAt: Value(updatedAt ?? DateTime.now()),
          ),
        );
  }

  /// 物理删除本地进度。
  Future<int> deleteProgress(int sourceId, String filePath) {
    return (delete(localProgress)
          ..where(
            (t) => t.sourceId.equals(sourceId) & t.filePath.equals(filePath),
          ))
        .go();
  }

  /// 物理删除指定路径（含子路径）的本地进度记录。
  Future<int> deleteProgressByPath(int sourceId, String filePath) async {
    final prefix = _pathPrefix(filePath);
    final rows = await (select(localProgress)
          ..where((t) => t.sourceId.equals(sourceId)))
        .get();
    final ids = [
      for (final r in rows)
        if (_pathMatches(r.filePath, prefix)) r.id,
    ];
    if (ids.isEmpty) return 0;
    return (delete(localProgress)..where((t) => t.id.isIn(ids))).go();
  }

  /// 标记指定路径（含子路径）的本地进度为已删除（待同步删除）。
  Future<int> markProgressDeletedByPath(
    int sourceId,
    String filePath, {
    DateTime? updatedAt,
  }) async {
    final prefix = _pathPrefix(filePath);
    final rows = await (select(localProgress)
          ..where((t) => t.sourceId.equals(sourceId) & t.deleted.equals(false)))
        .get();
    final ids = [
      for (final r in rows)
        if (_pathMatches(r.filePath, prefix)) r.id,
    ];
    if (ids.isEmpty) return 0;
    return (update(localProgress)..where((t) => t.id.isIn(ids))).write(
      LocalProgressCompanion(
        deleted: const Value(true),
        synced: const Value(false),
        updatedAt: Value(updatedAt ?? DateTime.now()),
      ),
    );
  }

  /// 标记已同步。
  Future<int> markProgressSynced(int id) {
    return (update(localProgress)..where((t) => t.id.equals(id)))
        .write(const LocalProgressCompanion(synced: Value(true)));
  }

  /// 规范化路径前缀：去掉结尾 `/`（根路径 `/` 归一为空串）。
  String _pathPrefix(String path) =>
      path.endsWith('/') ? path.substring(0, path.length - 1) : path;

  /// 判断文件路径是否命中前缀（精确匹配或位于其子目录下）。
  bool _pathMatches(String filePath, String prefix) =>
      filePath == prefix || filePath.startsWith('$prefix/');

  /// 文件移动/重命名后，同步改写本地进度记录路径（含子路径）。
  ///
  /// 目标位置若已有记录（如同名覆盖），先移除旧记录，以移动后文件的进度为准。
  Future<int> updateProgressPathPrefix(
    int sourceId,
    String oldPath,
    String newPath,
  ) async {
    final oldPrefix = _pathPrefix(oldPath);
    final newPrefix = _pathPrefix(newPath);
    if (oldPrefix.isEmpty || newPrefix.isEmpty || oldPrefix == newPrefix) {
      return 0;
    }
    final rows = await (select(localProgress)
          ..where((t) => t.sourceId.equals(sourceId)))
        .get();
    final targets = [
      for (final r in rows)
        if (_pathMatches(r.filePath, oldPrefix))
          (
            row: r,
            newFilePath:
                newPrefix + r.filePath.substring(oldPrefix.length),
          ),
    ];
    if (targets.isEmpty) return 0;
    await transaction(() async {
      for (final t in targets) {
        // 目标位置已有记录先删除，避免唯一键冲突
        await (delete(localProgress)
              ..where(
                (t2) =>
                    t2.sourceId.equals(sourceId) &
                    t2.filePath.equals(t.newFilePath),
              ))
            .go();
        await (update(localProgress)..where((t2) => t2.id.equals(t.row.id)))
            .write(LocalProgressCompanion(filePath: Value(t.newFilePath)));
      }
    });
    return targets.length;
  }

  // --- 下载任务（二期） ---

  /// 入队下载任务。
  Future<int> enqueueDownload(DownloadTaskCompanion entry) {
    return into(downloadTask).insert(entry);
  }

  /// 按状态查询任务。
  Future<List<DownloadTaskData>> downloadsByStatus(String status) {
    return (select(downloadTask)..where((t) => t.status.equals(status)))
        .get();
  }

  /// 全部下载任务（按创建时间降序）。
  Future<List<DownloadTaskData>> allDownloads() {
    return (select(downloadTask)
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .get();
  }

  /// 更新下载进度。
  Future<int> updateDownloadProgress(int id, int downloadedBytes) {
    return (update(downloadTask)..where((t) => t.id.equals(id))).write(
      DownloadTaskCompanion(
        downloadedBytes: Value(downloadedBytes),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// 更新任务状态（可附错误信息）。
  Future<int> updateDownloadStatus(int id, String status, {String? error}) {
    return (update(downloadTask)..where((t) => t.id.equals(id))).write(
      DownloadTaskCompanion(
        status: Value(status),
        error: Value(error),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// 删除任务。
  Future<int> deleteDownload(int id) {
    return (delete(downloadTask)..where((t) => t.id.equals(id))).go();
  }
}
