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
  int get schemaVersion => 1;

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

  /// 全部进度（按更新时间降序）。
  Future<List<LocalProgressData>> allProgress() {
    return (select(localProgress)
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
        .get();
  }

  /// 待同步进度。
  Future<List<LocalProgressData>> unsyncedProgress() {
    return (select(localProgress)..where((t) => t.synced.equals(false)))
        .get();
  }

  /// 标记已同步。
  Future<int> markProgressSynced(int id) {
    return (update(localProgress)..where((t) => t.id.equals(id)))
        .write(const LocalProgressCompanion(synced: Value(true)));
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
