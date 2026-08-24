import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/api/api_exception.dart';
import 'package:myhub_flutter/core/api/progress_api.dart';
import 'package:myhub_flutter/core/models/reading_progress.dart';
import 'package:myhub_flutter/data/database/app_database.dart';

/// 进度保存版本号：每次本地保存进度后 +1，驱动"正在阅读"页自动刷新。
///
/// NotifierProvider 默认 keepAlive，全程可被监听（F-502）。
final progressRevisionProvider =
    NotifierProvider<ProgressRevisionNotifier, int>(
  ProgressRevisionNotifier.new,
);

class ProgressRevisionNotifier extends Notifier<int> {
  @override
  int build() => 0;

  /// 进度上报后调用：版本号自增，通知监听方刷新。
  void bump() => state++;
}

/// 离线进度缓存仓库 Provider。
final progressRepositoryProvider = Provider<ProgressRepository>(
  (ref) => ProgressRepository(
    ref.watch(appDatabaseProvider),
    ref.watch(progressApiProvider),
    onSaved: () => ref.read(progressRevisionProvider.notifier).bump(),
  ),
);

/// 离线进度缓存与同步仓库（F-502）。
///
/// 写入策略：先落本地 drift（synced=false），再尝试上报后端，
/// 成功则标记已同步；网络不可用时仅保留本地记录，
/// 由 [syncPending] 在网络恢复后批量上传。
///
/// 冲突处理：本地与后端记录比较 updated_at，以最新为准。
class ProgressRepository {
  ProgressRepository(this._db, this._api, {this.onSaved});

  final AppDatabase _db;
  final ProgressApi _api;

  /// 进度本地落库后的回调（驱动"正在阅读"页自动刷新）。
  final void Function()? onSaved;

  /// 保存进度：本地优先，随后尝试上报后端。
  Future<void> save({
    required int sourceId,
    required String filePath,
    required String mediaType,
    String? title,
    String? cover,
    String? progressJson,
    double? percent,
  }) async {
    final now = DateTime.now();
    await _db.upsertProgress(
      LocalProgressCompanion(
        sourceId: Value(sourceId),
        filePath: Value(filePath),
        mediaType: Value(mediaType),
        title: Value(title ?? ''),
        cover: Value(cover ?? ''),
        progressJson: Value(progressJson ?? ''),
        percent: Value(percent ?? 0),
        // percent 达 100% 视为读完：本地同步标记 finished，与后端
        // 一致（后端在 percent>=100 时同样置 finished=true），离线时
        // "正在阅读"页也能立即显示"已读完"。
        finished: Value(percent != null && percent >= 100),
        // 重新产生进度时取消删除标记（此前可能被本地删除待同步）
        deleted: const Value(false),
        synced: const Value(false),
        updatedAt: Value(now),
      ),
    );
    // 本地已落库：通知"正在阅读"页刷新（后端上传成败不影响本地展示）
    onSaved?.call();
    try {
      await _api.save(
        sourceId: sourceId,
        filePath: filePath,
        mediaType: mediaType,
        title: title,
        cover: cover,
        progressJson: progressJson,
        percent: percent,
      );
      // 上传期间若无更新的本地写入，标记已同步
      final row = await _db.getProgress(sourceId, filePath);
      if (row != null && !row.updatedAt.isAfter(now)) {
        await _db.markProgressSynced(row.id);
      }
    } catch (_) {
      // 网络不可用：保留 synced=false，待网络恢复后批量同步
    }
  }

  /// 删除阅读记录：本地标记删除 + 后端删除（离线时保留待同步删除）。
  Future<void> delete(int sourceId, String filePath) async {
    final now = DateTime.now();
    final local = await _db.getProgress(sourceId, filePath);
    if (local != null && !local.deleted) {
      await _db.markProgressDeleted(sourceId, filePath, updatedAt: now);
    }
    try {
      await _api.delete(sourceId, filePath);
      // 后端删除成功，物理清理本地记录
      await _db.deleteProgress(sourceId, filePath);
    } catch (_) {
      // 离线：保留 deleted=true 标记，联网后由 syncPending 补删
    }
  }

  /// 删除指定路径（含子路径）的阅读记录：本地标记删除 + 后端删除（离线时保留待同步）。
  ///
  /// 用于浏览页删除文件/目录后联动清理"正在阅读"历史：
  /// 服务端进度已由删除接口一并清理，此处主要负责清理本地缓存；
  /// 后端返回 404（记录不存在）视为删除成功。
  Future<void> deleteByPath(int sourceId, String filePath) async {
    await _db.markProgressDeletedByPath(sourceId, filePath);
    try {
      await _api.delete(sourceId, filePath);
      await _db.deleteProgressByPath(sourceId, filePath);
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        // 后端已无该记录（可能已被删除接口联动清理），直接清理本地
        await _db.deleteProgressByPath(sourceId, filePath);
      }
      // 其余异常：保留 deleted=true 标记，联网后由 syncPending 补删
    } catch (_) {
      // 离线：保留 deleted=true 标记，联网后由 syncPending 补删
    }
  }

  /// 文件移动/重命名后同步进度路径（含子路径）。
  ///
  /// 服务端路径已由移动/重命名接口同步改写，此处同步本地缓存；
  /// 本地记录路径改写成功后无需重新上传（服务端与本地已一致）。
  Future<void> movePath(int sourceId, String oldPath, String newPath) async {
    await _db.updateProgressPathPrefix(sourceId, oldPath, newPath);
  }

  /// 查询单条进度：本地与后端取 updated_at 较新者（以最新为准）。
  ///
  /// 后端较新时回写本地缓存（synced=true）；本地较新且未同步时
  /// 由 [syncPending] 统一补传。网络失败时静默返回本地记录。
  ///
  /// 本地已删除待同步的记录视为不存在（返回 null）。
  ///
  /// 后端列表中不存在该记录时：本地已同步（synced=true）的缓存说明
  /// 已被其他设备删除，清理本地并视为不存在；本地未同步的离线新增
  /// 记录仍返回，供离线续读。
  Future<LocalProgressData?> get(int sourceId, String filePath) async {
    final local = await _db.getProgress(sourceId, filePath);
    if (local != null && local.deleted) return null;
    try {
      final items = await _api.list();
      var found = false;
      for (final e in items) {
        if (e is! Map<String, dynamic>) continue;
        if (e['source_id'] != sourceId || e['file_path'] != filePath) {
          continue;
        }
        found = true;
        final remote = ReadingProgress.fromJson(e);
        final remoteAt = remote.updatedAt;
        if (local == null ||
            (remoteAt != null && remoteAt.isAfter(local.updatedAt))) {
          // 后端较新（或本地无记录）：回写本地缓存
          await _applyRemote(remote);
          return _db.getProgress(sourceId, filePath);
        }
        return local;
      }
      if (!found && local != null && local.synced) {
        // 后端已无该记录：清理本地旧缓存，避免继续阅读复活已删除记录
        await _db.deleteProgress(sourceId, filePath);
        return null;
      }
    } catch (_) {
      // 网络不可用：仅用本地缓存
    }
    return local;
  }

  /// 合并本地 + 后端进度列表（以最新为准），供"正在阅读"页使用。
  ///
  /// 后端较新的记录回写本地缓存；仅在本地存在的未同步记录保留展示。
  /// 本地已删除待同步的记录不展示、不被后端复活。
  ///
  /// 本地已同步（synced=true）但后端已不存在的记录，说明已被其他设备
  /// 删除：清理本地缓存、不再展示，避免已删除记录跨设备"复活"。
  Future<List<ReadingProgress>> listMerged() async {
    final local = await _db.allProgress();
    final deletedKeys = {
      for (final p in await _db.deletedProgress()) _key(p.sourceId, p.filePath),
    };
    final merged = <String, ReadingProgress>{
      for (final p in local) _key(p.sourceId, p.filePath): _fromLocal(p),
    };
    try {
      final items = await _api.list();
      final remoteKeys = <String>{};
      for (final e in items) {
        if (e is! Map<String, dynamic>) continue;
        final remote = ReadingProgress.fromJson(e);
        final k = _key(remote.sourceId, remote.filePath);
        remoteKeys.add(k);
        if (deletedKeys.contains(k)) continue;
        final existing = merged[k];
        final remoteAt = remote.updatedAt;
        if (existing == null ||
            (remoteAt != null &&
                (existing.updatedAt == null ||
                    remoteAt.isAfter(existing.updatedAt!)))) {
          merged[k] = remote;
          await _applyRemote(remote);
        }
      }
      // 清理"已被其他设备删除"的本地已同步缓存（仅在后端列表成功
      // 拉取后执行；离线时跳过，保留本地缓存展示）。
      for (final p in local) {
        if (!p.synced) continue;
        final k = _key(p.sourceId, p.filePath);
        if (remoteKeys.contains(k)) continue;
        merged.remove(k);
        await _db.deleteProgress(p.sourceId, p.filePath);
      }
    } catch (_) {
      // 网络不可用：仅展示本地缓存
    }
    return merged.values.toList();
  }

  /// 批量上传未同步进度/补删未同步删除（网络恢复时调用）。
  ///
  /// 冲突处理：上传前先拉取后端列表，后端 updated_at 较新的记录
  /// 跳过上传并用后端数据覆盖本地（以最新为准）。
  Future<void> syncPending() async {
    final unsynced = await _db.unsyncedProgress();
    if (unsynced.isEmpty) return;
    // 拉一次后端做冲突比较；失败说明网络仍不可用，直接返回
    final remote = <String, ReadingProgress>{};
    try {
      final items = await _api.list();
      for (final e in items) {
        if (e is! Map<String, dynamic>) continue;
        final p = ReadingProgress.fromJson(e);
        remote[_key(p.sourceId, p.filePath)] = p;
      }
    } catch (_) {
      return;
    }
    // 兜底清理：本地已同步（synced=true）但后端已不存在的记录，
    // 说明已被其他设备删除，清理本地缓存避免"复活"。
    final syncedLocal = await _db.allProgress();
    for (final p in syncedLocal) {
      if (!p.synced) continue;
      if (remote.containsKey(_key(p.sourceId, p.filePath))) continue;
      await _db.deleteProgress(p.sourceId, p.filePath);
    }
    for (final p in unsynced) {
      if (p.deleted) {
        // 离线删除补偿：后端删除后物理清理本地记录
        try {
          await _api.delete(p.sourceId, p.filePath);
          await _db.deleteProgress(p.sourceId, p.filePath);
        } catch (_) {
          // 单条失败不影响其余记录，下轮再试
        }
        continue;
      }
      final r = remote[_key(p.sourceId, p.filePath)];
      final remoteAt = r?.updatedAt;
      if (r != null && remoteAt != null && remoteAt.isAfter(p.updatedAt)) {
        // 后端较新：以最新为准，用后端覆盖本地
        await _applyRemote(r);
        continue;
      }
      try {
        await _api.save(
          sourceId: p.sourceId,
          filePath: p.filePath,
          mediaType: p.mediaType,
          title: p.title,
          cover: p.cover,
          progressJson: p.progressJson,
          percent: p.percent,
        );
        await _db.markProgressSynced(p.id);
      } catch (_) {
        // 单条失败不影响其余记录，下轮再试
      }
    }
  }

  /// 用后端记录覆盖本地缓存（标记已同步）。
  Future<void> _applyRemote(ReadingProgress p) {
    return _db.upsertProgress(
      LocalProgressCompanion(
        sourceId: Value(p.sourceId),
        filePath: Value(p.filePath),
        mediaType: Value(p.mediaType),
        title: Value(p.title),
        cover: Value(p.cover),
        progressJson: Value(p.progressJson),
        percent: Value(p.percent),
        finished: Value(p.finished),
        deleted: const Value(false),
        synced: const Value(true),
        updatedAt: Value(p.updatedAt ?? DateTime.now()),
      ),
    );
  }

  ReadingProgress _fromLocal(LocalProgressData p) {
    return ReadingProgress(
      id: p.id,
      sourceId: p.sourceId,
      filePath: p.filePath,
      mediaType: p.mediaType,
      title: p.title,
      cover: p.cover,
      progressJson: p.progressJson,
      percent: p.percent,
      finished: p.finished,
      updatedAt: p.updatedAt,
    );
  }

  String _key(int sourceId, String filePath) => '$sourceId:$filePath';
}
