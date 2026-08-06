import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/data/repositories/progress_repository.dart';

/// 进度同步服务 Provider（app 层 watch 激活，随 ProviderScope 销毁）。
final progressSyncProvider = Provider<ProgressSyncService>((ref) {
  final service = ProgressSyncService(ref.watch(progressRepositoryProvider));
  ref.onDispose(service.dispose);
  return service;
});

/// 离线进度同步服务（F-502）。
///
/// 启动时尝试同步一次；监听网络状态，恢复连接时
/// 批量上传本地未同步（synced=false）的进度记录。
class ProgressSyncService {
  ProgressSyncService(this._repo) {
    _sub = Connectivity().onConnectivityChanged.listen((results) {
      if (results.any((r) => r != ConnectivityResult.none)) {
        unawaited(sync());
      }
    });
    unawaited(sync());
  }

  final ProgressRepository _repo;
  StreamSubscription<List<ConnectivityResult>>? _sub;
  bool _syncing = false;

  /// 批量上传未同步进度（重入保护；失败静默，下轮再试）。
  Future<void> sync() async {
    if (_syncing) return;
    _syncing = true;
    try {
      await _repo.syncPending();
    } catch (_) {
      // 静默：未登录 / 网络波动等
    } finally {
      _syncing = false;
    }
  }

  void dispose() {
    unawaited(_sub?.cancel());
  }
}
